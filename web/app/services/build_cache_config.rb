# frozen_string_literal: true

require "base64"

# Registry-backed Docker layer cache for `setup_remote_docker` jobs, so image
# builds survive ephemeral runners: builds export their layer cache to the
# registry (--cache-to) and the next runner pulls it back (--cache-from).
# Configure with the full repository reference, sans tag:
#
#   FORGE_CI_BUILD_CACHE_REGISTRY="123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/forge-ci-cache"
#
# Per-project, per-branch cache images are tags on that one repository:
# "<registry>:p<project_id>-<branch>". ECR repositories don't auto-create, so
# `aws ecr create-repository` it once and give it a lifecycle policy.
#
# Credentials: ECR registry hosts get a 12-hour authorization token minted on
# demand via aws-sdk-ecr — the same AWS credential chain as the autoscaler,
# and the same IAM principal, so scope that principal to
# ecr:GetAuthorizationToken + ecr:* on the cache repository only. Any other
# registry uses the static FORGE_CI_BUILD_CACHE_REGISTRY_USERNAME /
# FORGE_CI_BUILD_CACHE_REGISTRY_PASSWORD pair (a machine user with push access
# to the cache repository).
#
# Fork pull requests never get a section (they are refused the Docker socket
# already), and neither do jobs that didn't ask for the cache
# (setup_remote_docker with docker_layer_caching: true).
class BuildCacheConfig
  ECR_HOST = /\A(\d{12})\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com(\.cn)?\z/

  class << self
    # The claim payload's `docker_build_cache` section for one job, or nil
    # when there is nothing to say (nothing configured, a fork, no remote
    # docker). Credentials are omitted for an unauthenticated registry or
    # when minting failed; the runner then skips its docker login.
    def for_job(job)
      registry = ENV["FORGE_CI_BUILD_CACHE_REGISTRY"].to_s.strip
      return nil if registry.empty?
      return nil if job.pipeline.forked?
      return nil unless Array(job.steps).any? { |s| s.is_a?(Hash) && s["type"] == "setup_remote_docker" && s["layer_caching"] }

      user, password = registry_credentials(registry)
      { registry: registry, ref: "#{registry}:#{cache_tag(job)}",
        username: user, password: password }.compact
    end

    def configured?
      !ENV["FORGE_CI_BUILD_CACHE_REGISTRY"].to_s.strip.empty?
    end

    # Docker tag: [A-Za-z0-9_][A-Za-z0-9._-]{0,127}. The p<id>- prefix keeps
    # projects apart on one repository; the branch keys the cache per line of
    # work ("feat/new-ui" -> "feat-new-ui").
    def cache_tag(job)
      branch = job.pipeline.branch.to_s.downcase.gsub(%r{[^a-z0-9._-]}, "-")
      "p#{job.pipeline.project_id}-#{branch}"[0, 127]
    end

    # Drops a cached ECR token (tests; also correct after a credential swap).
    def reset_ecr_token!
      @ecr_mutex.synchronize { @ecr_tokens = {} }
    end

    # Factory seam: tests swap in a fake client.
    def ecr_factory
      @ecr_factory ||= lambda do |region|
        require "aws-sdk-ecr"
        Aws::ECR::Client.new(region: region)
      end
    end

    def ecr_factory=(factory)
      @ecr_factory = factory
    end

    private

    def registry_credentials(registry)
      host = registry.split("/").first
      match = host.match(ECR_HOST)
      match ? ecr_credentials(match[2]) : static_credentials
    end

    def static_credentials
      user = ENV["FORGE_CI_BUILD_CACHE_REGISTRY_USERNAME"].presence
      password = ENV["FORGE_CI_BUILD_CACHE_REGISTRY_PASSWORD"].presence
      user && password ? [user, password] : nil
    end

    # GetAuthorizationToken returns base64("AWS:<token>"), valid 12h. Minted
    # with the control plane's own IAM principal and cached in-process, so a
    # claim costs an API call roughly twice a day, not per job.
    # Cached per region: a token is only valid for its own region's registry.
    def ecr_credentials(region)
      @ecr_mutex.synchronize do
        token = @ecr_tokens[region]
        if token.nil? || token[:expires_at] <= Time.now + 1.hour
          datum = ecr_factory.call(region).get_authorization_token.authorization_data.first
          user, password = Base64.decode64(datum.authorization_token).split(":", 2)
          token = @ecr_tokens[region] = { user: user, password: password, expires_at: datum.expires_at }
        end
        [token[:user], token[:password]]
      end
    rescue StandardError => e
      Rails.logger.warn("[build-cache] ECR authorization token failed: #{e.class}: #{e.message}")
      nil
    end
  end

  @ecr_mutex = Mutex.new
  @ecr_tokens = {}
end
