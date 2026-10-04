// Command controller runs the GPU-aware autoscaler for vLLM inference servers.
//
// Each interval it lists GPUAutoscaler objects, queries Prometheus for the
// in-flight request load on the target Deployment, and resizes the Deployment
// through its scale subresource. When replicas drop, the AKS cluster
// autoscaler releases the now-empty GPU nodes.
package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"

	"github.com/aniketmalpure/gpu-llm-inference-platform/controller/internal/metrics"
	"github.com/aniketmalpure/gpu-llm-inference-platform/controller/internal/prom"
	"github.com/aniketmalpure/gpu-llm-inference-platform/controller/internal/reconciler"
)

func main() {
	var (
		kubeconfig  = flag.String("kubeconfig", os.Getenv("KUBECONFIG"), "path to kubeconfig (empty = in-cluster)")
		promURL     = flag.String("prometheus-url", envOr("PROMETHEUS_URL", "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"), "Prometheus base URL")
		interval    = flag.Duration("interval", 15*time.Second, "reconcile interval")
		metricsAddr = flag.String("metrics-addr", ":8080", "address for /metrics and /healthz")
		dryRun      = flag.Bool("dry-run", false, "log decisions without scaling")
		logLevel    = flag.String("log-level", "info", "debug | info | warn | error")
	)
	flag.Parse()

	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: parseLevel(*logLevel)}))

	cfg, err := restConfig(*kubeconfig)
	if err != nil {
		log.Error("build kube config", "err", err)
		os.Exit(1)
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		log.Error("dynamic client", "err", err)
		os.Exit(1)
	}
	kube, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Error("kube client", "err", err)
		os.Exit(1)
	}

	reg := metrics.New()
	mux := http.NewServeMux()
	mux.Handle("/metrics", reg)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })
	srv := &http.Server{Addr: *metricsAddr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("metrics server", "err", err)
			os.Exit(1)
		}
	}()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	log.Info("controller starting", "prometheus", *promURL, "interval", interval.String(), "dryRun", *dryRun)
	r := &reconciler.Reconciler{
		Dynamic:  dyn,
		Kube:     kube,
		Prom:     prom.New(*promURL),
		Metrics:  reg,
		Log:      log,
		Interval: *interval,
		DryRun:   *dryRun,
	}
	r.Run(ctx)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
}

func restConfig(kubeconfig string) (*rest.Config, error) {
	if kubeconfig != "" {
		return clientcmd.BuildConfigFromFlags("", kubeconfig)
	}
	return rest.InClusterConfig()
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func parseLevel(s string) slog.Level {
	switch s {
	case "debug":
		return slog.LevelDebug
	case "warn":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
