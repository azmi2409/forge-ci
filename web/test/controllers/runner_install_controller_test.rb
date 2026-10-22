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
