# frozen_string_literal: true

module Github
  # Turns a GitHub push / pull_request event into a forge-ci pipeline.
  #
  # Fetches .circleci/config.yml at the event SHA, compiles it with the
  # forge-ci gem, and creates the pipeline through the shared PipelineIntake
  # service (the same seam the REST API uses).
  #
  # SECURITY — fork pull requests: when `forked` is true the pipeline is
  # marked as such and gets NO contexts injected (context_names: []),
  # regardless of the project's configured contexts. Secrets must never
  # reach untrusted fork code.
  class SyncPipelineJob < ApplicationJob
    queue_as :default

    def perform(installation_id:, account_login:, repo_full_name:, sha:, branch:, forked: false)
      installation = GithubInstallation.find_or_create_by!(installation_id: installation_id) do |inst|
        inst.account_login = account_login
      end

      github_repo = installation.github_repositories.find_by(full_name: repo_full_name)
      unless github_repo
        project = Project.create!(name: repo_full_name) # max_concurrency defaults to 4
        github_repo = installation.github_repositories.create!(full_name: repo_full_name, project: project)
        Rails.logger.info("[github] auto-created project #{project.id} for #{repo_full_name}")
      end
      project = github_repo.project

      client = Github.client_for(installation_id)
      yaml = client.fetch_config(repo_full_name, sha)
      unless yaml.present?
        Rails.logger.info("[github] no .circleci/config.yml at #{repo_full_name}@#{sha[0, 7]} — skipping")
        return
      end

      # A push to a branch with an open pull request sends both a `push` and a
      # `pull_request` event for the same commit: build it once. The row lock
      # makes two deliveries arriving together wait for each other.
      github_repo.with_lock do
        if project.pipelines.exists?(github_repository: github_repo, sha: sha)
          Rails.logger.info("[github] #{repo_full_name}@#{sha[0, 7]} already has a pipeline — skipping")
        else
          create_pipeline(project, github_repo, yaml, sha: sha, branch: branch, forked: forked)
        end
      end
    end

    private

    def create_pipeline(project, github_repo, yaml, sha:, branch:, forked:)
      number = project.pipelines.maximum(:pipeline_number).to_i + 1
      ir, errors = ForgeCI::Compiler.compile(yaml, pipeline_params: { "branch" => branch, "number" => number })

      if errors.any?
        # Don't silently drop the push: create a failed pipeline and tell
        # GitHub why via a failure commit status.
        pipeline = project.pipelines.create!(
          sha: sha, branch: branch, status: "failed",
          forked: forked, github_repository: github_repo, pipeline_number: number
        )
        StatusPoster.post_compile_error(pipeline, errors)
        return
      end

      # Forked PRs never receive contexts — see the SECURITY note above.
      context_names = forked ? [] : project.default_context_names
      pipeline = PipelineIntake.call!(
        project: project,
        sha: sha,
        branch: branch,
        ir: ir,
        context_names: context_names,
        pipeline_number: number,
        forked: forked,
        github_repository: github_repo
      )
      StatusPoster.post_pending(pipeline)
    end
  end
end
