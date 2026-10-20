#!/usr/bin/env bash
# Trivy CRITICAL/HIGH scan of one arch of an image, Go CVEs govulncheck-filtered. See docs/CI.md#image-scan
set -euo pipefail
image="$1" arch="$2"
report="trivy-image-$arch.json"

trivy image --no-progress --platform "linux/$arch" --severity CRITICAL,HIGH --image-config-scanners misconfig \
  -f json -o plugin=govulncheck "$image" > "$report"
trivy convert --format table --exit-code 1 --severity CRITICAL,HIGH "$report"
