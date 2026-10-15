# frozen_string_literal: true

module ForgeCI
  # Directed-acyclic-graph helpers for workflow `requires` edges.
  #
  # nodes  - job names in config order (stable tie-breaking)
  # edges  - Hash of job name => Array of names it depends on
  module DAG
    module_function

    # Returns an Array describing the cycle (e.g. ["a", "b", "a"]) or nil.
    def find_cycle(nodes, edges)
      visited = {} # name => :visiting | :done
      stack = []

      visit = lambda do |node|
        visited[node] = :visiting
        stack << node
        (edges[node] || []).each do |dep|
          if visited[dep] == :visiting
            return stack.drop(stack.index(dep)) + [dep]
          elsif !visited.key?(dep)
            cycle = visit.call(dep)
            return cycle if cycle
          end
        end
        stack.pop
        visited[node] = :done
        nil
      end

      nodes.each do |node|
        next if visited.key?(node)

        cycle = visit.call(node)
        return cycle if cycle
      end
      nil
    end

    # Kahn's algorithm, stable: among ready nodes, config order wins.
    # Assumes the graph is acyclic (run find_cycle first).
    def toposort(nodes, edges)
      indegree = Hash.new(0)
      dependents = Hash.new { |h, k| h[k] = [] }
      nodes.each do |node|
        (edges[node] || []).each do |dep|
          indegree[node] += 1
          dependents[dep] << node
        end
      end

      ready = nodes.select { |n| indegree[n].zero? }
      order = []
      until ready.empty?
        node = ready.shift
        order << node
        dependents[node].each do |dep|
          indegree[dep] -= 1
          ready << dep if indegree[dep].zero?
        end
        # Keep config order among newly-ready nodes.
        ready.sort_by! { |n| nodes.index(n) }
      end
      order
    end
  end
end
