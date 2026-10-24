# frozen_string_literal: true

require "rake/testtask"
require "bundler/gem_tasks" # rake build | install (builds + puts forge-ci on PATH) | release

Rake::TestTask.new do |t|
  t.libs << "lib" << "test"
  t.pattern = "test/**/*_test.rb"
  t.warning = false
end

task default: :test
