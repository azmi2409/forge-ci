# frozen_string_literal: true

# Presentation helpers shared by the dashboard views.
module UiHelper
  # Inline icons on a 24px grid with a 1.7px round-capped stroke in the current
  # text colour: the Kilat.host dashboard_icon glyphs, plus a few CI-specific
  # ones drawn the same way. No asset files needed.
  ICONS = {
    "grid" => "M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z",
    "server" => "M4 3h16v7H4z M4 14h16v7H4z M7 6h.01 M7 17h.01 M11 6h6 M11 17h6",
    "settings" => "M4 7h16 M4 17h16 M8 4v6 M16 14v6",
    "logout" => "M9 4H4v16h5 M9 12h12 M17 8l4 4-4 4",
    "menu" => "M4 6h16 M4 12h16 M4 18h16",
    "close" => "M5 5l14 14 M19 5L5 19",
    "moon" => "M20 15a9 9 0 0 1-11-11A9 9 0 1 0 20 15",
    "sun" => "M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8 M12 2v2 M12 20v2 M2 12h2 M20 12h2 M5 5l1 1 M18 18l1 1 M5 19l1-1 M18 6l1-1",
    "monitor" => "M3 4h18v12H3z M8 20h8 M12 16v4",
    "deploy" => "M12 2l10 6v8l-10 6-10-6V8z M12 8v8 M7 5l5 3 5-3",
    "cpu" => "M6 4h12v16H6z M6 8h12 M6 16h12 M2 9h4 M2 15h4 M18 9h4 M18 15h4",
    "user" => "M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z M4 21v-1a7 7 0 0 1 14 0v1",
    "selector" => "M8 9l4-4 4 4 M8 15l4 4 4-4",
    "plus" => "M12 5v14 M5 12h14",
    "check" => "M5 12.5l4.5 4.5L19 7.5",
    "external" => "M14 4h6v6 M20 4l-9 9 M18 14v6H4V6h6",
    "arrow-right" => "M5 12h14 M13 6l6 6-6 6",
    "arrow-left" => "M19 12H5 M11 6l-6 6 6 6",
    "arrow-down" => "M12 5v14 M6 13l6 6 6-6",
    "alert" => "M12 3l10 18H2z M12 10v4 M12 17.5h.01",
    "info" => "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20z M12 11v6 M12 7.5h.01",
    "refresh" => "M20 11a8 8 0 0 0-14.6-4.5L4 8 M4 4v4h4 M4 13a8 8 0 0 0 14.6 4.5L20 16 M20 20v-4h-4",
    "terminal" => "M3 4h18v16H3z M7 9l3 3-3 3 M12 15h5",
    "logs" => "M4 5h16 M4 10h16 M4 15h10 M4 20h7",
    "link" => "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1 M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1",
    "play" => "M7 4l13 8-13 8z",
    "stop" => "M6 6h12v12H6z",
    "clock" => "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M12 7v5l3 2",
    "branch" => "M6 3a2 2 0 1 0 0 4 2 2 0 0 0 0-4z M6 17a2 2 0 1 0 0 4 2 2 0 0 0 0-4z M18 5a2 2 0 1 0 0 4 2 2 0 0 0 0-4z M6 7v10 M18 9c0 5-7 4-11 8",
    "commit" => "M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z M3 12h5.5 M15.5 12H21",
    "layers" => "M12 3l9 5-9 5-9-5z M3 13l9 5 9-5",
    "repo" => "M5 4.5A1.5 1.5 0 0 1 6.5 3H19v15H6.5A1.5 1.5 0 0 0 5 19.5z M5 19.5A1.5 1.5 0 0 0 6.5 21H19v-3",
    "users" => "M9 4.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z M2.5 20c.8-3.5 3.4-5.5 6.5-5.5s5.7 2 6.5 5.5 M16 4.8a3.5 3.5 0 0 1 0 6.4 M18 14.8c1.8.8 3 2.6 3.5 5.2",
    "chevron-right" => "M9 6l6 6-6 6",
    "github" => "M9 19c-4.3 1.4-4.3-2.5-6-3 M15 21v-3.5c0-1 .1-1.4-.5-2 2.8-.3 5.5-1.4 5.5-6a4.6 4.6 0 0 0-1.3-3.2 4.2 4.2 0 0 0-.1-3.2s-1.1-.3-3.5 1.3a12.3 12.3 0 0 0-6.2 0C6.5 2.8 5.4 3.1 5.4 3.1a4.2 4.2 0 0 0-.1 3.2A4.6 4.6 0 0 0 4 9.5c0 4.6 2.7 5.7 5.5 6-.6.6-.6 1.2-.5 2V21"
  }.freeze

  def icon(name, css: "icon", label: nil)
    aria = label ? { role: "img", "aria-label": label } : { "aria-hidden": true }
    tag.svg(viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", "stroke-width": 1.7,
            "stroke-linecap": "round", "stroke-linejoin": "round", class: css, **aria) do
      tag.path(d: ICONS.fetch(name.to_s))
    end
  end

  # Topbar breadcrumbs: breadcrumbs(["Overview", projects_path], ["acme/web"]).
  # Items with a path are links; the last item is the current page.
  def breadcrumbs(*items)
    parts = items.map { |label, path| path ? link_to(label, path) : tag.span(label, class: "crumb") }
    safe_join(parts, crumb_separator)
  end

  # The slanted hairline slash between breadcrumbs.
  def crumb_separator
    tag.svg(class: "crumb-sep", width: 16, height: 16, viewBox: "0 0 16 16", fill: "none", "aria-hidden": true) do
      tag.path(d: "M10.5 2.5 5.5 13.5", stroke: "currentColor", "stroke-linecap": "round")
    end
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

  def sidebar_link(label, path, icon_name, active:)
    link_to path, class: ["sidebar-link", ("is-active" if active)].compact.join(" "), "aria-current": (active ? "page" : nil) do
      safe_join([icon(icon_name), tag.span(label)])
    end
  end
end
