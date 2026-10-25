// forge-ci-runner: the Docker runner daemon for ForgeCI. Polls the control
// plane, claims jobs, executes them in Docker containers. Host target is
// Linux; darwin builds exist for tests and local development only.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/azmi2409/forge-ci/runner-go/internal/config"
	"github.com/azmi2409/forge-ci/runner-go/internal/executor"
	"github.com/azmi2409/forge-ci/runner-go/internal/runner"
	"github.com/azmi2409/forge-ci/runner-go/internal/version"
)

func main() {
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version.Version)
		return
	}

	cfg, err := config.FromEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "forge-ci-runner: %v\n", err)
		os.Exit(2)
	}
	if !executor.DockerAvailable(cfg.DockerBin) {
		fmt.Fprintf(os.Stderr, "forge-ci-runner: docker is not available (`%s info` failed)\n", cfg.DockerBin)
		os.Exit(2)
	}

	client := apiClient(cfg)
	if err := runner.New(cfg, client).Run(mainContext()); err != nil {
		if !isUnauthorized(err) {
			fmt.Fprintf(os.Stderr, "forge-ci-runner: %v\n", err)
		}
		os.Exit(1)
	}
}
