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
# Generates the tars that the base image Containerfiles in this directory
# copy, using standalone bazeldnf instead of `bazel build //rpm:<rpmtree>`.
# It needs bazeldnf, so it runs inside the builder: build-base-images.sh
# calls it through hack/dockerized.
#
# Usage:
#   hack/rpm-base-images/generate-rpm-tars.sh <output_tar> [<output_tar> ...]
#
# Each tar is named after its content: <rpmtree_name>.tar for the root
# filesystem of an rpmtree() rule in rpm/BUILD.bazel, and
# appliance_layer_<arch>.tar for the libguestfs appliance layer.

set -eo pipefail

SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
REPO_ROOT="$(realpath "${SCRIPT_DIR}/../..")"
cd "${REPO_ROOT}"

source "${REPO_ROOT}/hack/rpmtree-utils.sh"

# Write the root filesystem tar of an rpmtree() rule.
#   generate_rpm_tar <rpmtree_name> <output_tar>
generate_rpm_tar() {
    local rpmtree_name="$1"
    local output_tar="$2"

    echo "==> Generating ${output_tar}"
    rpmtree::rpm2tar "${rpmtree_name}" "${output_tar}"
}

# Write the libguestfs appliance layer, like //cmd/libguestfs:appliance_layer_<arch>:
# the appliance files and an empty "done" file in /usr/local/lib/guestfs/appliance,
# which tests/virtctl/guestfs.go checks for.
#   generate_appliance_tar <x86_64|s390x> <output_tar>
generate_appliance_tar() {
    local arch="$1"
    local output_tar="$2"
    local archive tmpdir dest file

    echo "==> Generating ${output_tar}"
    archive=$(rpmtree::fetch "libguestfs-appliance-${arch}")

    tmpdir=$(mktemp -d)
    # The builder has no xz binary, so decompress with Python's lzma module.
    python3 -c 'import lzma, shutil, sys; shutil.copyfileobj(lzma.open(sys.argv[1]), sys.stdout.buffer)' "${archive}" |
        tar -xf - -C "${tmpdir}"

    dest="${tmpdir}/layer/usr/local/lib/guestfs/appliance"
    mkdir -p "${dest}"
    for file in README.fixed initrd kernel root; do
        cp "${tmpdir}/appliance/${file}" "${dest}/${file}"
    done
    touch "${dest}/done"
    chmod 0444 "${dest}"/*
    chmod 0755 "${tmpdir}/layer"

    mkdir -p "$(dirname "${output_tar}")"
    tar -cf "${output_tar}" -C "${tmpdir}/layer" .
    rm -rf "${tmpdir}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <output_tar> [<output_tar> ...]" >&2
        exit 1
    fi
    for output_tar in "$@"; do
        name=$(basename "${output_tar}" .tar)
        case ${name} in
        appliance_layer_*) generate_appliance_tar "${name#appliance_layer_}" "${output_tar}" ;;
        *) generate_rpm_tar "${name}" "${output_tar}" ;;
        esac
    done
fi
