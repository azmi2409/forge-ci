package tarutil

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestCreateAndExtract(t *testing.T) {
	base := t.TempDir()
	os.MkdirAll(filepath.Join(base, "out/nested"), 0o755)
	os.WriteFile(filepath.Join(base, "out/nested/a.txt"), []byte("alpha"), 0o644)
	os.WriteFile(filepath.Join(base, "out/b.txt"), []byte("beta"), 0o644)

	dest := filepath.Join(t.TempDir(), "archive.tgz")
	warns := []string{}
	err := Create(context.Background(), []string{"out"}, base, dest, func(m string) { warns = append(warns, m) })
	if err != nil {
		t.Fatal(err)
	}
	if len(warns) != 0 {
		t.Fatalf("warns: %v", warns)
	}

	extractDir := t.TempDir()
	if err := Extract(context.Background(), dest, extractDir); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(extractDir, "out/nested/a.txt"))
	if err != nil || string(b) != "alpha" {
		t.Fatalf("round trip: %v %q", err, b)
	}
}

func TestCreateSkipsMissingWithWarning(t *testing.T) {
	base := t.TempDir()
	os.WriteFile(filepath.Join(base, "present.txt"), []byte("here"), 0o644)
	dest := filepath.Join(t.TempDir(), "a.tgz")
	var warns []string
	err := Create(context.Background(), []string{"missing.txt", "present.txt"}, base, dest,
		func(m string) { warns = append(warns, m) })
	if err != nil {
		t.Fatal(err)
	}
	if len(warns) != 1 || !contains(warns[0], "missing.txt") {
		t.Fatalf("warns: %v", warns)
	}
	// The archive holds only the present file.
	extractDir := t.TempDir()
	Extract(context.Background(), dest, extractDir)
	if _, err := os.Stat(filepath.Join(extractDir, "present.txt")); err != nil {
		t.Fatal("present.txt missing from archive")
	}
}

func TestCreateNothingToArchive(t *testing.T) {
	base := t.TempDir()
	dest := filepath.Join(t.TempDir(), "a.tgz")
	err := Create(context.Background(), []string{"nope"}, base, dest, func(string) {})
	if err == nil || !contains(err.Error(), "nothing to archive") {
		t.Fatalf("err: %v", err)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(sub) == 0 || indexOf(s, sub) >= 0)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
