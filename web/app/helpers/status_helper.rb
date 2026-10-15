# frozen_string_literal: true

module StatusHelper
  def status_badge(status)
    tag.span(status, class: "badge st-#{status}")
  end
end
