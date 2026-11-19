# frozen_string_literal: true

module PipelinesHelper
  def workflow_diagram(workflow)
    stages = workflow.stages
    nodes = stages.each_with_index.flat_map do |stage, column|
      stage.each_with_index.map do |jobs, row|
        job = jobs.first
        {
          id: job.name,
          type: "job",
          position: { x: column * 296, y: row * 152 },
          data: {
            name: job.name,
            status: group_status(jobs),
            resource_class: job.resource_class || "any runner",
            parallel: jobs.size,
            href: job_run_path(job),
            stage: column,
            stage_start: row.zero?,
            requires: job.requires_list,
            nodes: jobs.map do |node|
              { index: node.node_index + 1, status: node.status, href: job_run_path(node) }
            end
          }
        }
      end
    end
    by_name = nodes.index_by { |node| node[:id] }
    nodes.each do |node|
      node[:data][:long_requires] = node[:data][:requires].select do |name|
        parent = by_name[name]
        parent && node[:data][:stage] - parent[:data][:stage] > 1
      end
    end
    edges = nodes.flat_map do |node|
      node[:data][:requires].filter_map do |name|
        next unless by_name.key?(name)

        {
          id: [name, node[:id]].to_json,
          source: name,
          target: node[:id],
          targetHandle: name,
          type: "default",
          animated: %w[running queued claimed].include?(node[:data][:status]),
          data: { status: by_name[name][:data][:status] }
        }
      end
    end
    width = nodes.map { |node| node[:position][:x] + 248 }.max || 0
    height = nodes.map do |node|
      node[:position][:y] + (node[:data][:parallel] > 1 ? 124 : 90)
    end.max || 0
    { nodes: nodes, edges: edges, width: width, height: height }
  end
end
