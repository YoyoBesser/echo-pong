# Release

README L64 "Versioned releases with tags", L65 "Both container and binary releases", L113 "versioning and tagging strategy". A release publishes exactly those two artifacts: the multi-arch image and the binaries. Workflow: [`release.yml`](../.github/workflows/release.yml).

## Versioning

[Semantic versioning](https://semver.org), `vX.Y.Z`. A release is cut by pushing an annotated tag on `main`:

```sh
git tag -a v1.2.3 -m "v1.2.3" && git push origin v1.2.3
```

- **MAJOR:** an incompatible change to the API (`/ping`, `/pong`, `/health`) or the CLI flags.
- **MINOR:** a backward-compatible feature.
- **PATCH:** fixes, including dependency and Go toolchain bumps for CVEs.

The tag is the single version source. It's stamped into the binary ([CONTAINER.md#version](CONTAINER.md#version)) and becomes the image tag.

| Artifact | Where | Tag |
|---|---|---|
| Image (linux/amd64 + linux/arm64 index) | `ghcr.io/yoyobesser/echo-pong` | `vX.Y.Z`, with SBOM + provenance attestations |
| Binaries | GitHub Release `vX.Y.Z` | `ping-pong-app_vX.Y.Z_{linux,darwin}_{amd64,arm64}.tar.gz` + `checksums.txt` |
| CI images (not releases) | `ghcr.io/yoyobesser/echo-pong` | full commit SHA, pruned after 14 days ([CI.md#image-cleanup](CI.md#image-cleanup)) |

There's no `latest` tag. Deployments pin a version, and kube-linter's `latest-tag` check enforces that in manifests.

## Pipeline

```
image (build, push by digest only) ─┐
scan-source ────────────────────────┼─► publish (tag vX.Y.Z) ─────────────────────┐
scan-repo ──────────────────────────┤                                            ├─► github-release
scan-image (that digest) ───────────┘   binaries (linux from image, darwin) ─────┘
```

1. `image` builds both arches once, with `VERSION=vX.Y.Z`, and pushes **by digest**, with no tag. Nothing is "released" yet.
2. The gate: the same [reusable scans](CI.md#reusable-scans) as CI, blocking. `scan-image` scans exactly that digest.
3. `publish` runs only if every scan passed. It tags **the scanned digest** as `vX.Y.Z` (`docker buildx imagetools create`), so what's released is byte-for-byte what was scanned.
4. `binaries` and `github-release` publish the [binaries](#binaries).

A finding at step 2 means no tag and no GitHub Release (README L51). The untagged digest is pruned by the [cleanup workflow](CI.md#image-cleanup).

## Attestations

buildx attaches an SBOM (SPDX) and SLSA provenance (`mode=max`) to the release index. Inspect them with `docker buildx imagetools inspect --format '{{json .SBOM}}' ghcr.io/yoyobesser/echo-pong:vX.Y.Z`.

## Binaries

[`release-binaries.sh`](../.github/scripts/release-binaries.sh):

- **linux/amd64, linux/arm64:** copied out of the scanned release image ([CI.md#static-binary](CI.md#static-binary)), so they're the same bytes as the container.
- **darwin/amd64, darwin/arm64:** cross-compiled from the same commit with the same flags (`CGO_ENABLED=0`, `-trimpath`, version stamp).
- Each is a `.tar.gz`, with `checksums.txt` (SHA-256) alongside.

## Testing a release locally

```sh
.github/scripts/act.sh release --tag v0.0.1
```

This runs the whole pipeline against the local registry, which stands in for GHCR. The GitHub Release is skipped (`"act": true` in the event payload), so nothing is published.
