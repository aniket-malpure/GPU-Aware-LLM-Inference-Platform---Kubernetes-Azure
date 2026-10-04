// Package reconciler wires the scaling logic to Kubernetes and Prometheus.
package reconciler

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	autoscalingv1 "k8s.io/api/autoscaling/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"

	"github.com/aniketmalpure/gpu-llm-inference-platform/controller/internal/api"
	"github.com/aniketmalpure/gpu-llm-inference-platform/controller/internal/metrics"
	"github.com/aniketmalpure/gpu-llm-inference-platform/controller/internal/scaler"
)

// LoadQuerier returns the current load for a PromQL expression.
type LoadQuerier interface {
	QueryScalar(ctx context.Context, query string) (float64, error)
}

// Reconciler scales every GPUAutoscaler in the cluster on a fixed interval.
type Reconciler struct {
	Dynamic  dynamic.Interface
	Kube     kubernetes.Interface
	Prom     LoadQuerier
	Metrics  *metrics.Registry
	Log      *slog.Logger
	Interval time.Duration
	DryRun   bool
	Now      func() time.Time
}

// Run blocks until ctx is cancelled.
func (r *Reconciler) Run(ctx context.Context) {
	if r.Now == nil {
		r.Now = time.Now
	}
	ticker := time.NewTicker(r.Interval)
	defer ticker.Stop()

	r.reconcileAll(ctx)
	for {
		select {
		case <-ctx.Done():
			r.Log.Info("controller stopping")
			return
		case <-ticker.C:
			r.reconcileAll(ctx)
		}
	}
}

func (r *Reconciler) reconcileAll(ctx context.Context) {
	list, err := r.Dynamic.Resource(api.GVR).Namespace(metav1.NamespaceAll).List(ctx, metav1.ListOptions{})
	if err != nil {
		r.Log.Error("list GPUAutoscalers", "err", err)
		r.Metrics.Error()
		return
	}
	for i := range list.Items {
		obj := &list.Items[i]
		if err := r.reconcileOne(ctx, obj); err != nil {
			r.Log.Error("reconcile failed", "namespace", obj.GetNamespace(), "name", obj.GetName(), "err", err)
			r.Metrics.Error()
		}
	}
}

func (r *Reconciler) reconcileOne(ctx context.Context, obj *unstructured.Unstructured) error {
	as, err := decode(obj)
	if err != nil {
		return err
	}
	as.Spec.Defaults()
	log := r.Log.With("namespace", as.Namespace, "autoscaler", as.Name, "target", as.Spec.TargetRef.Name)

	deployments := r.Kube.AppsV1().Deployments(as.Namespace)
	scale, err := deployments.GetScale(ctx, as.Spec.TargetRef.Name, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("get scale for deployment %q: %w", as.Spec.TargetRef.Name, err)
	}

	load, err := r.Prom.QueryScalar(ctx, as.Spec.LoadQuery)
	if err != nil {
		// Without a signal, hold the current size rather than guess.
		return fmt.Errorf("query load: %w", err)
	}

	now := r.Now().UTC()
	lastScale := parseTime(as.Status.LastScaleTime)
	lastActive := parseTime(as.Status.LastActiveTime)
	// Start the idle clock the first time we see this autoscaler, so a fresh
	// controller never scales a target to zero on its first tick.
	if load > 0 || lastActive.IsZero() {
		lastActive = now
	}

	decision := scaler.Decide(scaler.Input{
		Now:                  now,
		CurrentReplicas:      scale.Spec.Replicas,
		Load:                 load,
		MinReplicas:          as.Spec.MinReplicas,
		MaxReplicas:          as.Spec.MaxReplicas,
		TargetLoadPerReplica: as.Spec.TargetLoadPerReplica,
		ScaleUpCooldown:      time.Duration(as.Spec.ScaleUpCooldownSeconds) * time.Second,
		ScaleDownCooldown:    time.Duration(as.Spec.ScaleDownCooldownSeconds) * time.Second,
		IdleBeforeZero:       time.Duration(as.Spec.IdleSecondsBeforeZero) * time.Second,
		LastScaleTime:        lastScale,
		LastActiveTime:       lastActive,
	})

	current := scale.Spec.Replicas
	if decision.Changed(current) {
		log.Info("scaling", "from", current, "to", decision.Desired, "load", load, "reason", decision.Reason, "dryRun", r.DryRun)
		if !r.DryRun {
			newScale := &autoscalingv1.Scale{
				ObjectMeta: scale.ObjectMeta,
				Spec:       autoscalingv1.ScaleSpec{Replicas: decision.Desired},
			}
			if _, err := deployments.UpdateScale(ctx, as.Spec.TargetRef.Name, newScale, metav1.UpdateOptions{}); err != nil {
				return fmt.Errorf("update scale: %w", err)
			}
		}
		r.Metrics.ScaleEvent(direction(current, decision.Desired))
		lastScale = now
	} else {
		log.Debug("no change", "replicas", current, "load", load, "reason", decision.Reason)
	}

	r.Metrics.Observe(as.Namespace, as.Name, current, decision.Desired, load)

	status := api.GPUAutoscalerStatus{
		CurrentReplicas: current,
		DesiredReplicas: decision.Desired,
		LastLoad:        load,
		LastScaleTime:   formatTime(lastScale),
		LastActiveTime:  formatTime(lastActive),
		Reason:          decision.Reason,
	}
	return r.writeStatus(ctx, obj, status)
}

func (r *Reconciler) writeStatus(ctx context.Context, obj *unstructured.Unstructured, st api.GPUAutoscalerStatus) error {
	statusMap, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&st)
	if err != nil {
		return fmt.Errorf("encode status: %w", err)
	}
	updated := obj.DeepCopy()
	if err := unstructured.SetNestedField(updated.Object, statusMap, "status"); err != nil {
		return fmt.Errorf("set status: %w", err)
	}
	_, err = r.Dynamic.Resource(api.GVR).Namespace(obj.GetNamespace()).UpdateStatus(ctx, updated, metav1.UpdateOptions{})
	if err != nil {
		return fmt.Errorf("update status: %w", err)
	}
	return nil
}

func decode(obj *unstructured.Unstructured) (*api.GPUAutoscaler, error) {
	as := &api.GPUAutoscaler{}
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(obj.Object, as); err != nil {
		return nil, fmt.Errorf("decode GPUAutoscaler %s/%s: %w", obj.GetNamespace(), obj.GetName(), err)
	}
	as.Name, as.Namespace = obj.GetName(), obj.GetNamespace()
	if as.Spec.TargetRef.Name == "" || as.Spec.LoadQuery == "" {
		return nil, fmt.Errorf("GPUAutoscaler %s/%s: spec.targetRef.name and spec.loadQuery are required", as.Namespace, as.Name)
	}
	return as, nil
}

func direction(from, to int32) string {
	switch {
	case from == 0 && to > 0:
		return "cold_start"
	case to == 0:
		return "zero"
	case to > from:
		return "up"
	default:
		return "down"
	}
}

func parseTime(s string) time.Time {
	if s == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

func formatTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}
