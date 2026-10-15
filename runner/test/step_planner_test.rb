# frozen_string_literal: true

require "test_helper"

class StepPlannerTest < Minitest::Test
  def test_plan_names_follow_server_convention
    steps = [
      { "type" => "checkout" },
      { "type" => "run", "name" => "Bundle", "command" => "bundle install" },
      { "type" => "save_cache", "keys" => ["k"], "paths" => [] }
    ]
    plan = ForgeCIRunner::StepPlanner.plan(steps)
    assert_equal %w[checkout Bundle save_cache], plan.map(&:name)
    assert_equal [0, 1, 2], plan.map(&:index)
  end

  def test_display_name_falls_back_to_type_then_step
    assert_equal "checkout",
                 ForgeCIRunner::StepPlanner.display_name({ "type" => "checkout" })
    assert_equal "step",
                 ForgeCIRunner::StepPlanner.display_name({})
  end

  def test_runnable_matrix
    p = ForgeCIRunner::StepPlanner
    on_success = { "type" => "run", "when" => "on_success" }
    on_fail = { "type" => "run", "when" => "on_fail" }
    always = { "type" => "run", "when" => "always" }
    defaulted = { "type" => "run" } # compiler default
    plain = { "type" => "checkout" } # no `when` key at all

    refute p.runnable?(on_success, true)
    assert p.runnable?(on_success, false)

    assert p.runnable?(on_fail, true)
    refute p.runnable?(on_fail, false)

    assert p.runnable?(always, true)
    assert p.runnable?(always, false)

    refute p.runnable?(defaulted, true)
    assert p.runnable?(defaulted, false)

    refute p.runnable?(plain, true)
    assert p.runnable?(plain, false)
  end

  def test_unknown_when_defaults_to_on_success_semantics
    p = ForgeCIRunner::StepPlanner
    weird = { "type" => "run", "when" => "sometimes" }
    refute p.runnable?(weird, true)
    assert p.runnable?(weird, false)
  end
end
