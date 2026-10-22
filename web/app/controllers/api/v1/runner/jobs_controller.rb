# frozen_string_literal: true

module Api
  module V1
    module Runner
      # The polling API the Docker runner (component 5) drives:
      #   claim -> start -> heartbeat (every ~30s) -> log_chunks -> complete
      class JobsController < BaseController
        # POST /api/v1/runner/jobs/claim { resource_class: "medium" }
        # Atomically claims the oldest queued job matching the token's
        # resource class, honoring each project's max_concurrency.
        def claim
          job = JobRun.claim_next!(current_runner_token)
          return render json: { error: "no claimable jobs right now" }, status: :unprocessable_entity unless job

          render json: job_payload(job), status: :ok
        end

        # POST /api/v1/runner/jobs/:id/heartbeat — refresh heartbeat_at.
        def heartbeat
          job = find_owned_job
          return unless job

          job.update!(heartbeat_at: Time.current)
          render json: { id: job.id, status: job.status, heartbeat_at: job.heartbeat_at }, status: :ok
        end

        # POST /api/v1/runner/jobs/:id/start — claimed -> running, called when
        # the container actually starts so the two states stay distinguishable.
        def start
          job = find_owned_job
          return unless job

          begin
            job.mark_running!
          rescue JobRun::IllegalTransition => e
            return render json: { error: e.message }, status: :unprocessable_entity
          end
          render json: { id: job.id, status: job.status }, status: :ok
        end

        # POST /api/v1/runner/jobs/:id/complete
        #   { status: "success"|"failed"|"canceled",
        #     step_results: [{ name, exit_code, started_at, finished_at }] }
        def complete
          job = find_owned_job
          return unless job

          begin
            job.complete_with_results!(status: params[:status], step_results: params[:step_results])
          rescue JobRun::IllegalTransition => e
            return render json: { error: e.message }, status: :unprocessable_entity
          end
          render json: { id: job.id, status: job.status }, status: :ok
        end

        private

        def find_owned_job
          job = JobRun.find(params[:id])
          require_job_owner!(job)
          # require_job_owner! renders 403 on mismatch; halt in that case.
          performed? ? nil : job
        rescue ActiveRecord::RecordNotFound
          render json: { error: "job not found" }, status: :not_found
          nil
        end

        # The full job payload. `environment` is the executor environment
        # merged with resolved context payloads (contexts win). Raw Context
        # records are NEVER returned. `repository` is additive (nil-safe) so
        # older runners keep working.
        def job_payload(job)
          pipeline = job.pipeline
          {
            id: job.id,
            name: job.name,
            working_directory: job.working_directory,
            executor: job.executor_hash,
            steps: job.steps || [],
            environment: job.merged_environment,
            pipeline: { sha: pipeline.sha, branch: pipeline.branch },
            workflow_run_id: job.workflow_run_id,
            project_id: job.project.id,
            repository: repository_info(job)
          }.compact
        end

        # Where the runner can `git clone` the code for `checkout` steps.
        # Prefers the GitHub repo the pipeline came from, then the project's
        # configured repo_url. Omitted entirely when neither is known.
        def repository_info(job)
          pipeline = job.pipeline
          url = if pipeline.github_repository
                  "https://github.com/#{pipeline.github_repository.full_name}.git"
                elsif job.project.repo_url.present?
                  job.project.repo_url
                end
          return nil if url.blank?

          { url: url, sha: pipeline.sha, branch: pipeline.branch,
            token: checkout_token(pipeline.github_repository) }.compact
        end

        # Short-lived GitHub App installation token so the runner can clone
        # private repos. Sent as its own field (never embedded in the URL);
        # nil when the App isn't configured or GitHub refuses, in which case
        # public repos still clone anonymously.
        def checkout_token(github_repository)
          return nil unless github_repository && ::Github.configured?

          ::Github.client_for(github_repository.github_installation.installation_id).installation_token
        rescue StandardError => e
          Rails.logger.warn("[runner] no checkout token for #{github_repository.full_name}: #{e.class}: #{e.message}")
          nil
        end
      end
    end
  end
end
