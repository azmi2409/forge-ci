# syntax=docker/dockerfile:1
# ForgeCI Go runner image (used by docker-compose during the cutover; build
# context is runner-go/). Static binary + the tools the runner drives:
# the docker CLI (job containers, socket mounts), buildx (copied into job
# images that lack it, for docker_layer_caching builds), tar and curl
# (forge-ci-asg-terminate-self needs curl).
#
#   docker build -t forge-ci-runner-go .
#   docker run -v /var/run/docker.sock:/var/run/docker.sock ...

FROM golang:1.27-alpine AS build
ARG RUNNER_VERSION=dev
COPY . /src/runner-go
WORKDIR /src/runner-go
RUN CGO_ENABLED=0 go build -trimpath \
      -ldflags "-s -w -X github.com/azmi2409/forge-ci/runner-go/internal/version.Version=${RUNNER_VERSION}" \
      -o /out/forge-ci-runner ./cmd/forge-ci-runner

ARG BUILDX_VERSION=v0.36.1
FROM alpine:3.20
RUN apk add --no-cache docker-cli tar curl git ca-certificates && \
    arch="$(uname -m)" && \
    case "$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) arch="";; esac && \
    if [ -n "$arch" ]; then curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${arch}" -o /usr/local/bin/buildx && chmod 755 /usr/local/bin/buildx; fi

COPY --from=build /out/forge-ci-runner /usr/local/bin/forge-ci-runner
ENV BUILDX_BIN=/usr/local/bin/buildx
CMD ["forge-ci-runner"]
