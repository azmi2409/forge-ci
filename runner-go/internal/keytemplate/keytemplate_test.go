package keytemplate

import (
	"strings"
	"testing"
)

func TestChecksum(t *testing.T) {
	var warns []string
	got := Resolve("gems-v1-{{ checksum \"Gemfile.lock\" }}", Options{
		Checksum: func(rel string) string {
			if rel != "Gemfile.lock" {
				t.Errorf("checksum path %q", rel)
			}
			return "abc123"
		},
		Warn: func(m string) { warns = append(warns, m) },
	})
	if got != "gems-v1-abc123" {
		t.Fatalf("got %q", got)
	}
	if len(warns) != 0 {
		t.Fatalf("warns: %v", warns)
	}
}

func TestChecksumMissingWarnsAndEmpties(t *testing.T) {
	var warns []string
	got := Resolve("k-{{ checksum \"missing.lock\" }}", Options{
		Checksum: func(string) string { return "" },
		Warn:     func(m string) { warns = append(warns, m) },
	})
	if got != "k-" {
		t.Fatalf("got %q", got)
	}
	if len(warns) != 1 || !strings.Contains(warns[0], "missing.lock") {
		t.Fatalf("warns: %v", warns)
	}
}

func TestBranchAndEpoch(t *testing.T) {
	epoch := int64(1700000000)
	got := Resolve("{{ .Branch }}-{{ epoch }}", Options{Branch: "feat/x", Epoch: &epoch})
	if got != "feat/x-1700000000" {
		t.Fatalf("got %q", got)
	}
	if Resolve("{{ epoch }}", Options{Epoch: &epoch}) != "1700000000" {
		t.Fatal("epoch override")
	}
	if Resolve("{{ .Branch }}", Options{}) != "" {
		t.Fatal("no branch -> empty")
	}
}

func TestUnknownTemplatePreserved(t *testing.T) {
	var warns []string
	in := "k-{{ .Environment }}-{{ checksum \"a\" }}"
	got := Resolve(in, Options{
		Checksum: func(string) string { return "zz" },
		Warn:     func(m string) { warns = append(warns, m) },
	})
	if got != "k-{{ .Environment }}-zz" {
		t.Fatalf("got %q", got)
	}
	if len(warns) != 1 || !strings.Contains(warns[0], ".Environment") {
		t.Fatalf("warns: %v", warns)
	}
}

func TestWhitespaceInsideBraces(t *testing.T) {
	got := Resolve("{{  .Branch  }}", Options{Branch: "main"})
	if got != "main" {
		t.Fatalf("got %q", got)
	}
}
