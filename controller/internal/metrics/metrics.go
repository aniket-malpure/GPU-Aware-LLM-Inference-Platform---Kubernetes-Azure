// Package metrics exposes the controller's own Prometheus metrics in the text
// exposition format without depending on client_golang.
package metrics

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
)

type key struct {
	namespace, name string
}

type entry struct {
	current, desired int32
	load             float64
}

// Registry stores the latest values per autoscaler plus counters.
type Registry struct {
	mu          sync.Mutex
	gauges      map[key]entry
	scaleEvents map[string]float64 // direction -> count
	errors      float64
	reconciles  float64
}

// New returns an empty registry.
func New() *Registry {
	return &Registry{gauges: map[key]entry{}, scaleEvents: map[string]float64{}}
}

// Observe records the latest state of one autoscaler.
func (r *Registry) Observe(ns, name string, current, desired int32, load float64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.gauges[key{ns, name}] = entry{current, desired, load}
	r.reconciles++
}

// ScaleEvent counts a scale action ("up", "down", "zero", "cold_start").
func (r *Registry) ScaleEvent(direction string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.scaleEvents[direction]++
}

// Error counts a failed reconcile.
func (r *Registry) Error() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.errors++
}

// ServeHTTP writes metrics in Prometheus text format.
func (r *Registry) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	r.mu.Lock()
	defer r.mu.Unlock()

	var b strings.Builder
	keys := make([]key, 0, len(r.gauges))
	for k := range r.gauges {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].namespace != keys[j].namespace {
			return keys[i].namespace < keys[j].namespace
		}
		return keys[i].name < keys[j].name
	})

	writeGauge := func(name, help string, val func(entry) float64) {
		fmt.Fprintf(&b, "# HELP %s %s\n# TYPE %s gauge\n", name, help, name)
		for _, k := range keys {
			fmt.Fprintf(&b, "%s{namespace=%q,autoscaler=%q} %g\n", name, k.namespace, k.name, val(r.gauges[k]))
		}
	}
	writeGauge("gpuautoscaler_current_replicas", "Replicas observed on the target.",
		func(e entry) float64 { return float64(e.current) })
	writeGauge("gpuautoscaler_desired_replicas", "Replicas the controller wants.",
		func(e entry) float64 { return float64(e.desired) })
	writeGauge("gpuautoscaler_load", "In-flight requests returned by the load query.",
		func(e entry) float64 { return e.load })

	fmt.Fprintf(&b, "# HELP gpuautoscaler_scale_events_total Scale actions taken.\n# TYPE gpuautoscaler_scale_events_total counter\n")
	dirs := make([]string, 0, len(r.scaleEvents))
	for d := range r.scaleEvents {
		dirs = append(dirs, d)
	}
	sort.Strings(dirs)
	for _, d := range dirs {
		fmt.Fprintf(&b, "gpuautoscaler_scale_events_total{direction=%q} %g\n", d, r.scaleEvents[d])
	}

	fmt.Fprintf(&b, "# HELP gpuautoscaler_reconcile_errors_total Failed reconciles.\n# TYPE gpuautoscaler_reconcile_errors_total counter\ngpuautoscaler_reconcile_errors_total %g\n", r.errors)
	fmt.Fprintf(&b, "# HELP gpuautoscaler_reconciles_total Reconciles completed.\n# TYPE gpuautoscaler_reconciles_total counter\ngpuautoscaler_reconciles_total %g\n", r.reconciles)

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	_, _ = w.Write([]byte(b.String()))
}
