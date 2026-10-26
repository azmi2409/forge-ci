# frozen_string_literal: true

require "test_helper"
require "rubygems/package"
require "open3"

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

  test "buildx failure leaves the running installation and configuration untouched" do
    run_installer(failure: "buildx") do |root, output, status|
      assert_not status.success?, output
      assert_previous_installation(root)
      assert_not_includes File.read("#{root}/systemctl.log"), "stop forge-ci-runner"
    end
  end

  test "failed activation restores the previous runner unit and environment" do
    %w[restart inactive].each do |failure|
      run_installer(failure: failure) do |root, output, status|
        assert_not status.success?, output
        assert_previous_installation(root)
        assert_equal "active", File.read("#{root}/active")
        assert_includes output, "restoring the previous installation"
        assert_not_includes output, "runner installed and started"
      end
    end
  end

  test "failed first activation removes new installation and configuration" do
    run_installer(failure: "restart", installed: false) do |root, output, status|
      assert_not status.success?, output
      assert_not File.exist?("#{root}/opt/forge-ci-runner")
      assert_not File.exist?("#{root}/etc/forge-ci-runner.env")
      assert_not File.exist?("#{root}/etc/systemd/system/forge-ci-runner.service")
      assert_not_includes output, "runner installed and started"
    end
  end

  test "successful upgrade retains the previous installation and both configuration backups" do
    run_installer do |root, output, status|
      assert status.success?, output
      assert_equal "old runner", File.read("#{root}/opt/forge-ci-runner.old/bin/forge-ci-runner")
      assert_equal "old environment", File.read("#{root}/etc/forge-ci-runner.env.bak")
      assert_equal "old unit", File.read("#{root}/etc/systemd/system/forge-ci-runner.service.bak")
      assert_includes File.read("#{root}/etc/systemd/system/forge-ci-runner.service"), "Description=ForgeCI runner (Go)"
      assert_equal "active", File.read("#{root}/active")
      assert_includes output, "runner installed and started"
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
    # Go binaries ship when the web image built them; the archive must never
    # break when they are absent (local dev without a docker build).
    if entries.key?("bin/SHA256SUMS")
      assert entries.key?("bin/forge-ci-runner-linux-amd64")
      assert entries.key?("bin/forge-ci-runner-linux-arm64")
    end
  end

  test "concurrent archive builders publish a complete runner archive" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/bin")
      content = Random.new(1).bytes(512 * 1024)
      File.binwrite("#{root}/bin/runner", content)
      dest = "#{root}/runner.tar.gz"
      gate = Queue.new
      builders = 8.times.map do
        Thread.new do
          gate.pop
          RunnerInstallController.build_tarball(root, dest)
        end
      end
      builders.each { gate << true }
      builders.each(&:value)
      Zlib::GzipReader.open(dest) do |gz|
        Gem::Package::TarReader.new(gz) do |tar|
          tar.each do |entry|
            assert_equal content, entry.read if entry.full_name == "bin/runner"
          end
        end
      end
    end
  end

  private

  def assert_previous_installation(root)
    assert_equal "old runner", File.read("#{root}/opt/forge-ci-runner/bin/forge-ci-runner")
    assert_equal "old environment", File.read("#{root}/etc/forge-ci-runner.env")
    assert_equal "old unit", File.read("#{root}/etc/systemd/system/forge-ci-runner.service")
  end

  def run_installer(failure: "", installed: true)
    get "/install-runner"
    Dir.mktmpdir("installer") do |root|
      FileUtils.mkdir_p(["#{root}/commands", "#{root}/opt/forge-ci-runner/bin", "#{root}/etc/systemd/system"])
      if installed
        File.write("#{root}/opt/forge-ci-runner/bin/forge-ci-runner", "old runner")
        File.write("#{root}/etc/forge-ci-runner.env", "old environment")
        File.write("#{root}/etc/systemd/system/forge-ci-runner.service", "old unit")
      else
        FileUtils.rm_rf("#{root}/opt/forge-ci-runner")
      end
      File.write("#{root}/active", installed ? "active" : "inactive")
      commands = {
        "id" => "echo 0",
        "uname" => "echo x86_64",
        "docker" => "exit 0",
        "sha256sum" => "exit 0",
        "curl" => <<~'SH',
          case "$*" in
            *buildx*)
              [ "$FAILURE" != buildx ] || exit 1
              while [ "$1" != -o ]; do shift; done
              printf '#!/bin/sh\nexit 0\n' > "$2"
              ;;
            *) echo archive ;;
          esac
        SH
        "tar" => <<~'SH',
          cat >/dev/null
          mkdir -p "$3/bin"
          printf '#!/bin/sh\necho test-version\n' > "$3/bin/forge-ci-runner-linux-amd64"
        SH
        "systemctl" => <<~'SH'
          echo "$*" >> "$STUB_ROOT/systemctl.log"
          case "$1 $2" in
            "is-active "*) [ "$(cat "$STUB_ROOT/active")" = active ] ;;
            "stop forge-ci-runner") printf inactive > "$STUB_ROOT/active" ;;
            "restart forge-ci-runner")
              if [ ! -f "$STUB_ROOT/activation-attempted" ]; then
                touch "$STUB_ROOT/activation-attempted"
                [ "$FAILURE" != restart ] || exit 1
                [ "$FAILURE" != inactive ] || exit 0
              fi
              printf active > "$STUB_ROOT/active"
              ;;
          esac
        SH
      }
      commands.each do |name, body|
        path = "#{root}/commands/#{name}"
        File.write(path, "#!/bin/sh\n#{body}\n")
        File.chmod(0o755, path)
      end
      script = response.body.gsub("/opt/forge-ci-runner", "#{root}/opt/forge-ci-runner").gsub("/etc/", "#{root}/etc/")
      File.write("#{root}/install.sh", script)
      output, status = Open3.capture2e({ "PATH" => "#{root}/commands:#{ENV.fetch('PATH')}", "STUB_ROOT" => root, "FAILURE" => failure },
        "sh", "#{root}/install.sh", "--token", "new-token", "--implementation", "go", "--allow-docker")
      yield root, output, status
    end
  end
end
