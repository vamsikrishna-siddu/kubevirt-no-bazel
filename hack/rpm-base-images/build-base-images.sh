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
# Build RPM base images for KubeVirt components.
# These images contain only the RPM-based filesystem layers and are
# rebuilt only when RPM dependencies change.
#
# The RPM tars are generated with bazeldnf inside the builder container
# (hack/dockerized), so the host only needs podman or docker.

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

# The builder image pinned in hack/dockerized
eval "$(grep -E '^(kubevirt_builder_version|default_kubevirt_builder_image)=' "${REPO_ROOT}/hack/dockerized")"
BUILDER_IMAGE=${BUILDER_IMAGE:-${default_kubevirt_builder_image}}
# Must be inside _out: hack/dockerized copies _out back to the host after
# generating the tars, and each image is built from its own subdirectory.
# Relative to the repo root, so the paths are the same in the builder.
RPM_TARS_DIR="_out/rpm-tars"

build_count=$(echo ${BUILD_ARCH//,/ } | wc -w)

echo "==============================================="
echo "Building RPM Base Images"
echo "==============================================="
echo "Architecture(s): ${BUILD_ARCH}"
echo "Multi-arch: $([ "$build_count" -gt 1 ] && echo "YES" || echo "NO")"
echo "Container Engine: ${KUBEVIRT_CRI}"
echo "Registry: ${docker_prefix}"
echo "Tag: ${BASE_IMAGE_TAG}"
echo "CentOS Stream: ${KUBEVIRT_CENTOS_STREAM_VERSION}"
echo "Builder: ${BUILDER_IMAGE}"
echo "RPM tars: ${RPM_TARS_DIR}"
echo "==============================================="

# Add the tars that Containerfile.<image> copies to tar_requests, as paths in
# the directory given as $3, which is then used as the build context.
generate_tars_for_image() {
    local image=$1
    local arch_tag=$2
    local context=$3
    local rpm_arch
    case ${arch_tag} in
    amd64) rpm_arch="x86_64" ;;
    arm64) rpm_arch="aarch64" ;;
    s390x) rpm_arch="s390x" ;;
    esac

    local trees="${image}"
    if [[ "${image}" == "handlerbase" ]]; then
        # handlerbase also needs passt-repair from the passt tree
        trees+=" passt_tree"
    fi
    if [[ "${image}" == "libvirt-devel" ]]; then
        # cross-linking virt-launcher also needs the libnbd headers/libs
        trees+=" libnbd-devel"
    fi

    rm -rf "${context}"
    local tree
    for tree in ${trees}; do
        tar_requests+=("${context}/${tree}_${rpm_arch}_cs${KUBEVIRT_CENTOS_STREAM_VERSION}.tar")
    done
    if [[ "${image}" == "libguestfs-tools" ]]; then
        tar_requests+=("${context}/appliance_layer_${rpm_arch}.tar")
    fi
}

# Generate the tars in tar_requests in the builder, which has bazeldnf.
# hack/dockerized copies _out back, so they end up in the build contexts.
# The tars don't depend on the builder's architecture, so clear BUILD_ARCH
# to keep hack/dockerized from switching to the amd64-only cross builder.
generate_requested_tars() {
    BUILD_ARCH="" "${REPO_ROOT}/hack/dockerized" \
        "./hack/rpm-base-images/generate-rpm-tars.sh ${tar_requests[*]}"
}

build_for_arch() {
    local arch=$1
    local arch_tag=$(format_archname ${arch} tag)

    local -a arch_images
    read -ra arch_images <<<"$(get_base_images_for_arch ${arch})"

    echo "Targets for ${arch_tag}: ${arch_images[*]}"

    local arch_build_args="--build-arg BUILDER_IMAGE=${BUILDER_IMAGE}"
    arch_build_args+=" --build-arg CENTOS_STREAM_VERSION=${KUBEVIRT_CENTOS_STREAM_VERSION}"

    local -a tar_requests=()
    for image in "${arch_images[@]}"; do
        generate_tars_for_image "${image}" "${arch_tag}" "${RPM_TARS_DIR}/${image}-${arch_tag}"
    done
    generate_requested_tars

    for image in "${arch_images[@]}"; do
        containerfile="${SCRIPT_DIR}/Containerfile.${image}"

        if [[ ! -f "${containerfile}" ]]; then
            echo "ERROR: Containerfile not found: ${containerfile}"
            exit 1
        fi

        # For multi-arch, append arch suffix to the tag
        if [ "$build_count" -gt 1 ]; then
            full_tag="${docker_prefix}/${image}:${BASE_IMAGE_TAG}-${arch_tag}"
        else
            full_tag="${docker_prefix}/${image}:${BASE_IMAGE_TAG}"
        fi

        echo ""
        context="${RPM_TARS_DIR}/${image}-${arch_tag}"
        echo "Building ${image} for ${arch_tag} -> ${full_tag}"
        ${KUBEVIRT_CRI} build \
            ${arch_build_args} \
            --platform "linux/${arch_tag}" \
            -f "${containerfile}" \
            -t "${full_tag}" \
            "${context}"

        echo "Successfully built ${full_tag}"
    done
}

if [ "$build_count" -gt 1 ]; then
    for arch in ${BUILD_ARCH//,/ }; do
        echo ""
        echo "=========================================="
        echo "Building for architecture: ${arch}"
        echo "=========================================="
        build_for_arch "${arch}"
    done
else
    build_for_arch "${BUILD_ARCH}"
fi

echo ""
echo "==============================================="
echo "Base image build completed successfully!"
echo "==============================================="
