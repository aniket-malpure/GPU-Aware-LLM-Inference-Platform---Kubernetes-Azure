// Package scaler holds the pure scaling decision logic, kept free of
// Kubernetes and Prometheus types so it is easy to unit test.
package scaler

import (
	"math"
	"time"
)

// Input is everything the decision needs.
type Input struct {
	Now             time.Time
	CurrentReplicas int32
	Load            float64 // waiting + running requests across all replicas

	MinReplicas          int32
	MaxReplicas          int32
	TargetLoadPerReplica float64

	ScaleUpCooldown   time.Duration
	ScaleDownCooldown time.Duration
	IdleBeforeZero    time.Duration

	LastScaleTime  time.Time // zero if never scaled
	LastActiveTime time.Time // last time Load > 0; zero if unknown
}

// Decision is the outcome.
type Decision struct {
	Desired int32
	Reason  string
}

// Changed reports whether the decision differs from the current replica count.
func (d Decision) Changed(current int32) bool { return d.Desired != current }

// Decide returns the replica count the target should run.
//
// Rules:
//  1. Raw demand = ceil(load / targetLoadPerReplica), clamped to [min, max].
//  2. Scale-up jumps straight to demand, but waits out the scale-up cooldown.
//  3. Scale-down removes one replica at a time and waits out the (longer)
//     scale-down cooldown, because a GPU replica takes minutes to load weights.
//  4. Scale-to-zero only happens when MinReplicas is 0 and load has been zero
//     for IdleBeforeZero. A request arriving at zero replicas scales to 1.
func Decide(in Input) Decision {
	if in.MaxReplicas < in.MinReplicas {
		in.MaxReplicas = in.MinReplicas
	}
	target := in.TargetLoadPerReplica
	if target <= 0 {
		target = 1
	}

	demand := int32(math.Ceil(in.Load / target))
	if in.Load > 0 && demand < 1 {
		demand = 1
	}

	// Never drop below one replica while there is (or recently was) traffic.
	floor := in.MinReplicas
	if floor == 0 && !idleLongEnough(in) {
		floor = 1
	}
	demand = clamp(demand, floor, in.MaxReplicas)

	sinceScale := time.Duration(math.MaxInt64)
	if !in.LastScaleTime.IsZero() {
		sinceScale = in.Now.Sub(in.LastScaleTime)
	}

	switch {
	case demand > in.CurrentReplicas:
		// Cold start from zero is always allowed: someone is waiting.
		if in.CurrentReplicas == 0 {
			return Decision{Desired: demand, Reason: "cold start: load arrived at zero replicas"}
		}
		if sinceScale < in.ScaleUpCooldown {
			return Decision{Desired: in.CurrentReplicas, Reason: "scale-up held: cooldown"}
		}
		return Decision{Desired: demand, Reason: "scale-up: queue above target"}

	case demand < in.CurrentReplicas:
		if sinceScale < in.ScaleDownCooldown {
			return Decision{Desired: in.CurrentReplicas, Reason: "scale-down held: cooldown"}
		}
		next := in.CurrentReplicas - 1
		if demand == 0 {
			return Decision{Desired: 0, Reason: "scale-to-zero: idle window elapsed"}
		}
		if next < demand {
			next = demand
		}
		return Decision{Desired: next, Reason: "scale-down: step by one"}

	default:
		return Decision{Desired: in.CurrentReplicas, Reason: "steady"}
	}
}

func idleLongEnough(in Input) bool {
	if in.Load > 0 {
		return false
	}
	if in.LastActiveTime.IsZero() {
		// No record of activity since the controller started: treat as idle
		// only after the configured window from the last scale event.
		if in.LastScaleTime.IsZero() {
			return true
		}
		return in.Now.Sub(in.LastScaleTime) >= in.IdleBeforeZero
	}
	return in.Now.Sub(in.LastActiveTime) >= in.IdleBeforeZero
}

func clamp(v, lo, hi int32) int32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
