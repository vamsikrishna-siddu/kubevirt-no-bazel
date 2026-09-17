# Building KubeVirt with Podman or Docker

## Prerequisites

- Podman 4.0+ OR Docker 20.10+
- Make
- Git

No Bazel is needed: Go binaries are built with `go build` in the builder image, and the RPM base images are
assembled with the standalone [bazeldnf](https://github.com/brianmcarey/bazeldnf) binary, which the scripts download.

## Quick Start

```bash
make container-build-images
```

## What Gets Built

The build creates the following images:
- `virt-operator` 
- `virt-api` 
- `virt-controller` 
- `virt-handler` 
- `virt-launcher` (includes QEMU/libvirt)
- `virt-exportserver` 
- `virt-exportproxy`
- Plus many additional helper, test, and sidecar images

## Configuration

Environment variables:
- `KUBEVIRT_CRI` - Container engine to use (`podman` or `docker`, auto-detected by default)
- `BUILD_ARCH` - Target architecture (amd64, arm64, s390x) or comma-separated list for multi-arch
- `DOCKER_TAG` - Image tag (default: devel)
- `DOCKER_PREFIX` - Registry prefix (default: quay.io/kubevirt)
- `IMAGE_PREFIX` - Prefix added to every image name (default: empty)
- `PUSH_TARGETS` - Space-separated list of images to build/push instead of the default set
- `BUILDER_IMAGE` - Builder image to use (default: the version pinned in `hack/dockerized`)
- `BASE_IMAGE_PREFIX` / `BASE_IMAGE_TAG` - Registry and tag of the pre-built RPM base images
  (defaults: `quay.io/vamsi_siddu` / `latest`)

## Multi-Architecture Builds

Pass a comma-separated `BUILD_ARCH` to the regular targets:

```bash
BUILD_ARCH=amd64,arm64,s390x make container-build-images
BUILD_ARCH=amd64,arm64,s390x make container-push-images
```

The multi-arch workflow:
1. Builds each architecture with arch-specific tags (e.g., `devel-amd64`, `devel-arm64`)
2. Uses architecture-specific distroless base image digests (pinned)
3. Pushes each arch-tagged image
4. Creates a multi-arch manifest combining all architectures
5. Pushes the manifest with the main tag (e.g., `devel`)


## Examples

```bash
# Build for specific architecture
BUILD_ARCH=arm64 make container-build-images

# Build with custom tag
DOCKER_TAG=v1.2.3 make container-build-images

# Build with custom registry
DOCKER_PREFIX=my-registry.com/kubevirt make container-build-images
```

### Multi-Architecture Testing

Test builds for multiple architectures:

```bash
export BUILD_ARCH=amd64,arm64

make cluster-sync
```

## Base Images

RPM base images (containing system libraries like libvirt, qemu, etc.) are built separately
and only need to be rebuilt when RPM dependencies change. See `hack/rpm-base-images/` for details.

```bash
# Build base images (downloads the pinned RPMs and assembles them with bazeldnf)
make rpm-base-build

# Push base images
make rpm-base-push
```

The RPMs are downloaded from the URLs pinned in `WORKSPACE` (GCS mirror first), verified against their
sha256 and cached in `~/.cache/kubevirt/rpms`. The generated tars are written to `~/.cache/kubevirt/rpm-tars`
(override with `RPMTREE_CACHE_DIR` and `RPM_TARS_DIR`).

`make rpm-deps` and `make verify-rpm-deps` also use the standalone bazeldnf binary.

## Using the Bazel Build Instead

Until Bazel is removed ([VEP #392](https://github.com/kubevirt/enhancements/blob/main/veps/sig-buildsystem/392-remove-bazel/vep.md)),
`make cluster-sync` can still build with Bazel:

```bash
KUBEVIRT_USE_BAZEL=true make cluster-sync
```

The `bazel-*` Makefile targets are unchanged. This switch is temporary and will be removed together with Bazel.
