# frozen_string_literal: true

require "test_helper"

class BackoffTest < Minitest::Test
  def test_geometric_progression_with_cap
    b = ForgeCIRunner::Backoff.new(base: 5.0, max: 60.0, factor: 2.0)
    assert_equal [5.0, 10.0, 20.0, 40.0, 60.0, 60.0, 60.0],
                 Array.new(7) { b.tick }
  end

  def test_reset_returns_to_base
    b = ForgeCIRunner::Backoff.new(base: 5.0, max: 60.0)
    3.times { b.tick }
    b.reset
    assert_equal 5.0, b.tick
  end

  def test_current_reflects_next_interval
    b = ForgeCIRunner::Backoff.new(base: 5.0, max: 60.0)
    assert_equal 5.0, b.current
    b.tick
    assert_equal 10.0, b.current
  end
end
