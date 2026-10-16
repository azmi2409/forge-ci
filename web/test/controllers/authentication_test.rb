# frozen_string_literal: true

require "test_helper"

class AuthenticationTest < ActionDispatch::IntegrationTest
  PASS = "correct-horse-battery"

  setup do
    @admin = User.create!(username: "alice", password: PASS, role: :admin)
    @member = User.create!(username: "bob", password: PASS, role: :member)
  end

  def login(username, password = PASS)
    post "/login", params: { username: username, password: password }
  end

  test "UI pages redirect to the login page when signed out" do
    %w[/projects /job_runs/1 /account /users].each do |path|
      get path
      assert_redirected_to "/login", "#{path} must require login"
    end
    get "/login"
    assert_response :ok
    assert_match "Sign in", response.body
  end

  test "landing page and health check stay public" do
    get "/"
    assert_response :ok
    get "/up"
    assert_response :ok
  end

  test "successful login lands on projects and unlocks the UI" do
    login("alice")
    assert_redirected_to "/projects"
    get "/projects"
    assert_response :ok
    assert_match "alice", response.body
  end

  test "usernames are case-insensitive, passwords are not" do
    login("ALICE")
    assert_redirected_to "/projects"
    delete "/logout"
    login("alice", PASS.upcase)
    assert_response :unprocessable_entity
  end

  test "wrong password and unknown user get the same generic error" do
    login("alice", "nope-nope-nope")
    assert_response :unprocessable_entity
    wrong = response.body[/Invalid username or password\./]
    login("ghost", "whatever-whatever")
    assert_response :unprocessable_entity
    assert_equal wrong, response.body[/Invalid username or password\./]
    assert_not_nil wrong
  end

  test "login returns to the originally requested page, but never to an external one" do
    get "/users"
    assert_redirected_to "/login"
    login("alice")
    assert_redirected_to "/users"

    delete "/logout"
    get "/login"
    # session[:return_to] can only be set server-side; verify the sanitizer directly
    ctrl = SessionsController.new
    assert_nil ctrl.send(:safe_return_path, "//evil.example.com")
    assert_nil ctrl.send(:safe_return_path, "https://evil.example.com")
    assert_nil ctrl.send(:safe_return_path, "/\\evil.example.com")
    assert_equal "/projects", ctrl.send(:safe_return_path, "/projects")
  end

  test "logout ends the session" do
    login("alice")
    delete "/logout"
    assert_redirected_to "/login"
    get "/projects"
    assert_redirected_to "/login"
  end

  test "login resets the session (no fixation)" do
    get "/login"
    before = cookies["_forge_ci_session"]
    login("alice")
    assert_not_equal before, cookies["_forge_ci_session"]
  end

  test "account locks after repeated failures, even for the right password" do
    User::MAX_FAILED_ATTEMPTS.times { login("alice", "bad-bad-bad-bad") }
    assert @admin.reload.locked?
    login("alice")
    assert_response :unprocessable_entity
    get "/projects"
    assert_redirected_to "/login"

    travel_to(User::LOCK_FOR.from_now + 1.minute) do
      login("alice")
      assert_redirected_to "/projects"
    end
  end

  test "a successful login resets the failure counter" do
    3.times { login("alice", "bad-bad-bad-bad") }
    assert_equal 3, @admin.reload.failed_attempts
    login("alice")
    assert_equal 0, @admin.reload.failed_attempts
  end

  test "sessions expire after the idle timeout" do
    login("alice")
    travel_to(SessionAuth::IDLE_TIMEOUT.from_now + 1.minute) do
      get "/projects"
      assert_redirected_to "/login"
    end
  end

  test "sessions expire after the absolute timeout even when active" do
    login("alice")
    (1..8).each do |day|
      travel_to(day.days.from_now) { get "/projects" }
    end
    travel_to(8.days.from_now) do
      get "/projects"
      assert_redirected_to "/login"
    end
  end

  test "changing a password signs out other sessions but keeps the current one" do
    login("alice")
    other = open_session
    other.post "/login", params: { username: "alice", password: PASS }
    other.get "/projects"
    assert_equal 200, other.response.status

    patch "/account", params: { current_password: PASS, password: "a-brand-new-passphrase",
                                password_confirmation: "a-brand-new-passphrase" }
    assert_redirected_to "/account"
    get "/projects"
    assert_response :ok
    other.get "/projects"
    assert_equal 302, other.response.status
    assert User.authenticate("alice", "a-brand-new-passphrase")
  end

  test "password change requires the current password, a match and the policy" do
    login("alice")
    patch "/account", params: { current_password: "wrong-wrong-wrong", password: "a-brand-new-passphrase",
                                password_confirmation: "a-brand-new-passphrase" }
    assert_response :unprocessable_entity
    patch "/account", params: { current_password: PASS, password: "a-brand-new-passphrase",
                                password_confirmation: "different-different" }
    assert_response :unprocessable_entity
    patch "/account", params: { current_password: PASS, password: "short", password_confirmation: "short" }
    assert_response :unprocessable_entity
    assert User.authenticate("alice", PASS)
  end

  test "sign out everywhere kills other sessions only" do
    login("alice")
    other = open_session
    other.post "/login", params: { username: "alice", password: PASS }
    post "/account/sign_out_everywhere"
    assert_redirected_to "/account"
    get "/projects"
    assert_response :ok
    other.get "/projects"
    assert_equal 302, other.response.status
  end

  # --- authorization ------------------------------------------------------------

  test "members cannot manage users" do
    login("bob")
    get "/users"
    assert_redirected_to "/projects"
    post "/users", params: { username: "eve", password: PASS, password_confirmation: PASS, role: "admin" }
    assert_nil User.find_by(username: "eve")
  end

  test "admins can create, edit, and delete users" do
    login("alice")
    post "/users", params: { username: "carol", password: PASS, password_confirmation: PASS, role: "member" }
    assert_redirected_to "/users"
    carol = User.find_by!(username: "carol")
    assert carol.member?

    patch "/users/#{carol.id}", params: { role: "admin", password: "", password_confirmation: "" }
    assert carol.reload.admin?
    assert User.authenticate("carol", PASS)

    patch "/users/#{carol.id}", params: { password: "another-long-passphrase",
                                          password_confirmation: "another-long-passphrase" }
    assert User.authenticate("carol", "another-long-passphrase")

    delete "/users/#{carol.id}"
    assert_nil User.find_by(username: "carol")
  end

  test "weak or mismatched passwords are rejected when creating users" do
    login("alice")
    post "/users", params: { username: "dave", password: "short", password_confirmation: "short", role: "member" }
    assert_response :unprocessable_entity
    post "/users", params: { username: "dave", password: PASS, password_confirmation: "nope", role: "member" }
    assert_response :unprocessable_entity
    assert_nil User.find_by(username: "dave")
  end

  test "you cannot delete yourself or the last admin, nor demote the last admin" do
    login("alice")
    delete "/users/#{@admin.id}"
    assert User.exists?(@admin.id)

    patch "/users/#{@admin.id}", params: { role: "member" }
    assert_response :unprocessable_entity
    assert @admin.reload.admin?

    @member.update!(role: :admin)
    patch "/users/#{@admin.id}", params: { role: "member" }
    assert @admin.reload.member?
  end

  test "an unknown role value falls back to member" do
    login("alice")
    post "/users", params: { username: "frank", password: PASS, password_confirmation: PASS, role: "superuser" }
    assert User.find_by!(username: "frank").member?
  end

  # --- browser-facing API endpoints accept the session ----------------------------

  test "log read and stream accept a signed-in session and reject anonymous requests" do
    project = Project.create!(name: "p")
    pipeline = project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    wf = pipeline.workflow_runs.create!(name: "wf", status: "running")
    job = wf.job_runs.create!(name: "j", executor: {}, status: "success")

    get "/api/v1/jobs/#{job.id}/logs"
    assert_response :unauthorized
    get "/api/v1/jobs/#{job.id}/logs/stream"
    assert_response :unauthorized

    login("bob")
    get "/api/v1/jobs/#{job.id}/logs"
    assert_response :ok
  end

  # --- bootstrap ------------------------------------------------------------------

  test "first admin is bootstrapped from FORGE_CI_UI_USER/PASSWORD when no users exist" do
    User.delete_all
    with_env("FORGE_CI_UI_USER" => "root", "FORGE_CI_UI_PASSWORD" => "pw") do
      login("root", "pw")
      assert_redirected_to "/projects"
    end
    assert User.find_by!(username: "root").admin?
  end

  test "bootstrap does nothing once a user exists" do
    with_env("FORGE_CI_UI_USER" => "root", "FORGE_CI_UI_PASSWORD" => "pw") do
      login("root", "pw")
      assert_response :unprocessable_entity
    end
    assert_nil User.find_by(username: "root")
  end

  test "login page explains how to create the first user when there are none" do
    User.delete_all
    get "/login"
    assert_match "No users exist yet", response.body
  end

  # --- model ------------------------------------------------------------------------

  test "passwords are stored as salted PBKDF2 digests, never plaintext" do
    assert_match(/\Apbkdf2\$\d+\$/, @admin.password_digest)
    assert_not_includes @admin.password_digest, PASS
    other = User.create!(username: "same-pass", password: PASS)
    assert_not_equal @admin.password_digest, other.password_digest
    assert_not_includes @admin.inspect, @admin.password_digest
  end

  test "usernames are normalized and validated" do
    assert_equal "newbie", User.create!(username: "  NewBie ", password: PASS).username
    assert_not User.new(username: "bad name!", password: PASS).valid?
    assert_not User.new(username: "alice", password: PASS).valid?
  end

  private

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end
