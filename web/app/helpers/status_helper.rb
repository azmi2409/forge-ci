# frozen_string_literal: true

module StatusHelper
  def status_badge(status)
    # A dot before a word, never colour alone (Kilat.host status convention).
    tag.span(class: "status-badge") do
      safe_join([tag.span(class: "status-dot", "data-state": status.to_s), status.to_s.humanize])
    end
  end

  # One status for all nodes of a parallel job: the most urgent one wins.
  def group_status(jobs)
    statuses = jobs.map(&:status)
    return statuses.first if statuses.uniq.size == 1

    %w[failed running claimed queued pending canceled success].find { |s| statuses.include?(s) }
  end
end
