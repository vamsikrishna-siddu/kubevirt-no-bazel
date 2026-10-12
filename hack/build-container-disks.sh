#!/usr/bin/env bash
#
# This file is part of the KubeVirt project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Copyright The KubeVirt Authors.
#

set -e

source hack/common.sh
source hack/config.sh

IMAGE_PREFIX=${IMAGE_PREFIX:-}
BUILD_OUTPUT_DIR=${BUILD_OUTPUT_DIR:-_out}
CACHE_DIR=${CACHE_DIR:-${BUILD_OUTPUT_DIR}/container-disks}

# rpmtree::fetch downloads the disks into CACHE_DIR, which the images are built from
RPMTREE_CACHE_DIR=${CACHE_DIR}
source hack/rpmtree-utils.sh

# Detect architecture
PLATFORM=$(uname -m)
case ${PLATFORM} in
x86_64* | i?86_64* | amd64*) BUILD_ARCH=${BUILD_ARCH:-amd64} ;;
aarch64* | arm64*) BUILD_ARCH=${BUILD_ARCH:-arm64} ;;
s390x) BUILD_ARCH=${BUILD_ARCH:-s390x} ;;
*)
    echo "Unsupported architecture: ${PLATFORM}"
    exit 1
    ;;
esac

echo "==============================================="
echo "Building Container Disk Images"
echo "Architecture: ${BUILD_ARCH}"
echo "Container Engine: ${KUBEVIRT_CRI}"
echo "Tag: ${docker_tag}"
echo "Prefix: ${docker_prefix}"
echo "Cache Directory: ${CACHE_DIR}"
echo "==============================================="

mkdir -p "${CACHE_DIR}"

# Build a container disk image from the disk of a WORKSPACE entry
build_container_disk() {
    local name=$1
    local workspace_name=$2
    local package_dir=${3:-/disk}
    local disk

    echo "Building ${name} from ${workspace_name}"
    echo "Package dir: ${package_dir}"
    disk=$(rpmtree::fetch "${workspace_name}")

    # Create Containerfile. The disk is named "downloaded", like the file of
    # the http_file rule that the Bazel image is built from.
    cat >"${CACHE_DIR}/Containerfile.${name}" <<DOCKERFILE
FROM scratch
COPY --chown=107:107 --chmod=0440 $(basename "${disk}") ${package_dir}/downloaded
DOCKERFILE

    # Build image
    local full_tag="${docker_prefix}/${IMAGE_PREFIX}${name}:${docker_tag}"
    echo "Building image: ${full_tag}"
    ${KUBEVIRT_CRI} build \
        --platform linux/${BUILD_ARCH} \
        -f "${CACHE_DIR}/Containerfile.${name}" \
        -t "${full_tag}" \
        "${CACHE_DIR}/"

    rm -f "${CACHE_DIR}/Containerfile.${name}"

    echo "Successfully built ${full_tag}"
}

case ${BUILD_ARCH} in
amd64)
    build_container_disk "alpine-container-disk-demo" "alpine_image"
    build_container_disk "cirros-container-disk-demo" "cirros_image"
    build_container_disk "cirros-custom-container-disk-demo" "cirros_image" "/custom-disk"
    ;;
arm64)
    build_container_disk "alpine-container-disk-demo" "alpine_image_aarch64"
    build_container_disk "cirros-container-disk-demo" "cirros_image_aarch64"
    build_container_disk "cirros-custom-container-disk-demo" "cirros_image_aarch64" "/custom-disk"
    ;;
s390x)
    build_container_disk "alpine-container-disk-demo" "alpine_image_s390x"

    # Cirros not available for s390x
    echo "Skipping cirros images (not available for s390x)"
    ;;
esac

if [[ "${BUILD_ARCH}" != "s390x" ]]; then
    build_container_disk "virtio-container-disk" "virtio_win_image"
fi

echo "Container disk builds complete"
