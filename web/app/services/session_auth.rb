# frozen_string_literal: true

# Cookie-session helpers shared by the HTML controllers (via Authentication)
# and the browser-facing API endpoints (log stream, artifact download),
# which are ActionController::API and read the session off the request.
module SessionAuth
  IDLE_TIMEOUT = 12.hours
  ABSOLUTE_TIMEOUT = 7.days

  # The signed-in User for this session, or nil. Slides the idle window.
  def self.user_for(session)
    id = session[:user_id]
    return nil unless id

    now = Time.current.to_i
    return nil if now - session[:started_at].to_i > ABSOLUTE_TIMEOUT
    return nil if now - session[:seen_at].to_i > IDLE_TIMEOUT

    user = User.find_by(id: id)
    return nil unless user && ActiveSupport::SecurityUtils.secure_compare(user.session_nonce, session[:nonce].to_s)

    session[:seen_at] = now if now - session[:seen_at].to_i > 60
    user
  end

  # Start a fresh session for +user+ (reset first: prevents fixation).
  def self.sign_in(controller, user)
    return_to = controller.session[:return_to]
    controller.reset_session
    now = Time.current.to_i
    controller.session[:user_id] = user.id
    controller.session[:nonce] = user.session_nonce
    controller.session[:started_at] = now
    controller.session[:seen_at] = now
    return_to
  end
end
