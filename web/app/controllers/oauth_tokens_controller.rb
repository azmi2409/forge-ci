# frozen_string_literal: true

class OauthTokensController < Doorkeeper::TokensController
  include OauthResourceIndicator

  before_action :validate_oauth_resource!, only: :create
end
