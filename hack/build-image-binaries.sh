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
# (BUILD_ARCH, the host's by default) into _out/cmd/. One hack/dockerized run
# compiles all of them, so they share one Go build cache, and the
# Containerfiles only copy the programs.
#
# virt-launcher and virt-handler link against libvirt. Its headers and
# libraries come from the libvirt-devel base image (LIBVIRT_DEVEL_IMAGE) of
# the target architecture, unpacked into .libvirt-devel/<arch>: hack/dockerized
# does not copy _out into the builder.

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

# Runs in the builder. hack/build-go.sh cross-compiles when ARCH is not the
# host's architecture.
compile_programs() {
    local devel=${KUBEVIRT_DIR}/.libvirt-devel/${ARCH}
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
    PKG_CONFIG_PATH=${devel}/usr/lib64/pkgconfig \
        CGO_CFLAGS="-I${devel}/usr/include" \
        CGO_LDFLAGS="-L${devel}/usr/lib64 -Wl,--allow-shlib-undefined" \
        hack/build-go.sh install ${launcher_programs}
    PKG_CONFIG_PATH=${devel}/usr/lib64/pkgconfig \
        CGO_CFLAGS="-I${devel}/usr/include" \
        CGO_LDFLAGS="-L${devel}/usr/lib64" \
        BIN_NAME=none hack/build-go.sh install ${handler_programs}
}

# Unpack the libvirt-devel image for ARCH, unless that image is unpacked already
unpack_libvirt_devel() {
    local dir=${KUBEVIRT_DIR}/.libvirt-devel/${ARCH}
    if [ "$(cat ${dir}/.image 2>/dev/null)" = "${LIBVIRT_DEVEL_IMAGE}" ]; then
        return
    fi

    echo "Unpacking ${LIBVIRT_DEVEL_IMAGE} (${ARCH}) into ${dir}"
    rm -rf ${dir}
    mkdir -p ${dir}/usr
    local container status=0
    container=$(${KUBEVIRT_CRI} create --platform linux/${ARCH} ${LIBVIRT_DEVEL_IMAGE} /bin/true)
    ${KUBEVIRT_CRI} cp ${container}:/usr/include ${dir}/usr/ &&
        ${KUBEVIRT_CRI} cp ${container}:/usr/lib64 ${dir}/usr/ || status=$?
    ${KUBEVIRT_CRI} rm ${container} >/dev/null
    [ ${status} -eq 0 ] || return ${status}
    echo "${LIBVIRT_DEVEL_IMAGE}" >${dir}/.image
}

if [ "$1" = "compile" ]; then
    compile_programs
    exit
fi

if [ -z "${LIBVIRT_DEVEL_IMAGE}" ]; then
    echo "LIBVIRT_DEVEL_IMAGE is not set" >&2
    exit 1
fi

unpack_libvirt_devel

# hack/dockerized picks the cross-compile builder when BUILD_ARCH is not the
# host's architecture
echo "Compiling the image programs for ${ARCH}"
BUILD_ARCH=${ARCH} hack/dockerized "BUILD_ARCH=${ARCH} ./hack/build-image-binaries.sh compile"
