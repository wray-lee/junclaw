# syntax=docker/dockerfile:1

# ── Stage 1: Build ────────────────────────────────────────────
# Build natively on the runner architecture and cross-compile per TARGETARCH.
FROM --platform=$BUILDPLATFORM alpine:3.24 AS builder

ARG ZIG_VERSION=0.16.0

RUN apk add --no-cache bash curl git musl-dev python3

WORKDIR /app
COPY .github/scripts/install-zig.sh .github/scripts/install-zig.sh
COPY build.zig build.zig.zon ./
COPY src/ src/
COPY vendor/sqlite3/ vendor/sqlite3/

RUN set -eu; \
    mkdir -p /tmp/zig-path; \
    GITHUB_PATH=/tmp/zig-path/path RUNNER_TEMP=/opt bash .github/scripts/install-zig.sh "${ZIG_VERSION}"; \
    ln -sf "$(cat /tmp/zig-path/path)/zig" /usr/local/bin/zig; \
    test "$(zig version)" = "0.16.0"

ARG TARGETARCH
ARG VERSION=dev
RUN --mount=type=cache,target=/root/.cache/zig \
    --mount=type=cache,target=/app/.zig-cache \
    set -eu; \
    arch="${TARGETARCH:-}"; \
    if [ -z "${arch}" ]; then \
      case "$(uname -m)" in \
        x86_64) arch="amd64" ;; \
        aarch64|arm64) arch="arm64" ;; \
        *) echo "Unsupported host arch: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "${arch}" in \
      amd64) zig_target="x86_64-linux-musl" ;; \
      arm64) zig_target="aarch64-linux-musl" ;; \
      *) echo "Unsupported TARGETARCH: ${arch}" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="${zig_target}" -Doptimize=ReleaseSmall -Dversion="${VERSION}"

# ── Stage 2: Config Prep ─────────────────────────────────────
FROM busybox:1.38 AS config

# Keep config.json at the volume root so existing compose volumes remain readable.
RUN mkdir -p /nullclaw-data/workspace

RUN cat > /nullclaw-data/config.json << 'EOF'
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "openrouter/anthropic/claude-sonnet-4"
      }
    }
  },
  "models": {
    "providers": {
      "openrouter": {}
    }
  },
  "gateway": {
    "port": 3000,
    "host": "::",
    "allow_public_bind": true
  }
}
EOF

# Default runtime runs as non-root (uid/gid 65534).
# Keep writable ownership for HOME/workspace in safe mode.
RUN chown -R 65534:65534 /nullclaw-data

# ── Stage 3: Runtime Base (shared) ────────────────────────────
FROM alpine:3.24 AS release-base

LABEL org.opencontainers.image.source=https://github.com/nullclaw/nullclaw

RUN apk add --no-cache ca-certificates curl git tzdata

COPY --from=builder /app/zig-out/bin/nullclaw /usr/local/bin/nullclaw
COPY --from=config /nullclaw-data /nullclaw-data
RUN chown -R 65534:65534 /nullclaw-data

ENV NULLCLAW_WORKSPACE=/nullclaw-data/workspace
ENV NULLCLAW_HOME=/nullclaw-data
ENV HOME=/nullclaw-data
ENV SHELL=/bin/sh
ENV NULLCLAW_GATEWAY_PORT=3000

WORKDIR /nullclaw-data
EXPOSE 3000
ENTRYPOINT ["nullclaw"]
CMD ["gateway", "--port", "3000", "--host", "::"]

# Optional autonomous mode (explicit opt-in):
#   make build DOCKER_TARGET=release-root IMAGE=nullclaw:root
FROM release-base AS release-root
USER 0:0

# ── Lightpanda image (optional, additive) ────────────────────
# Same junclaw binary and entrypoint as `release`, plus the pinned Lightpanda
# browser. Lightpanda is a glibc binary, so the runtime is Debian; junclaw
# itself is still the static musl build from `builder`.
#   docker build --target lightpanda -t junclaw:lightpanda .
FROM debian:13-slim AS lightpanda

LABEL org.opencontainers.image.source=https://github.com/nullclaw/nullclaw

ARG TARGETARCH
ARG LIGHTPANDA_VERSION=1.0.2

# Runtime packages match the alpine release image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git tzdata \
 && rm -rf /var/lib/apt/lists/*

# Official release asset, pinned per architecture. The build stops if the
# download does not match, so a changed asset cannot ship silently.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) lp_arch="x86_64"; lp_sha="ae7d01d261efb9e480e18ce3424533332883863bcf70b12a4321b5733f37e19e" ;; \
      arm64) lp_arch="aarch64"; lp_sha="ac546dfc43c533430da92b75ab36f2a29da7d6324d5d38baf606ef2e0d849345" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/lightpanda \
      "https://github.com/lightpanda-io/browser/releases/download/${LIGHTPANDA_VERSION}/lightpanda-${lp_arch}-linux"; \
    echo "${lp_sha}  /usr/local/bin/lightpanda" | sha256sum -c -; \
    chmod +x /usr/local/bin/lightpanda; \
    test "$(LIGHTPANDA_DISABLE_TELEMETRY=true lightpanda version)" = "${LIGHTPANDA_VERSION}"

COPY --from=builder /app/zig-out/bin/nullclaw /usr/local/bin/nullclaw
COPY --from=config /nullclaw-data /nullclaw-data
RUN chown -R 65534:65534 /nullclaw-data

# AGPL-3.0: full license, version, source and "unmodified binary" notice.
COPY assets/lightpanda/AGPL-3.0.txt assets/lightpanda/NOTICE.txt /usr/share/doc/lightpanda/

ENV NULLCLAW_WORKSPACE=/nullclaw-data/workspace
ENV NULLCLAW_HOME=/nullclaw-data
ENV HOME=/nullclaw-data
ENV SHELL=/bin/sh
ENV NULLCLAW_GATEWAY_PORT=3000
# Lightpanda collects usage telemetry by default; the image turns it off.
ENV LIGHTPANDA_DISABLE_TELEMETRY=true

WORKDIR /nullclaw-data
EXPOSE 3000
ENTRYPOINT ["nullclaw"]
CMD ["gateway", "--port", "3000", "--host", "::"]
USER 65534:65534

# ── Firefox WebDriver image (optional, additive) ─────────────
# Same junclaw binary and entrypoint as `release`, plus Debian's Firefox ESR
# and a pinned geckodriver. Firefox is a glibc program, so the runtime is
# Debian (like `lightpanda`); junclaw itself is still the static musl build.
#   docker build --target browser -t junclaw:browser .
FROM debian:13-slim AS browser

LABEL org.opencontainers.image.source=https://github.com/nullclaw/nullclaw

ARG TARGETARCH
ARG GECKODRIVER_VERSION=0.37.1

# Runtime packages match `lightpanda`; fonts keep headless screenshots legible.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git tzdata \
      firefox-esr fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/* \
 && firefox-esr --version

# Official release asset, pinned per architecture. The build stops if the
# download does not match, so a changed asset cannot ship silently.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) gd_arch="linux64"; gd_sha="e815130ea95983e162ae91843b48d3a3ce991735635fce83a647afde21e09f7e" ;; \
      arm64) gd_arch="linux-aarch64"; gd_sha="8fd90b951422fbad5b56539fb344dff66eb3f986d615d8d6fde9f1f62dad610c" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/geckodriver.tar.gz \
      "https://github.com/mozilla/geckodriver/releases/download/v${GECKODRIVER_VERSION}/geckodriver-v${GECKODRIVER_VERSION}-${gd_arch}.tar.gz"; \
    echo "${gd_sha}  /tmp/geckodriver.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/geckodriver.tar.gz -C /usr/local/bin geckodriver; \
    rm /tmp/geckodriver.tar.gz; \
    chmod +x /usr/local/bin/geckodriver; \
    test "$(geckodriver --version | head -n1 | cut -d' ' -f2)" = "${GECKODRIVER_VERSION}"

# geckodriver looks up `firefox` on PATH; Debian installs `firefox-esr`.
RUN ln -s /usr/bin/firefox-esr /usr/local/bin/firefox

COPY --from=builder /app/zig-out/bin/nullclaw /usr/local/bin/nullclaw
COPY --from=config /nullclaw-data /nullclaw-data
RUN chown -R 65534:65534 /nullclaw-data

ENV NULLCLAW_WORKSPACE=/nullclaw-data/workspace
ENV NULLCLAW_HOME=/nullclaw-data
ENV HOME=/nullclaw-data
ENV SHELL=/bin/sh
ENV NULLCLAW_GATEWAY_PORT=3000

WORKDIR /nullclaw-data
EXPOSE 3000
ENTRYPOINT ["nullclaw"]
CMD ["gateway", "--port", "3000", "--host", "::"]
USER 65534:65534

# ── Full dsh image (optional, additive) ──────────────────────
# The targets above are unchanged. This target adds the dsh sidecar harness:
#   docker build --target full-dsh -t junclaw:full-dsh .
# linux/amd64 is the supported platform; the ARM64 runtime has not been tested.
FROM builder AS full-dsh-builder
ARG TARGETARCH
ARG VERSION=dev
RUN --mount=type=cache,target=/root/.cache/zig \
    --mount=type=cache,target=/app/.zig-cache \
    set -eu; \
    arch="${TARGETARCH:-}"; \
    if [ -z "${arch}" ]; then \
      case "$(uname -m)" in \
        x86_64) arch="amd64" ;; \
        aarch64|arm64) arch="arm64" ;; \
        *) echo "Unsupported host arch: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "${arch}" in \
      amd64) zig_target="x86_64-linux-musl" ;; \
      arm64) zig_target="aarch64-linux-musl" ;; \
      *) echo "Unsupported TARGETARCH: ${arch}" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="${zig_target}" -Doptimize=ReleaseSmall -Dversion="${VERSION}" -Dharness_dsh=true

# dsh is installed from the committed lock file, so every package version and
# integrity hash is pinned (0.2.1-rc.2). Native addons ship prebuilt for
# linux-x64; no compiler is needed in this stage.
FROM node:22-slim AS full-dsh-deps
WORKDIR /opt/dsh
COPY docker/dsh/package.json docker/dsh/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

FROM node:22-slim AS full-dsh
LABEL org.opencontainers.image.source=https://github.com/nullclaw/nullclaw

COPY --from=full-dsh-builder /app/zig-out/bin/nullclaw /usr/local/bin/nullclaw
COPY --from=full-dsh-deps /opt/dsh /opt/dsh
COPY --from=config /nullclaw-data /nullclaw-data
RUN mkdir -p /nullclaw-data/.dsh && chown -R 65534:65534 /nullclaw-data

# The dsh sidecar harness is opt-in: agent.harness defaults to the
# in-process dsh engine; set "dsh-sidecar" to use the bundled sidecar.
ENV NULLCLAW_DSH_BIN=/opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js
ENV DSH_HOME=/nullclaw-data/.dsh
ENV NULLCLAW_WORKSPACE=/nullclaw-data/workspace
ENV NULLCLAW_HOME=/nullclaw-data
ENV HOME=/nullclaw-data
ENV SHELL=/bin/sh
ENV NULLCLAW_GATEWAY_PORT=3000

WORKDIR /nullclaw-data
EXPOSE 3000
USER 65534:65534
ENTRYPOINT ["nullclaw"]
CMD ["gateway", "--port", "3000", "--host", "::"]

# ── Full dsh + Firefox WebDriver image (optional, additive) ──
# `full-dsh` plus the same Firefox ESR + geckodriver layer as `browser`.
#   docker build --target full-dsh-browser -t junclaw:full-dsh-browser .
FROM full-dsh AS full-dsh-browser

ARG TARGETARCH
ARG GECKODRIVER_VERSION=0.37.1

# full-dsh leaves the runtime as 65534; apt needs root.
USER 0:0

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
      firefox-esr fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/* \
 && firefox-esr --version

# Same pinned geckodriver asset as the `browser` target.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) gd_arch="linux64"; gd_sha="e815130ea95983e162ae91843b48d3a3ce991735635fce83a647afde21e09f7e" ;; \
      arm64) gd_arch="linux-aarch64"; gd_sha="8fd90b951422fbad5b56539fb344dff66eb3f986d615d8d6fde9f1f62dad610c" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/geckodriver.tar.gz \
      "https://github.com/mozilla/geckodriver/releases/download/v${GECKODRIVER_VERSION}/geckodriver-v${GECKODRIVER_VERSION}-${gd_arch}.tar.gz"; \
    echo "${gd_sha}  /tmp/geckodriver.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/geckodriver.tar.gz -C /usr/local/bin geckodriver; \
    rm /tmp/geckodriver.tar.gz; \
    chmod +x /usr/local/bin/geckodriver; \
    test "$(geckodriver --version | head -n1 | cut -d' ' -f2)" = "${GECKODRIVER_VERSION}"

# geckodriver looks up `firefox` on PATH; Debian installs `firefox-esr`.
RUN ln -s /usr/bin/firefox-esr /usr/local/bin/firefox

USER 65534:65534

# Safe default image (used when no --target is provided)
FROM release-base AS release
USER 65534:65534

