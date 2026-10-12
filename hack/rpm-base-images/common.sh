#!/usr/bin/env bash
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
# Shared by build-base-images.sh and push-base-images.sh

# Like the builder images, a new tag for every build: date and commit
if [ -z "${BASE_IMAGE_TAG}" ]; then
    source "${REPO_ROOT}/hack/builder/version.sh"
    BASE_IMAGE_TAG=${VERSION}
fi

get_base_images_for_arch() {
    local arch=$1
    local arch_tag=$(format_archname ${arch} tag)
    local images=(
        "launcherbase"
        "libvirt-devel"
        "handlerbase"
        "exportserverbase"
        "sidecar-shim"
        "testimage"
    )

    # pr-helper not available for s390x
    if [[ "${arch_tag}" != "s390x" ]]; then
        images+=("pr-helper")
    fi

    # libguestfs-tools only for amd64 and s390x (not arm64)
    if [[ "${arch_tag}" != "arm64" ]]; then
        images+=("libguestfs-tools")
    fi

    # Allow override via BASE_IMAGE_TARGETS
    if [[ -n "${BASE_IMAGE_TARGETS:-}" ]]; then
        IFS=',' read -ra images <<<"${BASE_IMAGE_TARGETS}"
    fi

    echo "${images[@]}"
}
