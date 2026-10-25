// Package config reads runner configuration from the environment, matching
// the Ruby runner's keys, defaults, and parse semantics (Ruby's to_f/to_i
// prefix-parsing: "5abc" is 5, garbage is 0).
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	ControlPlaneURL     string
	RunnerToken         string
	ResourceClass       string // "" = any
	PollInterval        float64
	MaxIdleInterval     float64
	HeartbeatInterval   float64
	LogChunkSize        int
	LogFlushInterval    float64
	CheckoutRepoURL     string
	RedactMinLength     int
	DockerBin           string
	BuildxBin           string // "" = none
	StepNoOutputTimeout float64
	JobTimeout          float64
	IdleShutdownAfter   float64
	IdleShutdownCommand string
	AllowDockerSocket   bool
	DockerSocketPath    string
	RequeueOnShutdown   bool
}

// FromEnv builds the config, failing fast on missing required values.
func FromEnv() (*Config, error) {
	return fromEnv(os.LookupEnv)
}

func fromEnv(env func(string) (string, bool)) (*Config, error) {
	url := strings.TrimRight(envGet(env, "CONTROL_PLANE_URL"), "/")
	if url == "" {
		return nil, fmt.Errorf("CONTROL_PLANE_URL is required")
	}
	token, err := runnerToken(env)
	if err != nil {
		return nil, err
	}

	c := &Config{
		ControlPlaneURL:     url,
		RunnerToken:         token,
		ResourceClass:       envGet(env, "RESOURCE_CLASS"),
		PollInterval:        envFloat(env, "POLL_INTERVAL", 5),
		MaxIdleInterval:     envFloat(env, "MAX_IDLE_INTERVAL", 60),
		HeartbeatInterval:   envFloat(env, "HEARTBEAT_INTERVAL", 15),
		LogChunkSize:        envInt(env, "LOG_CHUNK_SIZE", 65536),
		LogFlushInterval:    envFloat(env, "LOG_FLUSH_INTERVAL", 1),
		CheckoutRepoURL:     envGet(env, "CHECKOUT_REPO_URL"),
		RedactMinLength:     envInt(env, "REDACT_MIN_LENGTH", 8),
		DockerBin:           envDefault(env, "DOCKER_BIN", "docker"),
		BuildxBin:           envGet(env, "BUILDX_BIN"),
		StepNoOutputTimeout: envFloat(env, "STEP_NO_OUTPUT_TIMEOUT", 600),
		JobTimeout:          envFloat(env, "JOB_TIMEOUT", 3600),
		IdleShutdownAfter:   envFloat(env, "IDLE_SHUTDOWN_AFTER", 0),
		IdleShutdownCommand: envGet(env, "IDLE_SHUTDOWN_COMMAND"),
		AllowDockerSocket:   envBool(env, "ALLOW_DOCKER_SOCKET"),
		DockerSocketPath:    envDefault(env, "DOCKER_SOCKET_PATH", "/var/run/docker.sock"),
		RequeueOnShutdown:   envBool(env, "REQUEUE_ON_SHUTDOWN"),
	}
	if c.LogChunkSize <= 0 {
		c.LogChunkSize = 65536
	}
	return c, nil
}

func runnerToken(env func(string) (string, bool)) (string, error) {
	if t := envGet(env, "RUNNER_TOKEN"); t != "" {
		return t, nil
	}
	path := envGet(env, "RUNNER_TOKEN_FILE")
	if path == "" {
		return "", fmt.Errorf("RUNNER_TOKEN is required — set it to the same secret as " +
			"the server's FORGE_CI_RUNNER_TOKEN (e.g. `openssl rand -hex 32`)")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("RUNNER_TOKEN_FILE %s: %v", path, err)
	}
	t := strings.TrimSpace(string(b))
	if t == "" {
		return "", fmt.Errorf("RUNNER_TOKEN_FILE %s: file is empty", path)
	}
	return t, nil
}

func envGet(env func(string) (string, bool), key string) string {
	v, _ := env(key)
	return v
}

func envDefault(env func(string) (string, bool), key, def string) string {
	if v := envGet(env, key); v != "" {
		return v
	}
	return def
}

// envFloat mirrors Ruby's `(env[k] || def).to_f`: the default applies only
// when the variable is unset; an explicitly empty value parses to 0.
func envFloat(env func(string) (string, bool), key string, def float64) float64 {
	v, ok := env(key)
	if !ok {
		return def
	}
	return rubyToFloat(v)
}

func envInt(env func(string) (string, bool), key string, def int) int {
	v, ok := env(key)
	if !ok {
		return def
	}
	return int(rubyToFloat(v))
}

// envBool matches the Ruby runner: "1", "true", "yes" (case-insensitive,
// trimmed) are true.
func envBool(env func(string) (string, bool), key string) bool {
	switch strings.ToLower(strings.TrimSpace(envGet(env, key))) {
	case "1", "true", "yes":
		return true
	}
	return false
}

// rubyToFloat parses the leading numeric prefix like Ruby's to_f.
func rubyToFloat(s string) float64 {
	s = strings.TrimLeft(s, " \t\n\v\f\r")
	end := 0
	seenDigit := false
	for i := 0; i < len(s); i++ {
		ch := s[i]
		switch {
		case ch >= '0' && ch <= '9':
			seenDigit = true
			end = i + 1
		case (ch == '+' || ch == '-') && i == 0:
		case ch == '.':
		case (ch == 'e' || ch == 'E') && seenDigit:
		default:
			return parseFloatPrefix(s[:end], seenDigit)
		}
	}
	return parseFloatPrefix(s[:end], seenDigit)
}

func parseFloatPrefix(s string, seenDigit bool) float64 {
	if !seenDigit {
		return 0
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0
	}
	return f
}
