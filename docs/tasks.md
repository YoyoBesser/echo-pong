# Tasks

## Container
- Multi-stage `Dockerfile` (Go build → minimal/distroless runtime)
- Non-root user, read-only root FS
- `.dockerignore` (currently gitignored — un-ignore)
- Multi-arch build (amd64/arm64)

## CI
- Lint / vet / test on PRs
- Make lint blocking: drop `continue-on-error` (`docs/CI.md#soft-fail`)
- `helm lint` + `helm template` validation
- Build multi-arch image
- Vulnerability scan; fail on critical/high
- Secret scanning

## CD / Release
- Tag-triggered release (semver `vX.Y.Z`)
- Push images to GHCR (version + sha tags)
- Cross-compiled binaries (linux/darwin × amd64/arm64) on GitHub Releases
- Image signing / SBOM
- Package + push Helm chart to GHCR (OCI), chart version tracks app version
- Retention policy for old/untagged images

## Kubernetes
- Helm chart in `helm/echo-pong/`: Deployment, Service, Ingress (namespace via `--create-namespace`)
- Secret mounted as file (`SECRET_FILE_PATH`), not in repo
- Readiness/liveness/startup probes (`/health`, 10s startup delay)
- Rolling update with zero downtime (maxUnavailable 0, PDB, ≥2 replicas)
- securityContext: non-root, no privilege escalation, drop caps, RO root FS
- Resource requests/limits, HPA
- NetworkPolicy; ingress-only exposure
- ARM64 node affinity
- GHCR pull access (imagePullSecret if private)
- Per-env values files (`values-<env>.yaml`)

## App
- Graceful shutdown on SIGTERM

## Local Testing
- Minikube/Kind cluster setup (ARM64)
- Deploy + verify ping/pong/health through ingress
- Verify zero-downtime rollout

## Documentation
- Approach & architecture decisions
- Deployment & scaling strategy
- Security measures
- CI/CD pipeline, multi-arch, versioning/tagging
- EKS deployment strategy
- Global image distribution (ECR replication / pull-through cache)
- Stale version cleanup
