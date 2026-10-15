# frozen_string_literal: true

require_relative "lib/forge_ci"

Gem::Specification.new do |spec|
  spec.name = "forge-ci"
  spec.version = ForgeCI::VERSION
  spec.authors = ["Azmi Muwahid"]
  spec.email = ["azmimuwahid@gmail.com"]

  spec.summary = "Open-source CircleCI-compatible CI: config compiler (v1)"
  spec.description = "Compiles CircleCI v2.1-style pipeline YAML into a normalized, " \
                     "JSON-serializable intermediate representation. Pure Ruby, stdlib only. " \
                     "Component 1 of the ForgeCI open-source CI project."
  spec.homepage = "https://github.com/azmi2409/forge-ci"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*.rb", "MIT-LICENSE", "README.md"]
  spec.require_paths = ["lib"]
end
