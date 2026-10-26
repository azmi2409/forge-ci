package config

import (
	"strings"
	"testing"
)

func testEnv(pairs map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) {
		v, ok := pairs[k]
		return v, ok
	}
}

func required() map[string]string {
	return map[string]string{
		"CONTROL_PLANE_URL": "https://ci.example.com///",
		"RUNNER_TOKEN":      "tok-1234567890",
	}
}

func TestDefaults(t *testing.T) {
	c, err := fromEnv(testEnv(required()))
	if err != nil {
		t.Fatal(err)
	}
	if c.ControlPlaneURL != "https://ci.example.com" {
		t.Fatalf("url trailing slashes: %q", c.ControlPlaneURL)
	}
	if c.PollInterval != 5 || c.MaxIdleInterval != 60 || c.HeartbeatInterval != 15 {
		t.Fatalf("intervals: %v %v %v", c.PollInterval, c.MaxIdleInterval, c.HeartbeatInterval)
	}
	if c.LogChunkSize != 65536 || c.LogFlushInterval != 1 || c.RedactMinLength != 8 {
		t.Fatalf("log/redact: %d %v %d", c.LogChunkSize, c.LogFlushInterval, c.RedactMinLength)
	}
	if c.DockerBin != "docker" || c.DockerSocketPath != "/var/run/docker.sock" {
		t.Fatalf("bins: %q %q", c.DockerBin, c.DockerSocketPath)
	}
	if c.StepNoOutputTimeout != 600 || c.JobTimeout != 3600 {
		t.Fatalf("timeouts: %v %v", c.StepNoOutputTimeout, c.JobTimeout)
	}
	if c.AllowDockerSocket || c.RequeueOnShutdown || c.IdleShutdownAfter != 0 {
		t.Fatal("flag defaults must be off")
	}
	if c.ResourceClass != "" || c.BuildxBin != "" {
		t.Fatal("optional strings default to empty")
	}
}

func TestRequiredAndTokenFile(t *testing.T) {
	if _, err := fromEnv(testEnv(map[string]string{})); err == nil || !strings.Contains(err.Error(), "CONTROL_PLANE_URL") {
		t.Fatalf("missing url error: %v", err)
	}
	env := map[string]string{"CONTROL_PLANE_URL": "https://x"}
	if _, err := fromEnv(testEnv(env)); err == nil || !strings.Contains(err.Error(), "RUNNER_TOKEN") {
		t.Fatalf("missing token error: %v", err)
	}

	env["RUNNER_TOKEN_FILE"] = "testdata/token.txt"
	c, err := fromEnv(testEnv(env))
	if err != nil {
		t.Fatal(err)
	}
	if c.RunnerToken != "file-token-abcdef" {
		t.Fatalf("token from file: %q", c.RunnerToken)
	}

	env["RUNNER_TOKEN_FILE"] = "testdata/missing.txt"
	if _, err := fromEnv(testEnv(env)); err == nil || !strings.Contains(err.Error(), "RUNNER_TOKEN_FILE") {
		t.Fatalf("missing token file error: %v", err)
	}
}

func TestBooleanParsing(t *testing.T) {
	for _, v := range []string{"1", "true", "yes", "TRUE", " Yes "} {
		c, err := fromEnv(testEnv(with("ALLOW_DOCKER_SOCKET", v)))
		if err != nil {
			t.Fatal(err)
		}
		if !c.AllowDockerSocket {
			t.Errorf("ALLOW_DOCKER_SOCKET=%q should be true", v)
		}
	}
	for _, v := range []string{"", "0", "false", "no", "on", "2"} {
		c, err := fromEnv(testEnv(with("ALLOW_DOCKER_SOCKET", v)))
		if err != nil {
			t.Fatal(err)
		}
		if c.AllowDockerSocket {
			t.Errorf("ALLOW_DOCKER_SOCKET=%q should be false", v)
		}
	}
}

func TestRubyStyleNumberParsing(t *testing.T) {
	// Ruby to_f/to_i semantics: prefix parse, garbage is 0.
	cases := []struct {
		v    string
		want float64
	}{
		{"5", 5}, {"0.5", 0.5}, {"5abc", 5}, {"abc", 0}, {"", 0}, {"-3x", -3},
	}
	for _, tc := range cases {
		c, err := fromEnv(testEnv(with("POLL_INTERVAL", tc.v)))
		if err != nil {
			t.Fatal(err)
		}
		if c.PollInterval != tc.want {
			t.Errorf("POLL_INTERVAL=%q -> %v want %v", tc.v, c.PollInterval, tc.want)
		}
	}
	// Unset uses the default.
	c, err := fromEnv(testEnv(required()))
	if err != nil {
		t.Fatal(err)
	}
	if c.PollInterval != 5 {
		t.Fatalf("default poll interval: %v", c.PollInterval)
	}
}

func with(key, val string) map[string]string {
	m := required()
	m[key] = val
	return m
}
