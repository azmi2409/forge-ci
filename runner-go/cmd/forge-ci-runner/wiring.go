package main

import (
	"context"
	"errors"

	"github.com/azmi2409/forge-ci/runner-go/internal/api"
	"github.com/azmi2409/forge-ci/runner-go/internal/config"
)

// apiClient builds the control-plane client (split out so main stays
// readable and the wiring is explicit).
func apiClient(cfg *config.Config) *api.Client {
	return api.New(cfg.ControlPlaneURL, cfg.RunnerToken)
}

// mainContext is the process root context; it is NOT the shutdown signal —
// the runner owns its lifetimes (see package runner) and the context only
// bounds process-wide resources.
func mainContext() context.Context {
	return context.Background()
}

func isUnauthorized(err error) bool {
	return errors.Is(err, api.ErrUnauthorized)
}
