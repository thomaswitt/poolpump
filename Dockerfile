# syntax=docker/dockerfile:1.16.0

### Build image
#
# docker build -t poolpump:latest .
# docker images poolpump:latest --format '{{.Size}}'
#
### Run dev (non-privileged ports — no sudo needed):
#
# docker run --rm -e MODBUS_PORT=5020 -e HTTP_PORT=8090 \
#   -p 5020:5020 -p 8090:8090 poolpump:latest
#
### Run production (compose handles privileged port 502):
#
# docker compose up -d --build
# docker compose logs -f poolpump-emulator
#
### Drop into a shell to poke around:
#
# docker run --rm -it poolpump:latest bash

# Build context = repo root. The Ruby app lives under `server/` — we copy
# only that subtree into the image, so reverse-engineering notes + host-side
# snapshots and logs (`_data/`, `_log/`) and the demo client (`poolpump.sh`)
# stay out of the image.

# Make sure RUBY_VERSION matches the Ruby version in server/.ruby-version
ARG RUBY_VERSION=3.4.8

# Multi-stage: a heavier `builder` stage compiles native gems, then the
# slim `runtime` stage gets only the bundled gems + app code + the runtime
# shared libraries (no compiler toolchain). ~820 MB → ~314 MB.

### BUILDER STAGE ##################################################
FROM public.ecr.aws/docker/library/ruby:${RUBY_VERSION}-slim AS builder

ENV BUNDLE_PATH=/usr/local/bundle \
  BUNDLE_WITHOUT='development:test' \
  BUNDLE_JOBS=4 \
  BUNDLE_RETRY=3 \
  LANG=C.UTF-8

# Native-extension build deps:
#   build-essential — gcc/make for compiling C extensions
#   libssl-dev      — headers for `openssl` gem (pulled in by falcon)
#   libyaml-dev     — headers for `psych` (YAML parser bundled with Ruby)
#   libffi-dev      — headers for any `ffi`-using gem
#   pkg-config      — used by openssl/libyaml extconf to find headers
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       build-essential libssl-dev libyaml-dev libffi-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --link server/Gemfile server/Gemfile.lock* ./

# Add the platforms we might build on so a Gemfile.lock generated on macOS
# (x86_64-darwin / arm64-darwin) doesn't trip on a Pi build (aarch64-linux).
# `bundle install` follows.
RUN bundle lock --add-platform aarch64-linux \
  && bundle lock --add-platform arm64-linux \
  && bundle lock --add-platform x86_64-linux \
  && bundle install

### RUNTIME STAGE ##################################################
FROM public.ecr.aws/docker/library/ruby:${RUBY_VERSION}-slim AS runtime

ENV BUNDLE_PATH=/usr/local/bundle \
  BUNDLE_WITHOUT='development:test' \
  LANG=C.UTF-8

# Runtime shared libraries only (no compiler toolchain). Names match the
# *-dev packages used in the builder stage minus the headers.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       libssl3 libyaml-0-2 libffi8 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the compiled gems from the builder stage.
COPY --link --from=builder /usr/local/bundle /usr/local/bundle

# Copy the application source (only `server/`, not the rest of the repo).
COPY --link server/ ./

# Run as a non-root user. The container only ever needs to read its own
# code and write to stdout/stderr — no filesystem mutations, no privileged
# bind (Docker handles port 502 forwarding outside the container).
RUN groupadd --system --gid 1000 poolpump \
  && useradd poolpump --uid 1000 --gid 1000 --create-home --shell /bin/bash \
  && chown -R 1000:1000 /app
USER 1000:1000

LABEL com.docker.compose.project="poolpump" \
  com.docker.compose.service="poolpump-emulator"

EXPOSE 502 8090

CMD ["bundle", "exec", "bin/poolpump-emulator"]
