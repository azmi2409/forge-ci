# frozen_string_literal: true

# Maps a GitHub repository (owner/name) to a forge-ci Project.
# On the first push from an unmapped repo the sync job auto-creates both the
# Project (named after the repo's full_name) and this mapping.
class GithubRepository < ApplicationRecord
  belongs_to :github_installation
  belongs_to :project
  has_many :pipelines, dependent: :nullify

  validates :full_name, presence: true, uniqueness: true
end
