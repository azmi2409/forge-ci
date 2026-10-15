# frozen_string_literal: true

require "test_helper"

class GithubInstallationTest < ActiveSupport::TestCase
  test "requires a unique installation_id" do
    GithubInstallation.create!(installation_id: 1, account_login: "octo")
    dup = GithubInstallation.new(installation_id: 1, account_login: "other")
    assert_not dup.valid?
    assert_includes dup.errors[:installation_id], "has already been taken"
  end

  test "destroying an installation destroys its repository mappings" do
    inst = GithubInstallation.create!(installation_id: 2, account_login: "octo")
    project = Project.create!(name: "octo/x")
    inst.github_repositories.create!(full_name: "octo/x", project: project)
    assert_difference("GithubRepository.count", -1) { inst.destroy }
    assert Project.exists?(project.id), "the project itself must survive"
  end
end

class GithubRepositoryTest < ActiveSupport::TestCase
  setup do
    @inst = GithubInstallation.create!(installation_id: 3, account_login: "octo")
    @project = Project.create!(name: "octo/y")
  end

  test "requires a unique full_name" do
    @inst.github_repositories.create!(full_name: "octo/y", project: @project)
    dup = @inst.github_repositories.new(full_name: "octo/y", project: @project)
    assert_not dup.valid?
  end

  test "belongs to an installation and a project" do
    repo = @inst.github_repositories.create!(full_name: "octo/y", project: @project)
    assert_equal @inst, repo.github_installation
    assert_equal @project, repo.project
  end
end
