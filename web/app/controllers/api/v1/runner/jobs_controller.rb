# frozen_string_literal: true

module Api
  module V1
    module Runner
      # The polling API the Docker runner (component 5) drives:
      #   claim -> start -> heartbeat (every ~30s) -> log_chunks -> complete
      #   (or release, when a REQUEUE_ON_SHUTDOWN runner shuts down mid-job)
      class JobsController < BaseController
        before_action :validate_runner_identity!

        # POST /api/v1/runner/jobs/claim { resource_class: "medium" }
        # Atomically claims the oldest queued job matching the token's
        # resource class (or, for a token without one, the requested
        # resource_class), honoring each project's max_concurrency.
        def claim
          record_runner_presence(resource_class: current_runner_token.resource_class || params[:resource_class].presence)
          job = JobRun.claim_next!(current_runner_token, requested_resource_class: params[:resource_class].to_s)
          unless job
            # `upcoming`: this runner's class has jobs waiting on earlier ones;
            # a runner with idle shutdown stays up for them.
            klass = current_runner_token.resource_class || params[:resource_class].presence
            return render json: { error: "no claimable jobs right now", upcoming: JobRun.upcoming_count(klass, fork_only: current_runner_token.fork_only?) },
                          status: :unprocessable_entity
          end
          @runner_instance&.update!(current_job_run: job)

          render json: job_payload(job), status: :ok
        end

        # POST /api/v1/runner/jobs/:id/heartbeat — refresh heartbeat_at.
        def heartbeat
          job = find_owned_job
          return unless job

          job.update!(heartbeat_at: Time.current)
          @runner_instance&.update!(current_job_run: job) if JobRun::ACTIVE_STATUSES.include?(job.status)
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
          @runner_instance&.update!(current_job_run: job)
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
          clear_runner_assignment(job)
          render json: { id: job.id, status: job.status }, status: :ok
        end

        # POST /api/v1/runner/jobs/:id/release { reason: "..." }
        # A runner shutting down (REQUEUE_ON_SHUTDOWN) hands the job back to
        # the queue. 409 once the job was released JobRun::MAX_RELEASES times;
        # the runner then completes it as canceled.
        def release
          job = find_owned_job
          return unless job

          begin
            unless job.release!(reason: params[:reason].to_s)
              return render json: { error: "job released #{JobRun::MAX_RELEASES} times already; not requeued" },
                            status: :conflict
            end
          rescue JobRun::IllegalTransition => e
            return render json: { error: e.message }, status: :unprocessable_entity
          end
          clear_runner_assignment(job)
          render json: { id: job.id, status: job.status }, status: :ok
        end

        private

        def validate_runner_identity!
          id = request.headers["X-Forge-Runner-ID"]
          return if id.nil? && request.headers["X-Forge-Runner-Hostname"].nil? &&
                    request.headers["X-Forge-Runner-Implementation"].nil?

          hostname = request.headers["X-Forge-Runner-Hostname"].to_s
          implementation = request.headers["X-Forge-Runner-Implementation"].to_s
          unless id.to_s.match?(RunnerInstance::UUID) && hostname.present? && hostname.length <= 255 &&
                 %w[ruby go].include?(implementation)
            render json: { error: "invalid runner identity headers" }, status: :bad_request
          end
        end

        def record_runner_presence(resource_class:)
          id = request.headers["X-Forge-Runner-ID"]
          return if id.nil?

          @runner_instance = current_runner_token.runner_instances.create_or_find_by!(uuid: id.downcase) do |instance|
            instance.hostname = request.headers["X-Forge-Runner-Hostname"]
            instance.implementation = request.headers["X-Forge-Runner-Implementation"]
            instance.last_seen_at = Time.current
          end
          @runner_instance.update!(hostname: request.headers["X-Forge-Runner-Hostname"],
                                   implementation: request.headers["X-Forge-Runner-Implementation"],
                                   resource_class: resource_class, last_seen_at: Time.current)
        end

        def clear_runner_assignment(job)
          return unless @runner_instance

          RunnerInstance.where(id: @runner_instance.id, current_job_run_id: job.id).update_all(current_job_run_id: nil)
        end

        def find_owned_job
          job = JobRun.find(params[:id])
          require_job_owner!(job)
          # require_job_owner! renders 403 on mismatch; halt in that case.
          return if performed?

          record_runner_presence(resource_class: current_runner_token.resource_class || job.resource_class)
          job
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
            node_index: job.node_index,
            parallelism: job.parallelism,
            working_directory: job.working_directory,
            executor: job.executor_hash,
            steps: job.steps || [],
            environment: job.merged_environment,
            pipeline: { sha: pipeline.sha, branch: pipeline.branch },
            # false for fork pull requests: the runner refuses them the
            # host's Docker (setup_remote_docker).
            trusted: !pipeline.forked?,
            workflow_run_id: job.workflow_run_id,
            project_id: job.project.id,
            repository: repository_info(job),
            # Registry-backed layer cache for setup_remote_docker jobs; nil
            # (omitted) unless FORGE_CI_BUILD_CACHE_REGISTRY is configured.
            docker_build_cache: BuildCacheConfig.for_job(job)
          }.compact
        end

        # Where the runner can `git clone` the code for `checkout` steps.
        # Prefers the GitHub repo the pipeline came from, then the project's
        # configured repo_url, then the project's GitHub App repo (so manual
        # `forge-ci trigger` pipelines on App-created projects still clone).
        # Omitted entirely when none is known.
        def repository_info(job)
          pipeline = job.pipeline
          github_repo = pipeline.github_repository
          github_repo ||= job.project.github_repositories.first if job.project.repo_url.blank?
          # Forks clone mapped GitHub repositories anonymously. Never expose an
          # installation token or an operator URL that may contain credentials.
          return nil if pipeline.forked? && github_repo.nil?
          url = if github_repo
                  "https://github.com/#{github_repo.full_name}.git"
                elsif job.project.repo_url.present?
                  job.project.repo_url
                end
          return nil if url.blank?

          { url: url, sha: pipeline.sha, branch: pipeline.branch,
            token: pipeline.forked? ? nil : checkout_token(github_repo) }.compact
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
