# frozen_string_literal: true

require "test_helper"
require "digest"

class KeyTemplateTest < Minitest::Test
  def resolve(template, branch: "main", files: {}, epoch: 1_700_000_000)
    warnings = []
    checksum = lambda do |rel|
      content = files[rel]
      content.nil? ? nil : Digest::SHA256.hexdigest(content)
    end
    key = ForgeCIRunner::KeyTemplate.resolve(
      template, branch: branch, checksum: checksum, epoch: epoch,
      warn: ->(m) { warnings << m }
    )
    [key, warnings]
  end

  def test_branch_and_epoch
    key, warnings = resolve("v1-{{ .Branch }}-{{ epoch }}")
    assert_equal "v1-main-1700000000", key
    assert_empty warnings
  end

  def test_checksum_of_file_contents
    key, warnings = resolve('deps-{{ checksum "Gemfile.lock" }}',
                            files: { "Gemfile.lock" => "lockdata" })
    assert_equal "deps-#{Digest::SHA256.hexdigest("lockdata")}", key
    assert_empty warnings
  end

  def test_checksum_missing_file_warns_and_empties
    key, warnings = resolve('deps-{{ checksum "nope.txt" }}-tail')
    assert_equal "deps--tail", key
    assert_equal 1, warnings.length
    assert_match(/nope\.txt/, warnings.first)
  end

  def test_unknown_template_left_as_is_with_warning
    key, warnings = resolve("v1-{{ arch }}")
    assert_equal "v1-{{ arch }}", key
    assert_equal 1, warnings.length
    assert_match(/arch/, warnings.first)
  end

  def test_multiple_templates_in_one_key
    key, _ = resolve("a-{{ .Branch }}-b-{{ epoch }}-c-{{ checksum \"f\" }}",
                     files: { "f" => "x" })
    assert_equal "a-main-b-1700000000-c-#{Digest::SHA256.hexdigest("x")}", key
  end

  def test_plain_key_unchanged
    key, warnings = resolve("plain-key")
    assert_equal "plain-key", key
    assert_empty warnings
  end

  def test_whitespace_variants
    key, _ = resolve("v1-{{.Branch}}-{{  epoch  }}")
    assert_equal "v1-main-1700000000", key
  end
end
