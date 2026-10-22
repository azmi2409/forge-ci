# frozen_string_literal: true

require "test_helper"

class ForgeCISecretsTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    ForgeCISecrets.reset!
  end

  teardown do
    ForgeCISecrets.reset!
    FileUtils.rm_rf(@dir)
  end

  def fetch(name, env = {})
    ForgeCISecrets.fetch(name, env: env, generate: true, dir: @dir)
  end

  test "generates every secret once, keeps it private and returns the same value later" do
    first = ForgeCISecrets::SECRETS.keys.to_h { |name| [name, fetch(name)] }
    assert first.values.all?(&:present?)
    assert_equal 128, first["secret_key_base"].length
    assert_equal 0o600, File.stat(File.join(@dir, "secrets.yml")).mode & 0o777

    ForgeCISecrets.reset! # a new process
    assert_equal first, ForgeCISecrets::SECRETS.keys.to_h { |name| [name, fetch(name)] }
  end

  test "an environment variable wins over the stored value" do
    fetch("admin_token")
    assert_equal "from-env", fetch("admin_token", { "FORGE_CI_ADMIN_TOKEN" => "from-env" })
  end

  test "nothing is generated or written outside production" do
    assert_nil ForgeCISecrets.fetch("admin_token", env: { "RAILS_ENV" => "test" }, dir: @dir)
    assert_empty Dir.children(@dir)
  end

  test "publishes the runner token in use for runners sharing the volume" do
    env = { "RAILS_ENV" => "production" }
    ForgeCISecrets.publish_runner_token!(env: env, dir: @dir)
    generated = File.read(File.join(@dir, "runner-token")).strip
    assert_equal fetch("runner_token"), generated

    ForgeCISecrets.publish_runner_token!(env: env.merge("FORGE_CI_RUNNER_TOKEN" => "chosen"), dir: @dir)
    assert_equal "chosen", File.read(File.join(@dir, "runner-token")).strip
  end
end
