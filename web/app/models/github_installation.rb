# frozen_string_literal: true

# A GitHub App installation of forge-ci on an account (org or user).
# Created/removed by the `installation` webhook event; also lazily created
# by the pipeline sync job if a push arrives before the event was processed.
class GithubInstallation < ApplicationRecord
  has_many :github_repositories, dependent: :destroy
  has_many :projects, through: :github_repositories

  validates :installation_id, presence: true, uniqueness: true
  validates :account_login, presence: true
end
