# syntax=docker/dockerfile:1.7
FROM ghcr.io/getburrowing/node:22-bookworm-slim@sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    git \
    openssh-client \
    python3 \
  && update-ca-certificates \
  && npm install -g @anthropic-ai/claude-code @openai/codex \
  && usermod -u 1001 node \
  && mkdir -p /workspace /tmp/suite-runner \
  && chown -R node:node /workspace /tmp/suite-runner /home/node \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

ENV HOME=/home/node

WORKDIR /workspace
USER node

CMD ["/bin/bash", "-lc", "echo 'suite-runner ready'; sleep infinity"]
