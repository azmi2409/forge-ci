# ForgeCI Docker runner. Stdlib-only Ruby plus the docker CLI.
# Run with the host's Docker socket mounted so it can drive the daemon:
#   docker run -v /var/run/docker.sock:/var/run/docker.sock ...
FROM ruby:3.3-slim

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y docker.io ca-certificates git && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /runner
COPY lib/ lib/
COPY bin/ bin/

# No bundle install — stdlib only. Fails fast without CONTROL_PLANE_URL /
# RUNNER_TOKEN (see runner README for the full env var list).
CMD ["ruby", "bin/forge-ci-runner"]
