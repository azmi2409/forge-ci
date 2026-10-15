# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "forge_ci_runner"

def docker_available?
  system("docker info > /dev/null 2>&1")
end
