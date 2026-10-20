# Released binary on a stock distro, no app image layers. See docs/CI.md#binary-e2e
ARG BASE=alpine:latest
FROM ${BASE}
COPY ping-pong-app /usr/local/bin/ping-pong-app
ENTRYPOINT ["/usr/local/bin/ping-pong-app"]
