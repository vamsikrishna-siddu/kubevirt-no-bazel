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

# Print the images that the container build builds and pushes for the
# architecture $1, as hack/bazel-push-images.sh does for Bazel. The name is
# normalized first, so e.g. s390x and crossbuild-s390x give the same list.
container_image_targets() {
    local arch
    arch=$(format_archname "$1" tag) || return 1

    local targets="
        virt-operator
        virt-api
        virt-controller
        virt-handler
        virt-launcher
        virt-exportserver
        virt-exportproxy
        virt-synchronization-controller
        alpine-container-disk-demo
        fedora-with-test-tooling-container-disk
        alpine-with-test-tooling-container-disk
        vm-killer
        sidecar-shim
        disks-images-provider
        test-helpers
    "

    # Bazel's arm64 libguestfs-tools image falls back to the x86_64 layers,
    # so it is not built for arm64.
    if [[ "${arch}" != "arm64" ]]; then
        targets+=" libguestfs-tools"
    fi

    if [[ "${arch}" == "s390x" ]]; then
        targets+=" s390x-guestless-kernel"
    fi

    if [[ "${arch}" == "amd64" ]]; then
        targets+="
            fedora-realtime-container-disk
            network-passt-binding-cni
            alpine-ext-kernel-boot-demo
        "
    fi

    if [[ "${arch}" != "s390x" ]]; then
        targets+="
            conformance
            pr-helper
            example-hook-sidecar
            example-disk-mutation-hook-sidecar
            example-cloudinit-hook-sidecar
            example-node-hook-plugin
            test-launcher-hook-sidecar
            cirros-container-disk-demo
            cirros-custom-container-disk-demo
            virtio-container-disk
            winrmcli
            network-passt-binding
            test-network-vhostuser-dra-binding
        "
    fi

    echo ${targets}
}
