# frozen_string_literal: true

module PipelinesHelper
  def workflow_diagram(workflow)
    stages = workflow.stages
    nodes = stages.each_with_index.flat_map do |stage, column|
      stage.each_with_index.map do |jobs, row|
        job = jobs.first
        { id: job.name, type: "job", position: { x: column * 320, y: row * 144 },
          data: { name: job.name, status: group_status(jobs), resource_class: job.resource_class || "any runner",
                  parallel: jobs.size, href: job_run_path(job), stage: column, stage_start: row.zero?, requires: job.requires_list,
                  nodes: jobs.map { |node| { index: node.node_index + 1, status: node.status, href: job_run_path(node) } } } }
      end
    end
    by_name = nodes.index_by { |node| node[:id] }
    edges = nodes.flat_map do |node|
      node[:data][:requires].filter_map do |name|
        next unless by_name.key?(name)

        { id: [name, node[:id]].to_json, source: name, target: node[:id], type: "smoothstep",
          animated: %w[running queued claimed].include?(node[:data][:status]),
          data: { status: by_name[name][:data][:status] } }
      end
    end
    { nodes: nodes, edges: edges, height: [340, stages.map(&:size).max.to_i * 144 + 96].max }
  end
end
