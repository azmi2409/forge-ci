# frozen_string_literal: true

module ApplicationCable
  # WebSocket connections use the web UI's signed-in session (the encrypted
  # session cookie), checked the same way as a page request.
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user || reject_unauthorized_connection
    end

    private

    def find_verified_user
      key = Rails.application.config.session_options[:key]
      session = cookies.encrypted[key]
      session.is_a?(Hash) ? SessionAuth.user_for(session.with_indifferent_access) : nil
    end
  end
end
