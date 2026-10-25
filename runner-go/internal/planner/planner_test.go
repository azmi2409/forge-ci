package planner

import (
	"encoding/json"
	"testing"

	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
)

func steps(t *testing.T, raw ...string) []payload.Step {
	t.Helper()
	out := make([]payload.Step, 0, len(raw))
	for _, r := range raw {
		var s payload.Step
		if err := json.Unmarshal([]byte(r), &s); err != nil {
			t.Fatal(err)
		}
		out = append(out, s)
	}
	return out
}

func TestPlanOrderAndNames(t *testing.T) {
	ss := steps(t,
		`{"type":"checkout"}`,
		`{"type":"run","name":"tests","command":"x"}`,
		`{"type":"run","command":"y"}`,
	)
	entries := Plan(ss)
	if len(entries) != 3 {
		t.Fatalf("entries: %d", len(entries))
	}
	wantNames := []string{"checkout", "tests", "run"}
	for i, e := range entries {
		if e.Index != i {
			t.Errorf("entry %d index %d", i, e.Index)
		}
		if e.Name != wantNames[i] {
			t.Errorf("entry %d name %q want %q", i, e.Name, wantNames[i])
		}
	}
}

func TestRunnable(t *testing.T) {
	cases := []struct {
		when   string
		failed bool
		want   bool
	}{
		{"", false, true},
		{"", true, false},
		{"on_success", true, false},
		{"on_fail", false, false},
		{"on_fail", true, true},
		{"always", false, true},
		{"always", true, true},
		{"bogus", true, false}, // unknown -> on_success semantics
	}
	for _, tc := range cases {
		ss := steps(t, `{"type":"run","command":"x","when":"`+tc.when+`"}`)
		if got := Runnable(&ss[0], tc.failed); got != tc.want {
			t.Errorf("when=%q failed=%v -> %v want %v", tc.when, tc.failed, got, tc.want)
		}
	}
	// Non-run steps (no when field) default to on_success semantics.
	ss := steps(t, `{"type":"checkout"}`)
	if Runnable(&ss[0], true) {
		t.Error("checkout after failure should be skipped")
	}
}
