# frozen_string_literal: true

require "psych"

require_relative "forge_ci/errors"
require_relative "forge_ci/interpolator"
require_relative "forge_ci/dag"
require_relative "forge_ci/validator"
require_relative "forge_ci/ir"
require_relative "forge_ci/compiler"

# ForgeCI — an open-source, CircleCI-compatible CI toolkit.
#
# This gem (component 1 of the ForgeCI project) is the config compiler:
# it turns a `.circleci/config.yml`-style YAML document into a normalized,
# JSON-serializable intermediate representation (IR) that a scheduler and
# runner can execute. Pure Ruby, stdlib only, no network, no processes.
module ForgeCI
  VERSION = "0.6.0"
end
