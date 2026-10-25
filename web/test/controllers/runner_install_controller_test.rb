# frozen_string_literal: true

require "test_helper"
require "rubygems/package"

class RunnerInstallControllerTest < ActionDispatch::IntegrationTest
  test "the install script is public and points at this control plane" do
    get "/install-runner", headers: { "Host" => "ci.example.com" }
    assert_response :ok
    assert_match %r{\A#!/bin/sh}, response.body
    assert_match 'CONTROL_PLANE_URL="http://ci.example.com"', response.body
    assert_includes response.media_type, "shellscript"
  end

  test "the install script is valid sh" do
    get "/install-runner"
    Tempfile.create(["install", ".sh"]) do |f|
      f.write(response.body)
      f.flush
      assert system("sh", "-n", f.path), "sh -n failed"
    end
  end

  test "the install script skips packages on a baked image and waits for the dpkg lock" do
    get "/install-runner"
    body = response.body
    assert_includes body, 'if command -v docker >/dev/null && command -v ruby >/dev/null; then'
    assert_includes body, "Docker and Ruby already installed"
    assert_includes body, "apt-get -o DPkg::Lock::Timeout=300 update -q"
    assert_includes body, "apt-get -o DPkg::Lock::Timeout=300 install -y -q"
    assert_not_includes body, "\n  apt-get update", "every apt-get call waits for the lock"
  end

  test "--requeue-on-shutdown writes REQUEUE_ON_SHUTDOWN=1 to the runner env" do
    get "/install-runner"
    body = response.body
    assert_includes body, "--requeue-on-shutdown) REQUEUE_ON_SHUTDOWN=1; shift ;;"
    assert_includes body, '[ "$REQUEUE_ON_SHUTDOWN" -eq 1 ] && echo "REQUEUE_ON_SHUTDOWN=1"'
    assert_match(%r{--requeue-on-shutdown\n(#.*\n)*#.*Spot/preemptible}, body, "documented in the Options header")
  end

  test "--implementation=go installs the static binary with integrity checks" do
    get "/install-runner"
    body = response.body
    # Ruby stays the default; go is opt-in.
    assert_includes body, 'IMPL="ruby"'
    assert_includes body, '--implementation) IMPL="${2:?--implementation needs go or ruby}"; shift 2 ;;'
    # Unsupported architectures are rejected before anything is touched.
    assert_includes body, "unsupported architecture $(uname -m) for the Go runner"
    # The go path verifies integrity and runnability before the swap.
    assert_includes body, "sha256sum -c --ignore-missing SHA256SUMS"
    assert_includes body, '"$BIN_NEW" --version >/dev/null 2>&1'
    # One runner identity at a time: the service stops before the swap.
    assert_match(/systemctl stop forge-ci-runner.*\n.*mv \/opt\/forge-ci-runner\.new \/opt\/forge-ci-runner/m, body)
    # The Go unit runs the binary directly (no ruby).
    assert_includes body, "ExecStart=/opt/forge-ci-runner/bin/forge-ci-runner\n"
    # The ruby unit is unchanged.
    assert_includes body, "ExecStart=/usr/bin/env ruby /opt/forge-ci-runner/bin/forge-ci-runner"
  end

  test "the runner tarball has the runner code with its executable bits" do
    get "/runner.tar.gz"
    assert_response :ok
    entries = {}
    Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(response.body))) do |tar|
      tar.each { |e| entries[e.full_name] = e.header.mode }
    end
    assert entries.key?("bin/forge-ci-runner")
    assert entries.key?("lib/forge_ci_runner/runner.rb")
    assert entries.key?("bin/forge-ci-asg-terminate-self")
    assert_equal 0o755, entries["bin/forge-ci-runner"] & 0o755
    # Go binaries ship when the web image built them; the archive must never
    # break when they are absent (local dev without a docker build).
    if entries.key?("bin/SHA256SUMS")
      assert entries.key?("bin/forge-ci-runner-linux-amd64")
      assert entries.key?("bin/forge-ci-runner-linux-arm64")
    end
  end
end
