#!/usr/bin/env bash
# Trivy CRITICAL/HIGH scan (OS packages, Go binary, image config) of one arch of an image. See docs/CI.md#image-scan
set -euo pipefail
image="$1" arch="$2"

trivy image --no-progress --platform "linux/$arch" --severity CRITICAL,HIGH \
  --image-config-scanners misconfig --exit-code 1 "$image"
