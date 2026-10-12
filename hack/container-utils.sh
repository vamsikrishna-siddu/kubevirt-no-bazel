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
# Utility functions for podman/docker builds

# Create buildah unshare context for rootless builds if needed (Podman only)
setup_buildah_context() {
    if [[ "${KUBEVIRT_CRI}" == "podman" ]]; then
        if ! podman system info | grep -q "rootless: false"; then
            echo "Running in rootless mode"
            export BUILDAH_ISOLATION=chroot
        fi
    fi
}

# Print the extra push flags needed for a tag. Pushes to the local cluster
# registry skip TLS verification; podman needs a flag for that, docker relies
# on its daemon config.
get_push_flags() {
    local tag=$1
    if [[ "${tag}" == localhost:* || "${tag}" == registry:* ]] && [[ "${KUBEVIRT_CRI}" == "podman" ]]; then
        echo "--tls-verify=false"
    fi
}
