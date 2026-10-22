# frozen_string_literal: true

# Production: write the shared runner token to runner-token on the data volume,
# so a runner container sharing the volume (docker compose) needs no setup.
Rails.application.config.after_initialize do
  next unless Rails.env.production?

  ForgeCISecrets.publish_runner_token!
rescue SystemCallError => e
  Rails.logger.warn("[forge-ci] could not write the runner token file: #{e.message}")
end
