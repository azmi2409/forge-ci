# syntax=docker/dockerfile:1
# ForgeCI control plane image. Build from the REPO ROOT:
#   docker build -t forge-ci-web .
#   docker compose build
# This Dockerfile understands the monorepo layout, where the forge-ci gem
# lives at the repo root (copied to /forge-ci for the path-gem reference).

ARG RUBY_VERSION=3.2.3
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    BUNDLE_JOBS="4" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" \
    FORGE_CI_GEM_PATH="/forge-ci" \
    FORGE_CI_RUNNER_PATH="/forge-ci/runner" \
    SOLID_QUEUE_IN_PUMA="1"
# SOLID_QUEUE_IN_PUMA runs the background worker inside the web server, so one
# container is the whole control plane. Set it to "" and run ./bin/jobs in a
# second container to scale the worker separately.
# The Gemfile references the forge-ci compiler as a path gem. Locally (and in
# CI) that path is `..` (monorepo root) — which is what the committed
# Gemfile.lock records — but here the gem source is copied to /forge-ci.
# Frozen mode would reject the mismatch, so explicitly unfreeze: bundler
# re-resolves just the path source, everything else stays locked.
ENV BUNDLE_FROZEN="false"

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# The forge-ci gem source (the web app consumes it as a path gem).
COPY forge-ci.gemspec MIT-LICENSE README.md /forge-ci/
COPY lib /forge-ci/lib
COPY exe /forge-ci/exe
# The runner, served to runner hosts by the install command on the Runners page.
COPY runner/bin /forge-ci/runner/bin
COPY runner/lib /forge-ci/runner/lib
COPY runner/aws /forge-ci/runner/aws

# App gems.
COPY web/Gemfile web/Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile

# App code.
COPY web/ ./
RUN bundle exec bootsnap precompile -j 1 app/ lib/

FROM base

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
COPY --chown=rails:rails --from=build /forge-ci /forge-ci

# /rails/storage is the data volume: generated secrets, logs, caches,
# artifacts. Created here so a fresh named volume is owned by the app user.
RUN mkdir -p /rails/storage /rails/tmp /rails/log && chown -R rails:rails /rails/storage /rails/tmp /rails/log
VOLUME /rails/storage
USER 1000:1000

# The stock entrypoint runs `db:prepare` when the command is `./bin/rails server`.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
