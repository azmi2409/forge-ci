# frozen_string_literal: true

module Api
  module V1
    module Github
      # Receives GitHub App webhook events.
      #
      # Security: every request must carry a valid X-Hub-Signature-256 HMAC
      # of the raw body, keyed by GITHUB_WEBHOOK_SECRET. Fail-closed — a
      # missing secret or a bad signature is a 401. The endpoint only
      # validates and enqueues; all real work happens in background jobs so
      # it always answers 202 fast.
      class WebhooksController < ActionController::API
        def create
          unless valid_signature?
            Rails.logger.warn("[github] webhook rejected: invalid or missing signature")
            return head :unauthorized
          end

          event = request.headers["X-GitHub-Event"].to_s
          payload =
            begin
              JSON.parse(request.raw_post)
            rescue JSON::ParserError
              return head :bad_request
            end

          case event
          when "ping" then head :ok
          when "push" then handle_push(payload)
          when "pull_request" then handle_pull_request(payload)
          when "installation" then handle_installation(payload)
          else
            Rails.logger.info("[github] ignoring webhook event #{event.inspect}")
            head :accepted
          end
        end

        private

        def valid_signature?
          secret = ::Github.webhook_secret
          return false if secret.blank?

          signature = request.headers["X-Hub-Signature-256"].to_s
          return false unless signature.start_with?("sha256=")

          expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, request.raw_post)}"
          ActiveSupport::SecurityUtils.secure_compare(signature, expected)
        rescue StandardError
          false
        end

        # Branch pushes only — tag pushes and branch deletions are ignored.
        def handle_push(payload)
          ref = payload["ref"].to_s
          unless ref.start_with?("refs/heads/") && !payload["deleted"]
            Rails.logger.info("[github] ignoring push to #{ref.inspect} (deleted=#{payload['deleted']})")
            return head :accepted
          end

          repo = payload["repository"] || {}
          installation = payload["installation"] || {}
          ::Github::SyncPipelineJob.perform_later(
            installation_id: installation["id"],
            account_login: installation.dig("account", "login"),
            repo_full_name: repo["full_name"],
            sha: payload["after"].to_s,
            branch: ref.delete_prefix("refs/heads/"),
            forked: false
          )
          head :accepted
        end

        # opened / synchronize only. Fork detection: head repo differs from
        # base repo — those pipelines get forked=true and NO contexts.
        def handle_pull_request(payload)
          unless %w[opened synchronize].include?(payload["action"].to_s)
            return head :accepted
          end

          pr = payload["pull_request"] || {}
          head_repo = pr.dig("head", "repo") || {}
          base_repo = pr.dig("base", "repo") || {}
          installation = payload["installation"] || {}

          ::Github::SyncPipelineJob.perform_later(
            installation_id: installation["id"],
            account_login: installation.dig("account", "login"),
            repo_full_name: base_repo["full_name"],
            sha: pr.dig("head", "sha").to_s,
            branch: pr.dig("head", "ref").to_s,
            forked: head_repo["full_name"] != base_repo["full_name"]
          )
          head :accepted
        end

        def handle_installation(payload)
          inst = payload["installation"] || {}
          case payload["action"].to_s
          when "created"
            GithubInstallation.find_or_create_by!(installation_id: inst["id"]) do |record|
              record.account_login = inst.dig("account", "login")
              record.account_type = inst.dig("account", "type")
            end
          when "deleted"
            GithubInstallation.find_by(installation_id: inst["id"])&.destroy
          end
          head :accepted
        end
      end
    end
  end
end
