# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class ConfigTest < Minitest::Test
  def test_requires_control_plane_url
    err = assert_raises(ForgeCIRunner::Config::Error) do
      ForgeCIRunner::Config.from_env({ "RUNNER_TOKEN" => "t" })
    end
    assert_match(/CONTROL_PLANE_URL/, err.message)
  end

  def test_requires_runner_token
    err = assert_raises(ForgeCIRunner::Config::Error) do
      ForgeCIRunner::Config.from_env({ "CONTROL_PLANE_URL" => "http://x" })
    end
    assert_match(/RUNNER_TOKEN/, err.message)
  end

  def test_runner_token_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "runner-token")
      File.write(path, "from-file\n")
      config = ForgeCIRunner::Config.from_env({ "CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN_FILE" => path })
      assert_equal "from-file", config.runner_token

      config = ForgeCIRunner::Config.from_env({ "CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN" => "env", "RUNNER_TOKEN_FILE" => path })
      assert_equal "env", config.runner_token, "RUNNER_TOKEN wins"
    end
    err = assert_raises(ForgeCIRunner::Config::Error) do
      ForgeCIRunner::Config.from_env({ "CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN_FILE" => "/nope/missing" })
    end
    assert_match(/RUNNER_TOKEN_FILE/, err.message)
  end

  def test_empty_resource_class_means_any
    config = ForgeCIRunner::Config.from_env({ "CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN" => "t", "RESOURCE_CLASS" => "" })
    assert_nil config.resource_class
  end

  def test_defaults
    cfg = ForgeCIRunner::Config.from_env(
      { "CONTROL_PLANE_URL" => "https://ci.example.com/",
        "RUNNER_TOKEN" => "secret" }
    )
    assert_equal "https://ci.example.com", cfg.control_plane_url # trailing slash stripped
    assert_equal "secret", cfg.runner_token
    assert_nil cfg.resource_class
    assert_equal 5.0, cfg.poll_interval
    assert_equal 60.0, cfg.max_idle_interval
    assert_equal 15.0, cfg.heartbeat_interval
    assert_equal 65_536, cfg.log_chunk_size
    assert_nil cfg.checkout_repo_url
    assert_equal 8, cfg.redact_min_length
    assert_equal "docker", cfg.docker_bin
  end

  def test_overrides
    cfg = ForgeCIRunner::Config.from_env(
      { "CONTROL_PLANE_URL" => "http://localhost:3000",
        "RUNNER_TOKEN" => "t",
        "RESOURCE_CLASS" => "medium",
        "POLL_INTERVAL" => "2",
        "CHECKOUT_REPO_URL" => "https://github.com/o/r.git" }
    )
    assert_equal "medium", cfg.resource_class
    assert_equal 2.0, cfg.poll_interval
    assert_equal "https://github.com/o/r.git", cfg.checkout_repo_url
  end
end
