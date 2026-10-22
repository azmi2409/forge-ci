# frozen_string_literal: true

# Presentation helpers shared by the dashboard views.
module UiHelper
  # Inline 24x24 stroke icons (Feather-style), so the UI needs no asset files.
  ICONS = {
    "check" => '<path d="M20 6 9 17l-5-5"/>',
    "x" => '<path d="M18 6 6 18M6 6l12 12"/>',
    "clock" => '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    "branch" => '<circle cx="6" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><circle cx="18" cy="7" r="2"/><path d="M6 7v10M18 9c0 5-7 4-11 8"/>',
    "commit" => '<circle cx="12" cy="12" r="3.5"/><path d="M3 12h5.5M15.5 12H21"/>',
    "repo" => '<path d="M5 4.5A1.5 1.5 0 0 1 6.5 3H19v15H6.5A1.5 1.5 0 0 0 5 19.5v-15zM5 19.5A1.5 1.5 0 0 0 6.5 21H19v-3"/>',
    "folder" => '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5H9l2 2h8.5A1.5 1.5 0 0 1 21 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z"/>',
    "play" => '<path d="M7 5v14l11-7z"/>',
    "stop" => '<circle cx="12" cy="12" r="9"/><path d="M9 9h6v6H9z"/>',
    "layers" => '<path d="m12 3 9 5-9 5-9-5 9-5z"/><path d="m3 13 9 5 9-5"/>',
    "cpu" => '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
    "terminal" => '<path d="m5 8 4 4-4 4M12 16h7"/><rect x="2" y="3" width="20" height="18" rx="2"/>',
    "users" => '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.8-3.5 3.4-5.5 6.5-5.5s5.7 2 6.5 5.5M16 4.8a3.5 3.5 0 0 1 0 6.4M18 14.8c1.8.8 3 2.6 3.5 5.2"/>',
    "user" => '<circle cx="12" cy="8" r="4"/><path d="M4 21c1-4 4.2-6 8-6s7 2 8 6"/>',
    "logout" => '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/>',
    "plus" => '<path d="M12 5v14M5 12h14"/>',
    "chevron-right" => '<path d="m9 6 6 6-6 6"/>',
    "chevron-down" => '<path d="m6 9 6 6 6-6"/>',
    "external" => '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
    "arrow-down" => '<path d="M12 5v14M6 13l6 6 6-6"/>',
    "activity" => '<path d="M3 12h4l3 8 4-16 3 8h4"/>',
    "github" => '<path d="M9 19c-4.3 1.4-4.3-2.5-6-3m12 5v-3.5c0-1 .1-1.4-.5-2 2.8-.3 5.5-1.4 5.5-6a4.6 4.6 0 0 0-1.3-3.2 4.2 4.2 0 0 0-.1-3.2s-1.1-.3-3.5 1.3a12.3 12.3 0 0 0-6.2 0C6.5 2.8 5.4 3.1 5.4 3.1a4.2 4.2 0 0 0-.1 3.2A4.6 4.6 0 0 0 4 9.5c0 4.6 2.7 5.7 5.5 6-.6.6-.6 1.2-.5 2V21"/>'
  }.freeze

  def icon(name, css: "icon", label: nil)
    paths = ICONS.fetch(name.to_s)
    aria = label ? %(role="img" aria-label="#{ERB::Util.html_escape(label)}") : 'aria-hidden="true"'
    # Paths are static strings above, never user input.
    %(<svg class="#{css}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" #{aria}>#{paths}</svg>).html_safe # rubocop:disable Rails/OutputSafety
  end

  # <time> with a relative label ("3 minutes ago") and the exact time on hover.
  def time_ago_tag(time)
    return tag.span("—", class: "muted") if time.nil?

    tag.time("#{time_ago_in_words(time)} ago", datetime: time.iso8601,
                                               title: time.utc.strftime("%Y-%m-%d %H:%M:%S UTC"))
  end

  # 42 -> "42s", 125 -> "2m 5s", 3720 -> "1h 2m".
  def duration_text(seconds)
    return "—" if seconds.nil?

    seconds = seconds.round
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m #{seconds % 60}s" if seconds < 3600

    "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
  end

  def pipeline_duration(pipeline)
    finished = pipeline.terminal? ? pipeline.updated_at : Time.current
    finished - pipeline.created_at
  end

  def job_duration(job)
    started = job.step_runs.filter_map(&:started_at).min
    return nil unless started

    finished = job.step_runs.filter_map(&:finished_at).max
    finished = Time.current if finished.nil? || %w[claimed running].include?(job.status)
    finished - started
  end

  def short_sha(sha)
    sha.to_s[0, 8]
  end

  # Commit URL on GitHub when the pipeline's repo is known to live there.
  def commit_url(pipeline)
    full_name = pipeline.github_repository&.full_name
    full_name ||= pipeline.project.repo_url.to_s[%r{github\.com[/:]([^/]+/[^/]+?)(?:\.git)?/?\z}, 1]
    full_name && "https://github.com/#{full_name}/commit/#{pipeline.sha}"
  end

  def nav_link(label, path, icon_name, active:)
    link_to path, class: ["nav-item", ("active" if active)].compact.join(" "), "aria-current": (active ? "page" : nil) do
      safe_join([icon(icon_name), tag.span(label)])
    end
  end
end
