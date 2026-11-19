# frozen_string_literal: true

module PipelinesHelper
  def workflow_diagram(workflow)
    stages = workflow.stages
    nodes = stages.each_with_index.flat_map do |stage, column|
      y = 0
      stage.each_with_index.map do |jobs, row|
        job = jobs.first
        height = workflow_diagram_node_height(jobs)
        position = { x: column * 296, y: y }
        y += height + 28
        {
          id: job.name,
          type: "job",
          position: position,
          data: {
            name: job.name,
            status: group_status(jobs),
            resource_class: job.resource_class || "any runner",
            parallel: jobs.size,
            estimated_height: height,
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
      node[:position][:y] + node[:data][:estimated_height]
    end.max || 0
    { nodes: nodes, edges: edges, width: width, height: height }
  end

  private

  def workflow_diagram_node_height(jobs)
    return 90 if jobs.size == 1

    rows = 1
    row_width = 0
    jobs.each do |job|
      pill_width = 29 + (job.node_index + 1).to_s.length * 7
      width = row_width.zero? ? pill_width : row_width + 4 + pill_width
      if width > 220
        rows += 1
        row_width = pill_width
      else
        row_width = width
      end
    end
    124 + (rows - 1) * 26
  end
end
