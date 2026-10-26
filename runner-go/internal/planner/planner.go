// Package planner is the pure step-planning logic: ordering, display names,
// and `when` evaluation. No Docker, no network. Display names follow the
// server convention step["name"] || step["type"] so the names reported in
// step_results match the stored StepRuns.
package planner

import "github.com/azmi2409/forge-ci/runner-go/internal/payload"

type Entry struct {
	Index int
	Name  string
	Step  *payload.Step
}

// Plan orders the job's steps into entries.
func Plan(steps []payload.Step) []Entry {
	entries := make([]Entry, 0, len(steps))
	for i := range steps {
		s := &steps[i]
		entries = append(entries, Entry{Index: i, Name: s.DisplayName(), Step: s})
	}
	return entries
}

// Runnable reports whether the step should execute given whether any earlier
// step in this job has already failed. Only `run` steps carry a runtime
// `when` in the IR (compile-time conditionals are resolved by the compiler);
// every other step type defaults to on_success semantics. Unknown `when`
// values fall back to on_success semantics too.
func Runnable(s *payload.Step, failedAlready bool) bool {
	switch s.When {
	case "", "on_success":
		return !failedAlready
	case "on_fail":
		return failedAlready
	case "always":
		return true
	default:
		return !failedAlready
	}
}
