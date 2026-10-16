# frozen_string_literal: true

# Public marketing landing page — the only unauthenticated HTML page.
class LandingController < ApplicationController
  skip_before_action :require_login

  layout "landing"

  def show; end
end
