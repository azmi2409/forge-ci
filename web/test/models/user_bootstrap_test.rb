# frozen_string_literal: true

require "test_helper"

class UserBootstrapTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @old = ENV.to_h.slice("FORGE_CI_DATA_DIR", "FORGE_CI_UI_USER", "FORGE_CI_UI_PASSWORD")
    ENV["FORGE_CI_DATA_DIR"] = @dir
    ENV.delete("FORGE_CI_UI_USER")
    ENV.delete("FORGE_CI_UI_PASSWORD")
  end

  teardown do
    %w[FORGE_CI_DATA_DIR FORGE_CI_UI_USER FORGE_CI_UI_PASSWORD].each { |k| @old.key?(k) ? ENV[k] = @old[k] : ENV.delete(k) }
    FileUtils.rm_rf(@dir)
  end

  def in_production
    previous = Rails.env
    Rails.env = "production"
    yield
  ensure
    Rails.env = previous
  end

  test "production without credentials creates admin with a generated, saved password" do
    user, password = in_production { User.bootstrap_admin_from_env! }
    assert user.admin?
    assert_equal "admin", user.username
    assert_equal 20, password.length
    assert_equal password, File.read(User.initial_password_path).strip
    assert_equal user, User.authenticate("admin", password)

    assert_nil in_production { User.bootstrap_admin_from_env! }, "only while there are no users"
    User.forget_initial_password!
    assert_not File.exist?(User.initial_password_path)
  end

  test "FORGE_CI_UI_USER and FORGE_CI_UI_PASSWORD win and nothing is saved" do
    ENV["FORGE_CI_UI_USER"] = "ops"
    ENV["FORGE_CI_UI_PASSWORD"] = "chosen-password-123"
    user, password = in_production { User.bootstrap_admin_from_env! }
    assert_equal "ops", user.username
    assert_nil password
    assert_not File.exist?(User.initial_password_path)
  end
end
