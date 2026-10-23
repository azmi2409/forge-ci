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
  end
end
