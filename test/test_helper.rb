# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "forge_ci"
require "minitest/autorun"
require "json"

FIXTURES_DIR = File.expand_path("fixtures", __dir__)

def fixture(name)
  File.read(File.join(FIXTURES_DIR, name))
end
