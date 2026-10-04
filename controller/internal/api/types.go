// Package api defines the GPUAutoscaler custom resource.
//
// The controller reads these objects with the dynamic client and converts them
// into the typed structs below, which keeps the build free of code generation.
package api

import "k8s.io/apimachinery/pkg/runtime/schema"

const (
	Group    = "inference.llmplatform.dev"
	Version  = "v1alpha1"
	Kind     = "GPUAutoscaler"
	Resource = "gpuautoscalers"
)

// GVR is the GroupVersionResource used with the dynamic client.
var GVR = schema.GroupVersionResource{Group: Group, Version: Version, Resource: Resource}

// GPUAutoscaler scales a GPU-backed Deployment from inference queue metrics.
type GPUAutoscaler struct {
	Name      string              `json:"-"`
	Namespace string              `json:"-"`
	Spec      GPUAutoscalerSpec   `json:"spec"`
	Status    GPUAutoscalerStatus `json:"status,omitempty"`
}

// TargetRef names the Deployment to scale (same namespace as the autoscaler).
type TargetRef struct {
	Name string `json:"name"`
}

// GPUAutoscalerSpec is the desired behaviour.
type GPUAutoscalerSpec struct {
	TargetRef   TargetRef `json:"targetRef"`
	MinReplicas int32     `json:"minReplicas"`
	MaxReplicas int32     `json:"maxReplicas"`

	// LoadQuery is a PromQL expression returning the total in-flight load
	// (waiting + running requests) across all replicas of the target.
	LoadQuery string `json:"loadQuery"`

	// TargetLoadPerReplica is how many concurrent requests one GPU replica
	// should carry before another replica is added.
	TargetLoadPerReplica float64 `json:"targetLoadPerReplica"`

	// ScaleUpCooldownSeconds is the minimum gap between two scale-ups.
	ScaleUpCooldownSeconds int64 `json:"scaleUpCooldownSeconds,omitempty"`

	// ScaleDownCooldownSeconds is the minimum gap after any scale event before
	// replicas are removed. GPU replicas are slow to start, so keep this long.
	ScaleDownCooldownSeconds int64 `json:"scaleDownCooldownSeconds,omitempty"`

	// IdleSecondsBeforeZero: when MinReplicas is 0 and load stays at zero for
	// this long, scale to zero so the cluster autoscaler can free the GPU node.
	IdleSecondsBeforeZero int64 `json:"idleSecondsBeforeZero,omitempty"`
}

// GPUAutoscalerStatus is written back by the controller.
type GPUAutoscalerStatus struct {
	CurrentReplicas int32   `json:"currentReplicas"`
	DesiredReplicas int32   `json:"desiredReplicas"`
	LastLoad        float64 `json:"lastLoad"`
	LastScaleTime   string  `json:"lastScaleTime,omitempty"`
	LastActiveTime  string  `json:"lastActiveTime,omitempty"`
	Reason          string  `json:"reason,omitempty"`
}

// Defaults fills unset optional fields.
func (s *GPUAutoscalerSpec) Defaults() {
	if s.TargetLoadPerReplica <= 0 {
		s.TargetLoadPerReplica = 16
	}
	if s.ScaleUpCooldownSeconds <= 0 {
		s.ScaleUpCooldownSeconds = 60
	}
	if s.ScaleDownCooldownSeconds <= 0 {
		s.ScaleDownCooldownSeconds = 300
	}
	if s.IdleSecondsBeforeZero <= 0 {
		s.IdleSecondsBeforeZero = 900
	}
	if s.MaxReplicas < s.MinReplicas {
		s.MaxReplicas = s.MinReplicas
	}
}
