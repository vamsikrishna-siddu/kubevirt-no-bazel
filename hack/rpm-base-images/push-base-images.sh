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
# Build the RPM base images (build-base-images.sh), push them to the registry
# and, when all architectures are pushed, record them, pinned by digest, in
# BASE_IMAGE_VERSIONS, which the component image builds read.

set -eo pipefail

SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(realpath "${SCRIPT_DIR}/../..")"
cd "${REPO_ROOT}"

source "${REPO_ROOT}/hack/common.sh"
source "${REPO_ROOT}/hack/config.sh"
source "${REPO_ROOT}/hack/container-utils.sh"
source "${SCRIPT_DIR}/common.sh"

# RPM updates apply to every architecture
BUILD_ARCH=${BUILD_ARCH:-amd64,arm64,s390x}

# Build the images to push with the same tag, like the Bazel push
BUILD_ARCH=${BUILD_ARCH} \
    DOCKER_PREFIX=${docker_prefix} \
    BASE_IMAGE_TAG=${BASE_IMAGE_TAG} \
    KUBEVIRT_CRI=${KUBEVIRT_CRI} \
    "${SCRIPT_DIR}/build-base-images.sh"

VERSIONS_FILE="${SCRIPT_DIR}/BASE_IMAGE_VERSIONS"

build_count=$(echo ${BUILD_ARCH//,/ } | wc -w)

echo "==============================================="
echo "Pushing RPM Base Images"
echo "==============================================="
echo "Registry: ${docker_prefix}"
echo "Tag: ${BASE_IMAGE_TAG}"
echo "Architecture(s): ${BUILD_ARCH}"
echo "Multi-arch: $([ "$build_count" -gt 1 ] && echo "YES (will create manifests)" || echo "NO")"
echo "==============================================="

PUSH_SUCCESS=()
PUSH_FAILED=()
# "<image>=<registry>/<image>@<digest>" for every pushed image
PUSHED_REFS=()

# Push $1 and set PUSHED_DIGEST to the digest the registry stored.
push_single_image() {
    local full_tag=$1
    local push_flags=$(get_push_flags "${full_tag}")
    local digest_file
    digest_file=$(mktemp)

    echo "Pushing ${full_tag}..."
    if [[ "${KUBEVIRT_CRI}" == "podman" ]]; then
        if ! ${KUBEVIRT_CRI} push ${push_flags} --digestfile "${digest_file}" "${full_tag}"; then
            echo "ERROR: Failed to push ${full_tag}"
            rm -f "${digest_file}"
            return 1
        fi
        PUSHED_DIGEST=$(cat "${digest_file}")
    else
        if ! ${KUBEVIRT_CRI} push "${full_tag}"; then
            echo "ERROR: Failed to push ${full_tag}"
            rm -f "${digest_file}"
            return 1
        fi
        PUSHED_DIGEST=$(${KUBEVIRT_CRI} inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${full_tag}" |
            sed -n "s|^${full_tag%:*}@||p" | head -1)
    fi
    rm -f "${digest_file}"
    echo "Successfully pushed ${full_tag} (${PUSHED_DIGEST})"
}

if [ "$build_count" -gt 1 ]; then
    # Multi-arch: push each arch-tagged image, then create manifests
    for arch in ${BUILD_ARCH//,/ }; do
        arch_tag=$(format_archname ${arch} tag)
        local_images=()
        read -ra local_images <<<"$(get_base_images_for_arch ${arch})"

        echo ""
        echo "=========================================="
        echo "Pushing images for architecture: ${arch_tag}"
        echo "=========================================="

        for image in "${local_images[@]}"; do
            full_tag="${docker_prefix}/${image}:${BASE_IMAGE_TAG}-${arch_tag}"
            if ! push_single_image "${full_tag}"; then
                PUSH_FAILED+=("${image}:${arch_tag}")
            fi
        done
    done

    echo ""
    echo "=========================================="
    echo "Creating multi-arch manifests"
    echo "=========================================="

    # Every image built for at least one of the architectures
    manifest_images=()
    for arch in ${BUILD_ARCH//,/ }; do
        for image in $(get_base_images_for_arch ${arch}); do
            [[ " ${manifest_images[*]} " == *" ${image} "* ]] || manifest_images+=("${image}")
        done
    done

    # One manifest per image, with the architectures it was built for
    for image in "${manifest_images[@]}"; do
        manifest_tag="${docker_prefix}/${image}:${BASE_IMAGE_TAG}"
        echo ""
        echo "Creating manifest: ${manifest_tag}"

        arch_tags=()
        for arch in ${BUILD_ARCH//,/ }; do
            arch_tag=$(format_archname ${arch} tag)
            # Only include if this image exists for this arch
            local_images=()
            read -ra local_images <<<"$(get_base_images_for_arch ${arch})"
            for img in "${local_images[@]}"; do
                if [[ "${img}" == "${image}" ]]; then
                    arch_tags+=("${docker_prefix}/${image}:${BASE_IMAGE_TAG}-${arch_tag}")
                    break
                fi
            done
        done

        if [[ "${KUBEVIRT_CRI}" == "podman" ]]; then
            ${KUBEVIRT_CRI} manifest rm "${manifest_tag}" 2>/dev/null || true
            ${KUBEVIRT_CRI} rmi "${manifest_tag}" 2>/dev/null || true
            ${KUBEVIRT_CRI} manifest create "${manifest_tag}" "${arch_tags[@]}"
            push_flags=$(get_push_flags "${manifest_tag}")
            digest_file=$(mktemp)
            ${KUBEVIRT_CRI} manifest push ${push_flags} --digestfile "${digest_file}" "${manifest_tag}" "docker://${manifest_tag}"
            manifest_digest=$(cat "${digest_file}")
            rm -f "${digest_file}"
        elif [[ "${KUBEVIRT_CRI}" == "docker" ]]; then
            docker buildx imagetools create -t "${manifest_tag}" "${arch_tags[@]}"
            manifest_digest=$(docker buildx imagetools inspect "${manifest_tag}" --format '{{.Manifest.Digest}}')
        fi

        PUSH_SUCCESS+=("${image}")
        PUSHED_REFS+=("${image}=${manifest_tag%:*}@${manifest_digest}")
        echo "Created and pushed manifest: ${manifest_tag}"
    done
else
    # Single-arch: push directly
    local_images=()
    read -ra local_images <<<"$(get_base_images_for_arch ${BUILD_ARCH})"

    for image in "${local_images[@]}"; do
        full_tag="${docker_prefix}/${image}:${BASE_IMAGE_TAG}"
        if push_single_image "${full_tag}"; then
            PUSH_SUCCESS+=("${image}")
            PUSHED_REFS+=("${image}=${full_tag%:*}@${PUSHED_DIGEST}")
        else
            PUSH_FAILED+=("${image}")
        fi
    done
fi

if [[ ${#PUSH_FAILED[@]} -gt 0 ]]; then
    echo ""
    echo "ERROR: Failed to push: ${PUSH_FAILED[*]}"
    exit 1
fi

# The pins serve every architecture, so only a push of all of them updates them
pushed_archs=$(for arch in ${BUILD_ARCH//,/ }; do format_archname ${arch} tag; done | sort -u | xargs)
if [[ "${pushed_archs}" == "amd64 arm64 s390x" ]]; then
    echo ""
    echo "==============================================="
    echo "Updating ${VERSIONS_FILE}"
    echo "==============================================="

    # Only replace the lines of the images pushed now, so pushing a subset
    # (BASE_IMAGE_TARGETS) keeps the other entries.
    for entry in "${PUSHED_REFS[@]}"; do
        name=${entry%%=*}
        if [[ "${entry}" != *@sha256:* ]]; then
            echo "ERROR: no digest recorded for ${name}: ${entry}"
            exit 1
        fi
        if grep -q "^${name}=" "${VERSIONS_FILE}"; then
            sed -i "s|^${name}=.*|${entry}|" "${VERSIONS_FILE}"
        else
            echo "${entry}" >>"${VERSIONS_FILE}"
        fi
        echo "  ${entry}"
    done

    echo "Updated ${VERSIONS_FILE}"
else
    echo ""
    echo "Not all architectures pushed (${pushed_archs}), so ${VERSIONS_FILE} is unchanged."
    echo "To build with these images: BASE_IMAGE_PREFIX=${docker_prefix} BASE_IMAGE_TAG=${BASE_IMAGE_TAG}"
fi
echo ""
echo "==============================================="
echo "Push completed successfully!"
echo "==============================================="
