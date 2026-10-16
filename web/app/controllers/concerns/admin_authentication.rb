# frozen_string_literal: true

# Bearer-token auth for the admin API (FORGE_CI_ADMIN_TOKEN). Deliberately
# separate from runner tokens: runners must never be able to start pipelines
# or read/rewrite secrets. Fails closed — when the token is not configured the
# endpoints answer 503 instead of being open.
module AdminAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_admin!
  end

  private

  def authenticate_admin!
    expected = ENV["FORGE_CI_ADMIN_TOKEN"].to_s
    if expected.blank?
      return render json: { error: "admin API not configured (set FORGE_CI_ADMIN_TOKEN)" },
                    status: :service_unavailable
    end

    header = request.headers["Authorization"].to_s
    scheme, _, credentials = header.partition(" ")
    provided = scheme.casecmp("bearer").zero? ? credentials.to_s : nil
    return if provided.present? && ActiveSupport::SecurityUtils.secure_compare(provided, expected)

    render json: { error: "unauthorized: valid admin bearer token required" }, status: :unauthorized
  end
end
