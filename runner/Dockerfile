# ForgeCI Docker runner. Stdlib-only Ruby plus the docker CLI.
# Run with the host's Docker socket mounted so it can drive the daemon:
#   docker run -v /var/run/docker.sock:/var/run/docker.sock ...
FROM ruby:3.3-slim

# buildx is copied into job images that lack it, for docker_layer_caching
# builds (see docs/configuration.md); keep it fresh when bumping.
ARG BUILDX_VERSION=v0.36.1
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y docker.io ca-certificates git curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives && \
    arch="$(uname -m)" && \
    case "$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) arch="";; esac && \
    if [ -n "$arch" ]; then curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${arch}" -o /usr/local/bin/buildx && chmod 755 /usr/local/bin/buildx; fi

WORKDIR /runner
COPY lib/ lib/
COPY bin/ bin/

# No bundle install — stdlib only. Fails fast without CONTROL_PLANE_URL /
# RUNNER_TOKEN (see runner README for the full env var list). BUILDX_BIN
# points at the binary above (runner/README.md documents it).
ENV BUILDX_BIN=/usr/local/bin/buildx
CMD ["ruby", "bin/forge-ci-runner"]
