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
# Copyright 2017 Red Hat, Inc.
#

# This script is called by cluster-sync.sh
# Container build flow — builds, pushes, and tags all images.

set -e

DOCKER_TAG=${DOCKER_TAG:-devel}
DOCKER_TAG_ALT=${DOCKER_TAG_ALT:-devel_alt}

source hack/common.sh
source kubevirtci/cluster-up/cluster/$KUBEVIRT_PROVIDER/provider.sh
source hack/config.sh
source hack/container-utils.sh

echo "Building ..."

export KUBEVIRT_CRI=${KUBEVIRT_CRI:-$(determine_cri_bin)}

# Prefer DOCKER_PREFIX env var, then fall back to docker_prefix,
# finally to quay.io/kubevirt as a safe default.
if [ -z "${DOCKER_PREFIX}" ]; then
    if [ -n "${docker_prefix}" ]; then
        DOCKER_PREFIX="${docker_prefix}"
        echo "Using registry from provider config: ${DOCKER_PREFIX}"
    else
        DOCKER_PREFIX="quay.io/kubevirt"
        echo "Using default registry: ${DOCKER_PREFIX}"
    fi
else
    echo "Using DOCKER_PREFIX from environment: ${DOCKER_PREFIX}"
fi

echo "==============================================="
echo "Using Container Build (${KUBEVIRT_CRI})"
echo "==============================================="

export BUILD_ARCH=${BUILD_ARCH}
export DOCKER_PREFIX
export DOCKER_TAG
export IMAGE_PREFIX
export BUILDER_IMAGE

# If RPM-related files changed, rebuild base images and push to cluster registry
if [ -n "${RPM_CHANGES:-}" ]; then
    echo ""
    echo "==============================================="
    echo "RPM changes detected - rebuilding base images"
    echo "==============================================="

    local_arch=$(uname -m)
    case ${local_arch} in
    x86_64) rpm_build_arch="amd64" ;;
    aarch64) rpm_build_arch="arm64" ;;
    s390x) rpm_build_arch="s390x" ;;
    *) rpm_build_arch="amd64" ;;
    esac

    BASE_IMAGE_PREFIX=${DOCKER_PREFIX}
    BASE_IMAGE_TAG=${DOCKER_TAG}

    echo "Building base images for ${rpm_build_arch} (detected from $(uname -m))"

    DOCKER_PREFIX=${BASE_IMAGE_PREFIX} \
        BASE_IMAGE_TAG=${BASE_IMAGE_TAG} \
        BUILD_ARCH=${rpm_build_arch} \
        KUBEVIRT_CRI=${KUBEVIRT_CRI} \
        ${KUBEVIRT_PATH}hack/rpm-base-images/build-base-images.sh

    DOCKER_PREFIX=${BASE_IMAGE_PREFIX} \
        BASE_IMAGE_TAG=${BASE_IMAGE_TAG} \
        BUILD_ARCH=${rpm_build_arch} \
        KUBEVIRT_CRI=${KUBEVIRT_CRI} \
        ${KUBEVIRT_PATH}hack/rpm-base-images/push-base-images.sh

    export BASE_IMAGE_PREFIX
    export BASE_IMAGE_TAG

    echo "Base images rebuilt and pushed to ${BASE_IMAGE_PREFIX}"
    echo "==============================================="
fi

echo ""
echo "Building functional test binaries"
${KUBEVIRT_PATH}hack/dockerized "KUBEVIRT_GO_BUILD_TAGS=${KUBEVIRT_GO_BUILD_TAGS} ./hack/go-build-functests.sh"

echo "Building container images"
${KUBEVIRT_PATH}hack/multi-arch-container.sh

echo ""
echo "Pushing images to cluster registry"
${KUBEVIRT_PATH}hack/push-images-container.sh

# Build and push cross-arch container disk images for cross-architecture emulation testing
if [ "${KUBEVIRT_CROSS_ARCH_EMULATION:-}" ]; then
    cross_arch_targets="fedora-with-test-tooling-container-disk alpine-with-test-tooling-container-disk"
    host_arch=$(uname -m)
    cross_arch=""
    case ${host_arch} in
    x86_64) cross_arch="arm64" ;;
    aarch64) cross_arch="amd64" ;;
    esac
    if [ -n "${cross_arch}" ]; then
        cross_build_arch=$(format_archname ${cross_arch})
        cross_tag=$(format_archname ${cross_arch} tag)
        cross_docker_tag="${DOCKER_TAG}-${cross_tag}"

        echo ""
        echo "Building cross-arch emulation images (${cross_build_arch}) with tag ${cross_docker_tag}"
        BUILD_ARCH=${cross_build_arch} \
            DOCKER_PREFIX=${DOCKER_PREFIX} \
            DOCKER_TAG=${cross_docker_tag} \
            IMAGE_PREFIX=${IMAGE_PREFIX} \
            PUSH_TARGETS="${cross_arch_targets}" \
            KUBEVIRT_CRI=${KUBEVIRT_CRI} \
            BUILDER_IMAGE=${BUILDER_IMAGE} \
            ${KUBEVIRT_PATH}hack/build-images-container.sh

        echo "Pushing cross-arch emulation images (${cross_build_arch}) with tag ${cross_docker_tag}"
        BUILD_ARCH=${cross_build_arch} \
            DOCKER_PREFIX=${DOCKER_PREFIX} \
            DOCKER_TAG=${cross_docker_tag} \
            IMAGE_PREFIX=${IMAGE_PREFIX} \
            PUSH_TARGETS="${cross_arch_targets}" \
            KUBEVIRT_CRI=${KUBEVIRT_CRI} \
            ${KUBEVIRT_PATH}hack/push-images-container.sh
    fi
fi

if [ -n "${DOCKER_TAG_ALT}" ]; then
    echo ""
    echo "Pushing images with alt tag/prefix"

    alt_targets="virt-operator virt-api virt-controller virt-handler virt-launcher virt-exportserver virt-exportproxy virt-synchronization-controller virt-template-apiserver virt-template-controller"
    base_tag=${DOCKER_TAG}

    echo "Re-tagging images for alt tag ${DOCKER_TAG_ALT}"
    for image in ${alt_targets}; do
        ${KUBEVIRT_CRI} tag \
            ${DOCKER_PREFIX}/${IMAGE_PREFIX}${image}:${DOCKER_TAG} \
            ${DOCKER_PREFIX}/${IMAGE_PREFIX}${image}:${DOCKER_TAG_ALT}
    done

    DOCKER_TAG=${DOCKER_TAG_ALT} \
        IMAGE_PREFIX=${IMAGE_PREFIX} \
        PUSH_TARGETS="${alt_targets}" \
        ${KUBEVIRT_PATH}hack/push-images-container.sh

    if [ -n "${IMAGE_PREFIX_ALT}" ]; then
        echo "Re-tagging images for alt prefix ${IMAGE_PREFIX_ALT}"
        for image in ${alt_targets}; do
            ${KUBEVIRT_CRI} tag \
                ${DOCKER_PREFIX}/${IMAGE_PREFIX}${image}:${base_tag} \
                ${DOCKER_PREFIX}/${IMAGE_PREFIX_ALT}${image}:${base_tag}
        done

        DOCKER_TAG=${base_tag} \
            IMAGE_PREFIX=${IMAGE_PREFIX_ALT} \
            PUSH_TARGETS="${alt_targets}" \
            ${KUBEVIRT_PATH}hack/push-images-container.sh
    fi
fi

echo ""
echo "Creating multi-arch manifests"
hack/push-container-manifest.sh

# Push virt-template images
source hack/virt-template/default.sh
echo ""
echo "Pushing virt-template images with tag ${virt_template_version}"
for target in virt-template-apiserver virt-template-controller; do
    src=${DOCKER_PREFIX}/${IMAGE_PREFIX}${target}:${DOCKER_TAG}
    dst=${DOCKER_PREFIX}/${IMAGE_PREFIX}${target}:${virt_template_version}
    ${KUBEVIRT_CRI} tag ${src} ${dst}
    ${KUBEVIRT_CRI} push $(get_push_flags ${dst}) ${dst}
done

if [ -n "${IMAGE_PREFIX_ALT}" ]; then
    echo "Pushing virt-template images with alt prefix ${IMAGE_PREFIX_ALT}"
    for target in virt-template-apiserver virt-template-controller; do
        src=${DOCKER_PREFIX}/${IMAGE_PREFIX}${target}:${virt_template_version}
        dst=${DOCKER_PREFIX}/${IMAGE_PREFIX_ALT}${target}:${virt_template_version}
        ${KUBEVIRT_CRI} tag ${src} ${dst}
        ${KUBEVIRT_CRI} push $(get_push_flags ${dst}) ${dst}
    done
fi

echo "Done $0"
