package scaler

import (
	"testing"
	"time"
)

var t0 = time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)

func base() Input {
	return Input{
		Now:                  t0,
		CurrentReplicas:      1,
		MinReplicas:          0,
		MaxReplicas:          4,
		TargetLoadPerReplica: 16,
		ScaleUpCooldown:      60 * time.Second,
		ScaleDownCooldown:    300 * time.Second,
		IdleBeforeZero:       900 * time.Second,
		LastScaleTime:        t0.Add(-1 * time.Hour),
		LastActiveTime:       t0,
	}
}

func TestDecide(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Input)
		want   int32
	}{
		{"steady at target", func(in *Input) { in.Load = 12 }, 1},
		{"scale up to demand", func(in *Input) { in.Load = 50 }, 4},
		{"scale up clamped to max", func(in *Input) { in.Load = 500 }, 4},
		{"scale up held by cooldown", func(in *Input) {
			in.Load = 50
			in.LastScaleTime = t0.Add(-30 * time.Second)
		}, 1},
		{"cold start ignores cooldown", func(in *Input) {
			in.CurrentReplicas = 0
			in.Load = 3
			in.LastScaleTime = t0.Add(-5 * time.Second)
		}, 1},
		{"scale down one step", func(in *Input) {
			in.CurrentReplicas = 4
			in.Load = 10
		}, 3},
		{"scale down held by cooldown", func(in *Input) {
			in.CurrentReplicas = 4
			in.Load = 10
			in.LastScaleTime = t0.Add(-2 * time.Minute)
		}, 4},
		{"keep one replica during short idle", func(in *Input) {
			in.Load = 0
			in.LastActiveTime = t0.Add(-5 * time.Minute)
		}, 1},
		{"scale to zero after idle window", func(in *Input) {
			in.Load = 0
			in.LastActiveTime = t0.Add(-20 * time.Minute)
		}, 0},
		{"respect min replicas", func(in *Input) {
			in.MinReplicas = 2
			in.CurrentReplicas = 2
			in.Load = 0
			in.LastActiveTime = t0.Add(-2 * time.Hour)
		}, 2},
		{"zero target load does not divide by zero", func(in *Input) {
			in.TargetLoadPerReplica = 0
			in.Load = 3
		}, 3},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			in := base()
			tc.mutate(&in)
			got := Decide(in)
			if got.Desired != tc.want {
				t.Fatalf("Decide() = %d (%s), want %d", got.Desired, got.Reason, tc.want)
			}
		})
	}
}

func TestDecideNeverExceedsBounds(t *testing.T) {
	for load := 0.0; load <= 200; load += 7 {
		for cur := int32(0); cur <= 5; cur++ {
			in := base()
			in.Load = load
			in.CurrentReplicas = cur
			d := Decide(in)
			if d.Desired < 0 || d.Desired > in.MaxReplicas+1 {
				t.Fatalf("load=%v cur=%d gave out-of-range %d", load, cur, d.Desired)
			}
		}
	}
}
