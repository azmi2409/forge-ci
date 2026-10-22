# frozen_string_literal: true

require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @old = ENV.to_h.slice("FORGE_CI_RUNNER_TOKEN", "GITHUB_APP_ID")
    ENV["FORGE_CI_RUNNER_TOKEN"] = "runner-secret-abc"
    ENV.delete("GITHUB_APP_ID")
  end

  teardown do
    %w[FORGE_CI_RUNNER_TOKEN GITHUB_APP_ID].each { |k| @old.key?(k) ? ENV[k] = @old[k] : ENV.delete(k) }
    Github::Manifest.converter = nil
  end

  test "admins only" do
    get "/settings"
    assert_redirected_to "/login"
    sign_in_as("member", role: :member)
    get "/settings"
    assert_not_equal 200, response.status
  end

  test "shows the runner install command and the API token" do
    sign_in_as_admin
    get "/settings"
    assert_response :ok
    assert_match %r{/install-runner \| sudo sh -s -- --token runner-secret-abc}, response.body
    assert_match TEST_ADMIN_TOKEN, response.body
    assert_match "Connect GitHub", response.body
  end

  test "Connect GitHub posts a manifest to GitHub with this server's URLs" do
    sign_in_as_admin
    post "/settings/github", params: { org: "acme" }
    assert_response :ok
    form = css_select("form#manifest-form").first
    assert_match %r{\Ahttps://github.com/organizations/acme/settings/apps/new\?state=\h{32}\z}, form["action"]
    manifest = JSON.parse(css_select("input[name=manifest]").first["value"])
    assert_equal "http://www.example.com/api/v1/github/webhooks", manifest.dig("hook_attributes", "url")
    assert_equal "http://www.example.com/settings/github/callback", manifest["redirect_url"]
    assert_equal "write", manifest.dig("default_permissions", "statuses")
    assert_equal false, manifest["public"]
  end

  test "Connect GitHub for a personal account or a named organization" do
    sign_in_as_admin
    post "/settings/github", params: { account: "personal", org: "ignored" }
    assert_match %r{\Ahttps://github.com/settings/apps/new\?state=}, css_select("form#manifest-form").first["action"]

    post "/settings/github", params: { account: "org", org: " @KilatHost " }
    assert_match %r{\Ahttps://github.com/organizations/KilatHost/settings/apps/new\?state=}, css_select("form#manifest-form").first["action"]
  end

  test "Connect GitHub for an organization needs a valid name" do
    sign_in_as_admin
    post "/settings/github", params: { account: "org", org: "" }
    assert_redirected_to "/settings"
    assert_match "Enter the name of the organization", flash[:alert]

    post "/settings/github", params: { account: "org", org: "not/an org" }
    assert_redirected_to "/settings"
    assert_match "isn't a GitHub organization name", flash[:alert]
  end

  test "once connected, shows who can install it and offers another account" do
    GithubAppCredential.create!(app_id: "1", slug: "forgeci-x", name: "ForgeCI x", owner_login: "azmi",
                                webhook_secret: "w", private_key: "k")
    sign_in_as_admin
    get "/settings"
    assert_match "can only be installed on repositories owned by", response.body
    assert_select "details.other-account form[data-github-connect] input[name=account][value=org]"
    assert_select "a[href='https://github.com/apps/forgeci-x/installations/new']"
  end

  test "the callback stores the new App and sends the user to install it" do
    sign_in_as_admin
    post "/settings/github"
    state = css_select("form#manifest-form").first["action"][/state=(\h+)/, 1]
    Github::Manifest.converter = lambda do |code|
      assert_equal "one-time-code", code
      { "id" => 4242, "slug" => "forgeci-example", "name" => "ForgeCI example", "html_url" => "https://github.com/apps/forgeci-example",
        "owner" => { "login" => "acme" }, "client_id" => "Iv1.x", "client_secret" => "cs", "webhook_secret" => "whs",
        "pem" => "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n" }
    end

    get "/settings/github/callback", params: { code: "one-time-code", state: state }
    assert_redirected_to "https://github.com/apps/forgeci-example/installations/new"
    assert_equal "4242", Github.app_id
    assert_equal "whs", Github.webhook_secret
    assert Github.configured?
    assert_not_equal "whs", GithubAppCredential.connection.select_value("SELECT webhook_secret FROM github_app_credentials"),
                     "secrets are encrypted at rest"
  end

  test "a callback with the wrong state is refused" do
    sign_in_as_admin
    post "/settings/github"
    Github::Manifest.converter = ->(_code) { flunk "must not convert" }
    get "/settings/github/callback", params: { code: "x", state: "forged" }
    assert_redirected_to "/settings"
    assert_equal 0, GithubAppCredential.count
  end

  test "environment variables take precedence over the stored App" do
    GithubAppCredential.create!(app_id: "1", slug: "s", webhook_secret: "w", private_key: "k")
    ENV["GITHUB_APP_ID"] = "999"
    assert_equal "999", Github.app_id
    assert Github.from_env?
  end
end
