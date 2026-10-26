package redact

import (
	"strings"
	"testing"
)

func TestRedactsLongestFirst(t *testing.T) {
	r := New(map[string]string{
		"SHORT": "s3cr3t",
		"LONG":  "s3cr3t-value-long",
		"TINY":  "x",
		"EMPTY": "",
	}, 6)
	// "s3cr3t-value-long" must be replaced before its prefix "s3cr3t".
	in := "token=s3cr3t-value-long and token=s3cr3t and x stays"
	want := "token=[REDACTED] and token=[REDACTED] and x stays"
	if got := r.Redact(in); got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestMinLength(t *testing.T) {
	r := New(map[string]string{"A": "test", "B": "longenough"}, 6)
	if got := r.Redact("test longenough"); got != "test [REDACTED]" {
		t.Fatalf("got %q", got)
	}
	if r.PatternCount() != 1 {
		t.Fatalf("pattern count %d", r.PatternCount())
	}
}

func TestEmptyAndNoSecrets(t *testing.T) {
	r := New(map[string]string{}, 8)
	if r.Redact("anything") != "anything" {
		t.Fatal("no secrets must be identity")
	}
	if r.MaxSecretLen() != 0 {
		t.Fatal("max secret len 0")
	}
}

func TestDuplicatesCollapse(t *testing.T) {
	r := New(map[string]string{"A": "same-secret", "B": "same-secret"}, 4)
	if r.PatternCount() != 1 {
		t.Fatalf("duplicates must collapse: %d", r.PatternCount())
	}
}

func TestMaxSecretLen(t *testing.T) {
	r := New(map[string]string{"A": "short", "B": "the-longest-secret-value"}, 4)
	if r.MaxSecretLen() != len("the-longest-secret-value") {
		t.Fatalf("max len %d", r.MaxSecretLen())
	}
	if !strings.Contains(RedactText(r, "the-longest-secret-value"), Replacement) {
		t.Fatal("sanity")
	}
}

// RedactText is a tiny indirection so the test doesn't re-implement the loop.
func RedactText(r *Redactor, s string) string { return r.Redact(s) }
