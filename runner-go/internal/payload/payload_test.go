package payload

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "contract", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return b
}

// Every fixture in contract/ must decode; the golden claim payloads pin the
// wire shapes (CONTRACT.md).
func TestParseClaimFixtures(t *testing.T) {
	for _, name := range []string{
		"claim-full.json", "claim-classless.json", "claim-fork.json",
		"claim-trusted-absent.json", "steps-variants.json", "executor-nulls.json",
	} {
		t.Run(name, func(t *testing.T) {
			c, err := ParseClaim(fixture(t, name))
			if err != nil {
				t.Fatalf("ParseClaim: %v", err)
			}
			if c.ID == 0 || c.Name == "" {
				t.Fatalf("id/name not decoded: %+v", c)
			}
		})
	}
}

func TestParseClaimFull(t *testing.T) {
	c, err := ParseClaim(fixture(t, "claim-full.json"))
	if err != nil {
		t.Fatal(err)
	}
	if c.ID != 1042 || c.Name != "test (3/4)" {
		t.Fatalf("id/name: %d %q", c.ID, c.Name)
	}
	if c.NodeIndex == nil || *c.NodeIndex != 2 || c.Parallelism == nil || *c.Parallelism != 4 {
		t.Fatalf("node/parallelism: %v %v", c.NodeIndex, c.Parallelism)
	}
	if c.WorkingDirectory != "~/app" {
		t.Fatalf("workdir %q", c.WorkingDirectory)
	}
	if c.Executor == nil || c.Executor.Image != "cimg/ruby:3.2" {
		t.Fatalf("executor: %+v", c.Executor)
	}
	if c.Executor.Entrypoint == nil || *c.Executor.Entrypoint != "/bin/sh" {
		t.Fatalf("entrypoint: %v", c.Executor.Entrypoint)
	}
	if len(c.Executor.SecondaryImages) != 2 || c.Executor.SecondaryImages[0].Name == nil ||
		*c.Executor.SecondaryImages[0].Name != "db" {
		t.Fatalf("secondary images: %+v", c.Executor.SecondaryImages)
	}
	if c.Environment["FORGE_TOKEN"] != "s3cr3t-token-value-0001" {
		t.Fatalf("environment: %+v", c.Environment)
	}
	if c.Trusted == nil || !*c.Trusted {
		t.Fatalf("trusted: %v", c.Trusted)
	}
	if c.ProjectID == nil || *c.ProjectID != 12 || c.WorkflowRunID == nil || *c.WorkflowRunID != 907 {
		t.Fatalf("ids: %v %v", c.ProjectID, c.WorkflowRunID)
	}
	if c.Repository == nil || c.Repository.Token == nil || *c.Repository.Token == "" {
		t.Fatalf("repository token: %+v", c.Repository)
	}
	if c.DockerBuildCache == nil || c.DockerBuildCache.Username == nil {
		t.Fatalf("build cache: %+v", c.DockerBuildCache)
	}
	if len(c.Steps) != 9 {
		t.Fatalf("steps: %d", len(c.Steps))
	}
	// Step variants from the full fixture.
	if c.Steps[1].Name == nil || *c.Steps[1].Name != "bundle install" {
		t.Fatalf("step 1 name: %+v", c.Steps[1])
	}
	if c.Steps[1].NoOutputTimeout == nil || *c.Steps[1].NoOutputTimeout != "10m" {
		t.Fatalf("step 1 no_output_timeout: %+v", c.Steps[1])
	}
	if !c.Steps[7].Background {
		t.Fatalf("step 7 background: %+v", c.Steps[7])
	}
	if c.Steps[4].When != "always" {
		t.Fatalf("step 4 when: %q", c.Steps[4].When)
	}
	if c.Steps[3].Keys[0] != "gems-v1-{{ checksum \"Gemfile.lock\" }}" {
		t.Fatalf("save_cache key: %+v", c.Steps[3])
	}
	if c.Steps[8].Root == nil || *c.Steps[8].Root != "." {
		t.Fatalf("persist root: %+v", c.Steps[8])
	}
}

func TestParseClaimAbsenceSemantics(t *testing.T) {
	// claim-trusted-absent.json: older server — trusted/project_id/
	// workflow_run_id/docker_build_cache are ABSENT, not null.
	c, err := ParseClaim(fixture(t, "claim-trusted-absent.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !c.TrustedPipeline() {
		t.Fatal("absent trusted must be trusted")
	}
	if c.ProjectID != nil || c.WorkflowRunID != nil || c.DockerBuildCache != nil {
		t.Fatal("absent fields must stay nil")
	}

	// claim-fork.json: explicit trusted false; repository without token.
	c, err = ParseClaim(fixture(t, "claim-fork.json"))
	if err != nil {
		t.Fatal(err)
	}
	if c.TrustedPipeline() {
		t.Fatal("explicit false must be untrusted")
	}
	if c.Repository == nil || c.Repository.Token != nil {
		t.Fatalf("repository token must be absent: %+v", c.Repository)
	}
	if c.DockerBuildCache != nil {
		t.Fatal("fork must have no docker_build_cache")
	}

	// executor-nulls.json: null executor sub-fields decode as absent;
	// unauthenticated docker_build_cache (no username/password).
	c, err = ParseClaim(fixture(t, "executor-nulls.json"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Executor.Entrypoint != nil || c.Executor.Command != nil ||
		c.Executor.SecondaryImages != nil || c.Executor.Environment != nil {
		t.Fatalf("null executor fields must decode to nil: %+v", c.Executor)
	}
	if c.DockerBuildCache.Username != nil || c.DockerBuildCache.Password != nil {
		t.Fatalf("unauthenticated cache must have nil creds: %+v", c.DockerBuildCache)
	}

	// claim-classless.json: pipeline.branch null.
	c, err = ParseClaim(fixture(t, "claim-classless.json"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Pipeline.Branch != nil {
		t.Fatal("null branch must decode to nil")
	}
}

func TestParseClaimUnknownStep(t *testing.T) {
	c, err := ParseClaim(fixture(t, "steps-variants.json"))
	if err != nil {
		t.Fatal(err)
	}
	last := c.Steps[len(c.Steps)-1]
	if last.Type != "teleport_node" {
		t.Fatalf("unknown step type: %q", last.Type)
	}
	// Raw preserved so the runner can report it.
	if string(last.Raw) == "" {
		t.Fatal("unknown step raw JSON lost")
	}
	if last.Command == nil || *last.Command != "mystery" {
		t.Fatalf("unknown step fields should still decode: %+v", last)
	}
}

func TestParseClaimRejectsGarbage(t *testing.T) {
	if _, err := ParseClaim([]byte(`{"nope": 1}`)); err == nil {
		t.Fatal("payload without id must be rejected")
	}
	if _, err := ParseClaim([]byte(`not json`)); err == nil {
		t.Fatal("garbage must be rejected")
	}
}

func TestEnvStringify(t *testing.T) {
	var env Env
	if err := json.Unmarshal([]byte(`{"a":"x","b":42,"c":4.5,"d":true,"e":null,"f":""}`), &env); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"a": "x", "b": "42", "c": "4.5", "d": "true", "e": "", "f": ""}
	for k, v := range want {
		if env[k] != v {
			t.Errorf("env[%q]=%q want %q", k, env[k], v)
		}
	}
	var nulled Env
	if err := json.Unmarshal([]byte(`null`), &nulled); err != nil {
		t.Fatal(err)
	}
	if len(nulled) != 0 {
		t.Fatal("null environment must be empty")
	}
}

func TestStepKeysFallback(t *testing.T) {
	var s Step
	if err := json.Unmarshal([]byte(`{"type":"save_cache","key":"k-v1","paths":["a"]}`), &s); err != nil {
		t.Fatal(err)
	}
	if len(s.Keys) != 1 || s.Keys[0] != "k-v1" {
		t.Fatalf("key fallback: %+v", s.Keys)
	}
	var r Step
	if err := json.Unmarshal([]byte(`{"type":"restore_cache","keys":["k1","k2"]}`), &r); err != nil {
		t.Fatal(err)
	}
	if len(r.Keys) != 2 {
		t.Fatalf("keys: %+v", r.Keys)
	}
}

func TestDisplayName(t *testing.T) {
	cases := []struct {
		raw  string
		want string
	}{
		{`{"type":"run","name":"tests","command":"x"}`, "tests"},
		{`{"type":"checkout"}`, "checkout"},
		{`{"type":"","name":""}`, "step"},
	}
	for _, tc := range cases {
		var s Step
		if err := json.Unmarshal([]byte(tc.raw), &s); err != nil {
			t.Fatal(err)
		}
		if got := s.DisplayName(); got != tc.want {
			t.Errorf("DisplayName(%s)=%q want %q", tc.raw, got, tc.want)
		}
	}
}

func TestExpandWorkdir(t *testing.T) {
	cases := map[string]string{
		"":        "",
		"~/app":   "/root/app",
		"~/a/b":   "/root/a/b",
		"/opt/x":  "/opt/x",
		"~user/x": "~user/x", // only "~/" expands, like Ruby
		"~":       "~",
	}
	for in, want := range cases {
		if got := ExpandWorkdir(in); got != want {
			t.Errorf("ExpandWorkdir(%q)=%q want %q", in, got, want)
		}
	}
}
