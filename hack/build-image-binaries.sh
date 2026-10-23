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

# Compile the Go programs of the KubeVirt images for one architecture
# (BUILD_ARCH, the host's by default) into _out/cmd/. Runs in the builder
# (hack/dockerized), so all programs share one Go build cache, and the
# Containerfiles only copy them.
#
# virt-launcher and virt-handler compile against the libvirt-devel base image
# (LIBVIRT_DEVEL_IMAGE) of that architecture, which skopeo unpacks here.

set -e

source hack/common.sh

ARCH=$(format_archname "${BUILD_ARCH:-$(uname -m)}" tag) || {
    echo "BUILD_ARCH=${BUILD_ARCH}: build one of amd64, arm64 or s390x at a time" >&2
    exit 1
}

# The programs in groups with the same cgo settings
static_programs="
    cmd/sidecars
    cmd/sidecars/smbios
    cmd/sidecars/cloudinit
    cmd/sidecars/disk-mutation
    cmd/test-helpers/pod-mutator
    cmd/example-node-hook-plugin
    cmd/plugin-sidecars/test-launcher-hook
    cmd/cniplugins/passt-binding/cmd
"
programs="
    cmd/virt-api
    cmd/virt-controller
    cmd/virt-operator
    tools/csv-generator
    cmd/virt-exportproxy
    cmd/virt-exportserver
    cmd/synchronization-controller
    cmd/sidecars/network-passt-binding
    cmd/sidecars/test-network-vhostuser-dra-binding
    tests/conformance
"
launcher_programs="
    cmd/virt-launcher
    cmd/virt-launcher-monitor
    cmd/virt-freezer
    cmd/virt-probe
    cmd/virt-tail
"
handler_programs="
    cmd/virt-handler
    cmd/virt-chroot
"

# Compile all programs for ARCH; hack/build-go.sh cross-compiles when needed
compile_programs() {
    local devel=$1
    export BUILD_ARCH=${ARCH}
    export KUBEVIRT_KEEP_OTHER_BINARIES=true

    # hack/build-go.sh names the programs after the version, so remove the
    # ones of earlier versions
    local program
    for program in ${static_programs} ${programs} ${launcher_programs} ${handler_programs}; do
        rm -f ${CMD_OUT_DIR}/$(basename ${program})/*-linux-${ARCH}
    done

    # BIN_NAME only skips the container-disk build, which the virt-launcher
    # group does.
    CGO_ENABLED=0 BIN_NAME=none hack/build-go.sh install ${static_programs}
    CGO_ENABLED=0 GOOS=linux GOARCH=${ARCH} go_build \
        -o ${CMD_OUT_DIR}/libvirt-hook-client/libvirt-hook-client ./cmd/virt-launcher/libvirt-hook-client
    BIN_NAME=none hack/build-go.sh install ${programs}

    # The libvirt headers and libraries of ARCH, for the two groups below
    export PKG_CONFIG_PATH=${devel}/usr/lib64/pkgconfig
    export CGO_CFLAGS="-I${devel}/usr/include"
    export CGO_LDFLAGS="-L${devel}/usr/lib64"
    CGO_LDFLAGS="${CGO_LDFLAGS} -Wl,--allow-shlib-undefined" \
        hack/build-go.sh install ${launcher_programs}
    BIN_NAME=none hack/build-go.sh install ${handler_programs}
}

# Unpack the libvirt-devel image, unless the same image is unpacked already
unpack_libvirt_devel() {
    local dir=$1
    local inspect_tls="" copy_tls="" digest layer
    # Base images rebuilt in CI are in the cluster registry, which has no TLS
    case ${LIBVIRT_DEVEL_IMAGE} in
    localhost:* | registry:*)
        inspect_tls=--tls-verify=false
        copy_tls=--src-tls-verify=false
        ;;
    esac
    digest=$(skopeo --override-arch ${ARCH} inspect ${inspect_tls} --format '{{.Digest}}' docker://${LIBVIRT_DEVEL_IMAGE})
    if [ "$(cat ${dir}/.digest 2>/dev/null)" = "${digest}" ]; then
        return
    fi

    echo "Unpacking ${LIBVIRT_DEVEL_IMAGE} (${ARCH}) into ${dir}"
    rm -rf "${dir:?}"
    mkdir -p ${dir}/image
    skopeo --override-arch ${ARCH} copy ${copy_tls} docker://${LIBVIRT_DEVEL_IMAGE} dir:${dir}/image
    for layer in $(jq -r '.layers[].digest' ${dir}/image/manifest.json); do
        tar -xf ${dir}/image/${layer#sha256:} -C ${dir}
    done
    rm -rf "${dir:?}/image"
    echo "${digest}" >${dir}/.digest
}

if [ -z "${LIBVIRT_DEVEL_IMAGE}" ]; then
    echo "LIBVIRT_DEVEL_IMAGE is not set" >&2
    exit 1
fi

# Kept in the builder's home, which persists between hack/dockerized runs
devel=${XDG_CACHE_HOME:-${HOME}/.cache}/kubevirt/libvirt-devel/${ARCH}
unpack_libvirt_devel ${devel}

echo "Compiling the image programs for ${ARCH}"
compile_programs ${devel}
