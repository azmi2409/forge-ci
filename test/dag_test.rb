# frozen_string_literal: true

require_relative "test_helper"

class DagTest < Minitest::Test
  def test_toposort_respects_dependencies
    nodes = %w[a b c d]
    edges = { "a" => [], "b" => ["a"], "c" => ["a"], "d" => %w[b c] }
    assert_equal %w[a b c d], ForgeCI::DAG.toposort(nodes, edges)
  end

  def test_toposort_is_stable_for_independent_nodes
    nodes = %w[zebra apple mango]
    edges = { "zebra" => [], "apple" => [], "mango" => [] }
    assert_equal %w[zebra apple mango], ForgeCI::DAG.toposort(nodes, edges),
                 "ties must break by config order, not alphabetically"
  end

  def test_toposort_handles_diamond
    nodes = %w[build test-a test-b deploy]
    edges = { "build" => [], "test-a" => ["build"], "test-b" => ["build"], "deploy" => %w[test-a test-b] }
    order = ForgeCI::DAG.toposort(nodes, edges)
    assert_equal "build", order.first
    assert_equal "deploy", order.last
    assert_equal nodes.sort, order.sort
  end

  def test_find_cycle_returns_nil_for_dag
    nodes = %w[a b]
    edges = { "a" => [], "b" => ["a"] }
    assert_nil ForgeCI::DAG.find_cycle(nodes, edges)
  end

  def test_find_cycle_detects_two_node_cycle
    nodes = %w[a b]
    edges = { "a" => ["b"], "b" => ["a"] }
    assert_equal %w[a b a], ForgeCI::DAG.find_cycle(nodes, edges)
  end

  def test_find_cycle_detects_self_loop
    assert_equal %w[a a], ForgeCI::DAG.find_cycle(%w[a], { "a" => ["a"] })
  end

  def test_find_cycle_detects_longer_cycle
    nodes = %w[a b c]
    edges = { "a" => ["c"], "b" => ["a"], "c" => ["b"] }
    assert_equal %w[a c b a], ForgeCI::DAG.find_cycle(nodes, edges)
  end
end
