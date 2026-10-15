# frozen_string_literal: true

require "psych"

module ForgeCI
  # Raised only when the YAML text cannot be parsed at all.
  # Every other problem (unknown keys, bad references, cycles, ...) is
  # reported as an entry in the errors array returned by Compiler.compile,
  # so callers get actionable feedback instead of exceptions.
  class Error < StandardError; end

  # Maps a key path (e.g. ["jobs", "build", "steps"]) back to the line number
  # of that key in the original YAML document, so error messages can point
  # at the user's YAML. Built from the Psych AST; tolerant of anchors and
  # merge keys.
  class LineIndex
    def initialize(document)
      @root = document.root
      @anchors = {}
      index_anchors(@root)
    end

    # Returns the 1-based line number of the key at the end of +path+,
    # or nil when it cannot be located (e.g. after alias expansion).
    # Integer path elements index into YAML sequences (step lists, etc.).
    def line_for(*path)
      node = @root
      key_node = nil
      path.each do |key|
        node = resolve(node)
        if node.is_a?(Psych::Nodes::Sequence) && key.is_a?(Integer)
          key_node = node.children[key]
          node = key_node
          next
        end
        return nil unless node.is_a?(Psych::Nodes::Mapping)

        i = mapping_key_index(node, key.to_s)
        return nil if i.nil?

        key_node = node.children[i]
        node = node.children[i + 1]
      end
      key_node ? key_node.start_line + 1 : nil
    rescue StandardError
      nil
    end

    private

    def index_anchors(node)
      return unless node.respond_to?(:children)

      @anchors[node.anchor] = node if node.respond_to?(:anchor) && node.anchor
      children = node.children
      return if children.nil?

      children.each { |child| index_anchors(child) }
    end

    def resolve(node)
      node.is_a?(Psych::Nodes::Alias) ? (@anchors[node.anchor] || node) : node
    end

    def mapping_key_index(map, key)
      map.children.each_slice(2).with_index do |(k, _v), i|
        k = resolve(k)
        return i * 2 if k.is_a?(Psych::Nodes::Scalar) && k.value == key
      end
      nil
    end
  end

  # Collects validation errors as structured entries and renders them as
  # actionable strings: "line 12: jobs.build: <message>".
  class ErrorCollector
    Entry = Struct.new(:path, :line, :message, keyword_init: true)

    def initialize(line_index = nil)
      @line_index = line_index
      @entries = []
    end

    def add(path, message)
      path = Array(path)
      line = @line_index&.line_for(*path)
      @entries << Entry.new(path: path.join("."), line: line, message: message)
    end

    def any? = @entries.any?
    def empty? = @entries.empty?
    def size = @entries.size

    def to_a
      @entries.map do |e|
        loc = e.line ? "line #{e.line}: " : ""
        "#{loc}#{e.path}: #{e.message}"
      end
    end
  end
end
