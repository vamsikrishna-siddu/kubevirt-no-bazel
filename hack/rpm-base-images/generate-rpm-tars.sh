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
# Copyright 2026 The KubeVirt Authors.
#
# Generates the tars that the base image Containerfiles in this directory
# copy, using standalone bazeldnf instead of `bazel build //rpm:<rpmtree>`.
# The tars are written to RPM_TARS_DIR, which build-base-images.sh uses as
# the build context.
#
# Usage:
#   hack/rpm-base-images/generate-rpm-tars.sh <rpmtree_name> [<output_tar>]
#   hack/rpm-base-images/generate-rpm-tars.sh launcherbase_x86_64_cs9
#
# Or source it and call generate_rpm_tar / generate_appliance_tar.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RPM_TARS_DIR=${RPM_TARS_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/kubevirt/rpm-tars}

source "${REPO_ROOT}/hack/install-bazeldnf.sh"
source "${REPO_ROOT}/hack/rpmtree-utils.sh"

# Write the root filesystem tar of an rpmtree() rule.
#   generate_rpm_tar <rpmtree_name> [<output_tar>]
generate_rpm_tar() {
    local rpmtree_name="$1"
    local output_tar="${2:-${RPM_TARS_DIR}/${rpmtree_name}.tar}"

    echo "==> Generating ${output_tar}"
    rpmtree::rpm2tar "${rpmtree_name}" "${output_tar}"
}

# Write the libguestfs appliance layer, like //cmd/libguestfs:appliance_layer_<arch>:
# the appliance files and an empty "done" file in /usr/local/lib/guestfs/appliance.
#   generate_appliance_tar <x86_64|s390x> [<output_tar>]
generate_appliance_tar() {
    local arch="$1"
    local output_tar="${2:-${RPM_TARS_DIR}/appliance_layer_${arch}.tar}"
    local archive tmpdir dest file

    echo "==> Generating ${output_tar}"
    archive=$(rpmtree::fetch "libguestfs-appliance-${arch}")

    tmpdir=$(mktemp -d)
    tar -xJf "${archive}" -C "${tmpdir}"

    dest="${tmpdir}/layer/usr/local/lib/guestfs/appliance"
    mkdir -p "${dest}"
    for file in README.fixed initrd kernel root; do
        cp "${tmpdir}/appliance/${file}" "${dest}/${file}"
    done
    touch "${dest}/done"
    chmod 0444 "${dest}"/*
    chmod 0755 "${tmpdir}/layer"

    mkdir -p "$(dirname "${output_tar}")"
    # COPYFILE_DISABLE keeps macOS tar from adding AppleDouble (._*) entries.
    COPYFILE_DISABLE=1 tar -cf "${output_tar}" -C "${tmpdir}/layer" .
    rm -rf "${tmpdir}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        echo "Usage: $0 <rpmtree_name> [<output_tar>]" >&2
        exit 1
    fi
    generate_rpm_tar "$@"
fi
