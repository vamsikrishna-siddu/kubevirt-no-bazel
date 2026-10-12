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
source hack/container-utils.sh

echo "Using container engine: ${KUBEVIRT_CRI}"

IMAGE_PREFIX=${IMAGE_PREFIX:-}

# Auto-detect architecture from platform if not set
if [ -z "${BUILD_ARCH}" ]; then
    PLATFORM=$(uname -m)
    case ${PLATFORM} in
    x86_64* | i?86_64* | amd64*) BUILD_ARCH="amd64" ;;
    aarch64* | arm64*) BUILD_ARCH="arm64" ;;
    s390x) BUILD_ARCH="s390x" ;;
    *) BUILD_ARCH="amd64" ;;
    esac
fi

DIGESTS_DIR=${DIGESTS_DIR:-${OUT_DIR}/digests}

build_count=$(echo ${BUILD_ARCH//,/ } | wc -w)

# Print the images to push for the architecture $1: PUSH_TARGETS, or the
# default set
push_targets() {
    if [[ -n "${PUSH_TARGETS}" ]]; then
        echo ${PUSH_TARGETS}
    else
        container_image_targets "$1"
    fi
}

PUSH_FAILED=()
PUSH_SUCCESS=()

echo "==============================================="
echo "Pushing KubeVirt Images with ${KUBEVIRT_CRI}"
echo "==============================================="
echo "Registry: ${docker_prefix}"
echo "Tag: ${docker_tag}"
echo "Architecture: ${BUILD_ARCH}"
if [ "$build_count" -gt 1 ]; then
    echo "Multi-arch build: YES (will add arch suffix to tags)"
else
    echo "Multi-arch build: NO (single tag)"
fi
echo "==============================================="

check_image_exists() {
    local full_tag=$1

    if ${KUBEVIRT_CRI} image exists "${full_tag}" 2>/dev/null; then
        return 0
    elif ${KUBEVIRT_CRI} image inspect "${full_tag}" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Print the local tag of the image $1 for the architecture $2. A multi-arch
# build tags each architecture with its own suffix.
image_tag() {
    if [ "$build_count" -gt 1 ]; then
        echo "${docker_prefix}/${IMAGE_PREFIX}$1:${docker_tag}-$(format_archname $2 tag)"
    else
        echo "${docker_prefix}/${IMAGE_PREFIX}$1:${docker_tag}"
    fi
}

echo "Checking if images exist locally..."
MISSING_IMAGES=()

for arch in ${BUILD_ARCH//,/ }; do
    targets=$(push_targets ${arch})
    for image in ${targets}; do
        full_tag=$(image_tag ${image} ${arch})
        if check_image_exists "${full_tag}"; then
            echo "- ${full_tag}"
        else
            MISSING_IMAGES+=("${full_tag}")
        fi
    done
done

if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
    echo "ERROR: The following images were not found locally:"
    for img in "${MISSING_IMAGES[@]}"; do
        echo "- ${img}"
    done
    echo "Please build images first"
    exit 1
fi

push_image() {
    local image_name=$1
    local arch=$2
    local full_tag
    full_tag=$(image_tag ${image_name} ${arch})

    echo "Pushing ${image_name}"
    echo "Tag: ${full_tag}"

    local push_flags=$(get_push_flags "${full_tag}")

    if ${KUBEVIRT_CRI} push ${push_flags} "${full_tag}"; then
        echo "Successfully pushed"

        # Mark the image as pushed for push-container-manifest.sh
        local digest_dir="${DIGESTS_DIR}/${arch}/${image_name}"
        mkdir -p "${digest_dir}"
        touch "${digest_dir}/${image_name}.image"
        echo "- Created marker: ${digest_dir}/${image_name}.image"

        PUSH_SUCCESS+=("${image_name}:${full_tag}")
        return 0
    else
        echo "- Failed to push"
        PUSH_FAILED+=("${image_name}:${full_tag}")
        return 1
    fi
}

echo "Pushing images..."

for arch in ${BUILD_ARCH//,/ }; do
    targets=$(push_targets ${arch})
    arch=$(format_archname ${arch})
    # Start without the markers of earlier pushes
    rm -rf "${DIGESTS_DIR}/${arch}"
    if [ "$build_count" -gt 1 ]; then
        echo "=========================================="
        echo "Architecture: ${arch}"
        echo "=========================================="
    fi
    for image in ${targets}; do
        push_image "${image}" "${arch}" || true
        echo ""
    done
done

echo "==============================================="
echo "Push Summary"
echo "==============================================="
echo "Successfully pushed: ${#PUSH_SUCCESS[@]} images"
for img in "${PUSH_SUCCESS[@]}"; do
    echo "- ${img}"
done

if [ ${#PUSH_FAILED[@]} -gt 0 ]; then
    echo "Failed to push: ${#PUSH_FAILED[@]} images"
    for img in "${PUSH_FAILED[@]}"; do
        echo "- ${img}"
    done
    exit 1
fi
