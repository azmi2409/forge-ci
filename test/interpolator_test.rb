# frozen_string_literal: true

require_relative "test_helper"

class InterpolatorTest < Minitest::Test
  def errors
    ForgeCI::ErrorCollector.new
  end

  def context(overrides = {})
    {
      "parameters" => { "name" => "world", "flag" => true, "count" => 3 },
      "pipeline" => { "branch" => "main", "number" => 42 },
      "matrix" => { "ruby" => "3.2" }
    }.merge(overrides)
  end

  def test_full_string_reference_preserves_native_type
    e = errors
    assert_equal true, ForgeCI::Interpolator.interpolate("<< parameters.flag >>", context, e, [])
    assert_equal 3, ForgeCI::Interpolator.interpolate("<< parameters.count >>", context, e, [])
    assert_empty e.to_a
  end

  def test_embedded_reference_stringifies
    e = errors
    result = ForgeCI::Interpolator.interpolate("hello << parameters.name >>!", context, e, [])
    assert_equal "hello world!", result
    assert_empty e.to_a
  end

  def test_pipeline_and_matrix_references
    e = errors
    assert_equal "main", ForgeCI::Interpolator.interpolate("<< pipeline.git.branch >>", context, e, [])
    assert_equal 42, ForgeCI::Interpolator.interpolate("<< pipeline.number >>", context, e, [])
    assert_equal "3.2", ForgeCI::Interpolator.interpolate("<< matrix.ruby >>", context, e, [])
    assert_empty e.to_a
  end

  def test_whitespace_inside_reference_is_tolerated
    e = errors
    assert_equal "world", ForgeCI::Interpolator.interpolate("<<parameters.name>>", context, e, [])
    assert_equal "world", ForgeCI::Interpolator.interpolate("<<  parameters.name  >>", context, e, [])
    assert_empty e.to_a
  end

  def test_unknown_reference_is_collected_not_raised
    e = errors
    result = ForgeCI::Interpolator.interpolate("<< parameters.nope >>", context, e, ["jobs"])
    assert_equal "<< parameters.nope >>", result
    assert_match(/unknown interpolation reference/, e.to_a.join("\n"))
  end

  def test_non_reference_strings_pass_through_untouched
    e = errors
    assert_equal "echo hi", ForgeCI::Interpolator.interpolate("echo hi", context, e, [])
    # Shell heredoc-style << without a closing >> is not a reference.
    assert_equal "cat <<EOF", ForgeCI::Interpolator.interpolate("cat <<EOF", context, e, [])
    assert_empty e.to_a
  end

  def test_interpolates_nested_structures
    e = errors
    obj = { "a" => ["<< parameters.name >>", { "b" => 1 }], "c" => "<< pipeline.number >>" }
    result = ForgeCI::Interpolator.interpolate(obj, context, e, [])
    assert_equal({ "a" => ["world", { "b" => 1 }], "c" => 42 }, result)
    assert_empty e.to_a
  end

  def test_only_allowlist_leaves_other_refs_alone
    e = errors
    result = ForgeCI::Interpolator.interpolate(
      "<< parameters.name >> << pipeline.git.branch >>",
      context, e, [], only: ["parameters.name"]
    )
    assert_equal "world << pipeline.git.branch >>", result
    assert_empty e.to_a
  end

  def test_skip_prefixes_leaves_matching_refs_alone
    e = errors
    result = ForgeCI::Interpolator.interpolate(
      "<< matrix.ruby >> on << pipeline.git.branch >>",
      context, e, [], skip_prefixes: ["matrix."]
    )
    assert_equal "<< matrix.ruby >> on main", result
    assert_empty e.to_a
  end

  def test_unresolved_refs_lists_remaining_references
    refs = ForgeCI::Interpolator.unresolved_refs({ "a" => "<< matrix.ruby >>", "b" => "plain" })
    assert_equal ["matrix.ruby"], refs
  end
end
