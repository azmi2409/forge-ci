# frozen_string_literal: true

module StatusHelper
  def status_badge(status)
    tag.span(status.to_s.humanize, class: "badge st-#{status}")
  end

  # One status for all nodes of a parallel job: the most urgent one wins.
  def group_status(jobs)
    statuses = jobs.map(&:status)
    return statuses.first if statuses.uniq.size == 1

    %w[failed running claimed queued pending canceled success].find { |s| statuses.include?(s) }
  end
end
