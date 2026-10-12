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

set -e

source hack/common.sh
source hack/config.sh
source hack/version.sh
source hack/container-utils.sh

echo "Using container engine: ${KUBEVIRT_CRI}"

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

IMAGE_PREFIX=${IMAGE_PREFIX:-}

# Builder image configuration
BUILDER_VERSION=$(grep 'kubevirt_builder_version=' hack/dockerized | cut -d'"' -f2)
BUILDER_IMAGE=${BUILDER_IMAGE:-quay.io/vamsi_siddu/builder:${BUILDER_VERSION}}

PLATFORM_ARCH=$(format_archname ${BUILD_ARCH} tag)

# Print the digest of the pull() rule named $1 in WORKSPACE. The Bazel build
# pins these images there and the bump scripts update them, so read them
# instead of keeping copies here.
workspace_digest() {
    local digest
    digest=$(awk -v name="\"$1\"," '
        $1 == "name" && $3 == name { found = 1 }
        found && $1 == "digest" { gsub(/[",]/, "", $3); print $3; exit }
    ' WORKSPACE)
    if [[ -z "${digest}" ]]; then
        echo "ERROR: no digest for $1 in WORKSPACE" >&2
        return 1
    fi
    echo "${digest}"
}

# Print the value of the digest variable $1 in images/virt-template/deps.bzl,
# which hack/virt-template/bump.sh updates.
virt_template_digest() {
    local digest
    digest=$(sed -n "s/^$1 = \"\(sha256:[0-9a-f]*\)\"\$/\1/p" images/virt-template/deps.bzl)
    if [[ -z "${digest}" ]]; then
        echo "ERROR: no $1 in images/virt-template/deps.bzl" >&2
        return 1
    fi
    echo "${digest}"
}

# Distroless base image per architecture, as in the Bazel build
case ${PLATFORM_ARCH} in
amd64)
    DISTROLESS_DIGEST=$(workspace_digest go_image_base)
    ;;
arm64)
    DISTROLESS_DIGEST=$(workspace_digest go_image_base_aarch64)
    ;;
s390x)
    DISTROLESS_DIGEST=$(workspace_digest go_image_base_s390x)
    ;;
*)
    echo "Error: Unsupported architecture ${PLATFORM_ARCH} (from BUILD_ARCH=${BUILD_ARCH})"
    exit 1
    ;;
esac

DISTROLESS_BASE_IMAGE="gcr.io/distroless/base-debian12@${DISTROLESS_DIGEST}"

# Base image of the passt binding CNI plugin, as in the Bazel build
BUSYBOX_IMAGE="registry.k8s.io/busybox@$(workspace_digest busybox)"

kubevirt::version::get_version_vars
KUBEVIRT_VERSION=${KUBEVIRT_GIT_VERSION:-"devel"}

# RPM base images: pinned by digest in hack/rpm-base-images/BASE_IMAGE_VERSIONS
# (written by push-base-images.sh). Setting BASE_IMAGE_PREFIX (docker_prefix by
# default) or BASE_IMAGE_TAG uses <prefix>/<image>:<tag> instead, e.g. for base
# images built and pushed for testing.
BASE_IMAGE_VERSIONS=hack/rpm-base-images/BASE_IMAGE_VERSIONS
base_image() {
    if [[ -n "${BASE_IMAGE_PREFIX}${BASE_IMAGE_TAG}" ]]; then
        echo "${BASE_IMAGE_PREFIX:-${docker_prefix}}/$1:${BASE_IMAGE_TAG:-latest}"
        return
    fi
    local ref
    ref=$(sed -n "s|^$1=||p" "${BASE_IMAGE_VERSIONS}")
    if [[ -z "${ref}" ]]; then
        echo "ERROR: no $1 entry in ${BASE_IMAGE_VERSIONS}" >&2
        return 1
    fi
    echo "${ref}"
}
LAUNCHERBASE_IMAGE=${LAUNCHERBASE_IMAGE:-$(base_image launcherbase)}
LIBVIRT_DEVEL_IMAGE=${LIBVIRT_DEVEL_IMAGE:-$(base_image libvirt-devel)}
HANDLERBASE_IMAGE=${HANDLERBASE_IMAGE:-$(base_image handlerbase)}
EXPORTSERVERBASE_IMAGE=${EXPORTSERVERBASE_IMAGE:-$(base_image exportserverbase)}
LIBGUESTFS_BASE_IMAGE=${LIBGUESTFS_BASE_IMAGE:-$(base_image libguestfs-tools)}
PR_HELPER_BASE_IMAGE=${PR_HELPER_BASE_IMAGE:-$(base_image pr-helper)}
SIDECAR_SHIM_BASE_IMAGE=${SIDECAR_SHIM_BASE_IMAGE:-$(base_image sidecar-shim)}
TESTIMAGE_BASE_IMAGE=${TESTIMAGE_BASE_IMAGE:-$(base_image testimage)}

BUILD_ARGS="--build-arg KUBEVIRT_VERSION=${KUBEVIRT_VERSION}"
BUILD_ARGS+=" --build-arg BUILD_ARCH=${BUILD_ARCH}"
BUILD_ARGS+=" --build-arg BUILDER_IMAGE=${BUILDER_IMAGE}"
BUILD_ARGS+=" --build-arg DISTROLESS_BASE_IMAGE=${DISTROLESS_BASE_IMAGE}"

# The images that push-images-container.sh pushes, plus the virt-template
# images: those are only retagged here, because the operator deploys them
# with the virt-template version as the tag, not with DOCKER_TAG.
default_targets="$(container_image_targets ${BUILD_ARCH}) virt-template-apiserver virt-template-controller"

# Allow override via PUSH_TARGETS
BUILD_TARGETS=(${PUSH_TARGETS:-${default_targets}})

get_containerfile_path() {
    local image_name=$1
    case "$image_name" in
    virt-operator | virt-api | virt-controller | virt-handler | virt-launcher | virt-exportserver | virt-exportproxy)
        echo "cmd/${image_name}/Containerfile"
        ;;
    virt-synchronization-controller) echo "cmd/synchronization-controller/Containerfile" ;;
    pr-helper) echo "cmd/${image_name}/Containerfile" ;;
    vm-killer) echo "images/vm-killer/Containerfile" ;;
    disks-images-provider) echo "images/disks-images-provider/Containerfile" ;;
    winrmcli) echo "images/winrmcli/Containerfile" ;;
    conformance) echo "tests/conformance/Containerfile" ;;
    libguestfs-tools) echo "cmd/libguestfs/Containerfile" ;;
    sidecar-shim) echo "cmd/sidecars/Containerfile" ;;
    network-passt-binding) echo "cmd/sidecars/network-passt-binding/Containerfile" ;;
    network-passt-binding-cni) echo "cmd/cniplugins/passt-binding/cmd/Containerfile" ;;
    test-network-vhostuser-dra-binding) echo "cmd/sidecars/test-network-vhostuser-dra-binding/Containerfile" ;;
    example-hook-sidecar) echo "cmd/sidecars/smbios/Containerfile" ;;
    example-disk-mutation-hook-sidecar) echo "cmd/sidecars/disk-mutation/Containerfile" ;;
    example-cloudinit-hook-sidecar) echo "cmd/sidecars/cloudinit/Containerfile" ;;
    example-node-hook-plugin) echo "cmd/example-node-hook-plugin/Containerfile" ;;
    test-launcher-hook-sidecar) echo "cmd/plugin-sidecars/test-launcher-hook/Containerfile" ;;
    test-helpers) echo "cmd/test-helpers/pod-mutator/Containerfile" ;;
    *)
        echo "ERROR: Unknown image: $image_name" >&2
        return 1
        ;;
    esac
}

build_image() {
    local image_name=$1
    local containerfile=$2
    local context=${3:-.}
    local extra_build_args=${4:-}

    local full_tag="${docker_prefix}/${IMAGE_PREFIX}${image_name}:${docker_tag}"
    echo "Building ${image_name} for ${BUILD_ARCH} (linux/${PLATFORM_ARCH})"

    ${KUBEVIRT_CRI} build ${BUILD_ARGS} --platform linux/${PLATFORM_ARCH} ${extra_build_args} \
        -f ${containerfile} -t ${full_tag} ${context}
    echo "Successfully built ${full_tag}"
}

is_retagged_image() {
    local image_name=$1
    case "$image_name" in
    fedora-with-test-tooling-container-disk | alpine-with-test-tooling-container-disk | fedora-realtime-container-disk | alpine-ext-kernel-boot-demo | s390x-guestless-kernel | virt-template-apiserver | virt-template-controller)
        return 0
        ;;
    *) return 1 ;;
    esac
}

is_container_disk_image() {
    local image_name=$1
    case "$image_name" in
    alpine-container-disk-demo | cirros-container-disk-demo | cirros-custom-container-disk-demo | virtio-container-disk)
        return 0
        ;;
    *) return 1 ;;
    esac
}

retag_single_image() {
    local image_name=$1
    case "$image_name" in
    fedora-with-test-tooling-container-disk)
        local normalized_arch=$(format_archname ${BUILD_ARCH} tag)
        case ${normalized_arch} in
        amd64) DIGEST=$(workspace_digest fedora_with_test_tooling) ;;
        arm64) DIGEST=$(workspace_digest fedora_with_test_tooling_aarch64) ;;
        s390x) DIGEST=$(workspace_digest fedora_with_test_tooling_s390x) ;;
        *)
            echo "ERROR: Unsupported architecture ${normalized_arch} for fedora-with-test-tooling"
            exit 1
            ;;
        esac
        SOURCE_IMAGE="quay.io/kubevirtci/fedora-with-test-tooling@${DIGEST}"
        ;;
    alpine-with-test-tooling-container-disk)
        local normalized_arch=$(format_archname ${BUILD_ARCH} tag)
        case ${normalized_arch} in
        amd64) DIGEST=$(workspace_digest alpine_with_test_tooling) ;;
        arm64) DIGEST=$(workspace_digest alpine_with_test_tooling_arm64) ;;
        s390x) DIGEST=$(workspace_digest alpine_with_test_tooling_s390x) ;;
        *)
            echo "ERROR: Unsupported architecture ${normalized_arch} for alpine-with-test-tooling"
            exit 1
            ;;
        esac
        SOURCE_IMAGE="quay.io/kubevirtci/alpine-with-test-tooling-container-disk@${DIGEST}"
        ;;
    fedora-realtime-container-disk)
        SOURCE_IMAGE="quay.io/kubevirt/fedora-realtime-container-disk@$(workspace_digest fedora_realtime)"
        ;;
    alpine-ext-kernel-boot-demo)
        SOURCE_IMAGE="quay.io/kubevirt/alpine-ext-kernel-boot-demo@$(workspace_digest alpine-ext-kernel-boot-demo-container-base)"
        ;;
    s390x-guestless-kernel)
        SOURCE_IMAGE="quay.io/kubevirt/s390x-guestless-kernel@$(workspace_digest s390x-guestless-kernel)"
        ;;
    virt-template-apiserver)
        local normalized_arch=$(format_archname ${BUILD_ARCH} tag)
        case ${normalized_arch} in
        amd64) DIGEST=$(virt_template_digest VIRT_TEMPLATE_APISERVER_DIGEST_AMD64) ;;
        arm64) DIGEST=$(virt_template_digest VIRT_TEMPLATE_APISERVER_DIGEST_ARM64) ;;
        s390x) DIGEST=$(virt_template_digest VIRT_TEMPLATE_APISERVER_DIGEST_S390X) ;;
        *)
            echo "ERROR: Unsupported architecture ${normalized_arch} for virt-template-apiserver"
            exit 1
            ;;
        esac
        SOURCE_IMAGE="quay.io/kubevirt/virt-template-apiserver@${DIGEST}"
        ;;
    virt-template-controller)
        local normalized_arch=$(format_archname ${BUILD_ARCH} tag)
        case ${normalized_arch} in
        amd64) DIGEST=$(virt_template_digest VIRT_TEMPLATE_CONTROLLER_DIGEST_AMD64) ;;
        arm64) DIGEST=$(virt_template_digest VIRT_TEMPLATE_CONTROLLER_DIGEST_ARM64) ;;
        s390x) DIGEST=$(virt_template_digest VIRT_TEMPLATE_CONTROLLER_DIGEST_S390X) ;;
        *)
            echo "ERROR: Unsupported architecture ${normalized_arch} for virt-template-controller"
            exit 1
            ;;
        esac
        SOURCE_IMAGE="quay.io/kubevirt/virt-template-controller@${DIGEST}"
        ;;
    *)
        echo "ERROR: Unknown retagged image: $image_name" >&2
        return 1
        ;;
    esac

    local target_tag="${docker_prefix}/${IMAGE_PREFIX}${image_name}:${docker_tag}"
    echo "${image_name}"
    echo "Source: ${SOURCE_IMAGE}"
    ${KUBEVIRT_CRI} pull ${SOURCE_IMAGE}
    ${KUBEVIRT_CRI} tag ${SOURCE_IMAGE} ${target_tag}
}

setup_buildah_context

# The images ship the version in /.version, like Bazel's get-version rule
trap 'rm -f .version' EXIT
echo "${KUBEVIRT_GIT_VERSION}" >.version

echo "Building KubeVirt Images with ${KUBEVIRT_CRI}"
echo "Architecture: ${BUILD_ARCH}"
echo "Version: ${KUBEVIRT_VERSION}"
echo "Tag: ${docker_tag}"
echo "Prefix: ${docker_prefix}"
echo "Targets: ${BUILD_TARGETS[@]}"

CONTAINER_DISK_IMAGES=""
REGULAR_BUILD_IMAGES=""
NEEDS_SIDECAR_SHIM=false

for image in ${BUILD_TARGETS[@]}; do
    if is_retagged_image "${image}"; then
        :
    elif is_container_disk_image "${image}"; then
        CONTAINER_DISK_IMAGES+=" ${image}"
    else
        REGULAR_BUILD_IMAGES+=" ${image}"
        if [[ "${image}" == "example-hook-sidecar" || "${image}" == "example-cloudinit-hook-sidecar" || "${image}" == "example-disk-mutation-hook-sidecar" ]]; then
            NEEDS_SIDECAR_SHIM=true
        fi
    fi
done

if [[ "${NEEDS_SIDECAR_SHIM}" == "true" ]]; then
    if [[ ! " ${BUILD_TARGETS[@]} " =~ " sidecar-shim " ]]; then
        containerfile=$(get_containerfile_path "sidecar-shim")
        if [ -f "${containerfile}" ]; then
            echo "Pre-building sidecar-shim as dependency..."
            build_image "sidecar-shim" "${containerfile}" "." "--build-arg SIDECAR_SHIM_BASE_IMAGE=${SIDECAR_SHIM_BASE_IMAGE}"
        else
            echo "ERROR: sidecar-shim Containerfile not found but required"
            exit 1
        fi
    fi
fi

for image in ${BUILD_TARGETS[@]}; do
    if is_retagged_image "${image}"; then
        retag_single_image "${image}"
    fi
done

for image in ${REGULAR_BUILD_IMAGES}; do
    containerfile=$(get_containerfile_path "${image}")
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to get Containerfile path for ${image}"
        exit 1
    fi
    if [ ! -f "${containerfile}" ]; then
        echo "ERROR: Containerfile not found for ${image}: ${containerfile}"
        echo "       This image needs to be implemented."
        exit 1
    fi

    extra_args=""
    if [[ "${image}" == "disks-images-provider" || "${image}" == "winrmcli" || "${image}" == "vm-killer" ]]; then
        extra_args="--build-arg TESTING_BASE_IMAGE=${TESTIMAGE_BASE_IMAGE}"
    elif [[ "${image}" == "example-hook-sidecar" || "${image}" == "example-cloudinit-hook-sidecar" || "${image}" == "example-disk-mutation-hook-sidecar" ]]; then
        extra_args="--build-arg SIDECAR_SHIM_IMAGE=${docker_prefix}/${IMAGE_PREFIX}sidecar-shim:${docker_tag}"
    elif [[ "${image}" == "virt-launcher" ]]; then
        extra_args="--build-arg LAUNCHERBASE_IMAGE=${LAUNCHERBASE_IMAGE}"
        extra_args+=" --build-arg LIBVIRT_DEVEL_IMAGE=${LIBVIRT_DEVEL_IMAGE}"
    elif [[ "${image}" == "virt-handler" ]]; then
        extra_args="--build-arg HANDLERBASE_IMAGE=${HANDLERBASE_IMAGE}"
        extra_args+=" --build-arg LIBVIRT_DEVEL_IMAGE=${LIBVIRT_DEVEL_IMAGE}"
    elif [[ "${image}" == "virt-exportserver" ]]; then
        extra_args="--build-arg EXPORTSERVERBASE_IMAGE=${EXPORTSERVERBASE_IMAGE}"
    elif [[ "${image}" == "libguestfs-tools" ]]; then
        extra_args="--build-arg LIBGUESTFS_BASE_IMAGE=${LIBGUESTFS_BASE_IMAGE}"
    elif [[ "${image}" == "pr-helper" ]]; then
        extra_args="--build-arg PR_HELPER_BASE_IMAGE=${PR_HELPER_BASE_IMAGE}"
    elif [[ "${image}" == "sidecar-shim" ]]; then
        extra_args="--build-arg SIDECAR_SHIM_BASE_IMAGE=${SIDECAR_SHIM_BASE_IMAGE}"
    elif [[ "${image}" == "network-passt-binding-cni" ]]; then
        extra_args="--build-arg BUSYBOX_IMAGE=${BUSYBOX_IMAGE}"
    fi

    build_image "${image}" "${containerfile}" "." "${extra_args}"
done

if [[ -n "${CONTAINER_DISK_IMAGES}" ]]; then
    echo "Building container disk images via build-container-disks.sh"
    BUILD_ARCH=${PLATFORM_ARCH} \
        DOCKER_TAG=${docker_tag} \
        DOCKER_PREFIX=${docker_prefix} \
        IMAGE_PREFIX=${IMAGE_PREFIX} \
        KUBEVIRT_CRI=${KUBEVIRT_CRI} \
        ./hack/build-container-disks.sh
fi

echo "==============================================="
echo "Build completed successfully!"
echo "==============================================="
