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
# Downloads the standalone bazeldnf binary for the current platform and
# caches it in _out/tools/bazeldnf-<os>-<arch>/. Later runs reuse the cached
# binary when its checksum matches.
#
# Usage:
#   source hack/install-bazeldnf.sh   # puts bazeldnf on PATH
#   bazeldnf --help

set -e

# Must match the bazeldnf http_archive in WORKSPACE (checked below).
BAZELDNF_VERSION="v0.5.9-2"
BAZELDNF_REPO="brianmcarey/bazeldnf"

function bazeldnf::sha256_for_platform() {
    case "$1" in
    linux-amd64) echo "e78b730e5f9d1edeb7b54e7414e8c094820056eb838f58a235763b63df3f5c41" ;;
    linux-arm64) echo "46d98eefc3bb09b5559140b8c65a128742d6ec0bddc3d4f8851b8eee5de9b660" ;;
    linux-s390x) echo "6ab0e13093d6dfbf5234cd935c24615de4658b17afc787542e62f8eaf5e3ccc7" ;;
    darwin-amd64) echo "215402eabbdde708982724e189b77d53bec5cd0d1ff767b310268b0bc6375269" ;;
    darwin-arm64) echo "ace3d1135dbb29283eb04c224514276e7627e05b577606b6fc0b8a9e610bf4d6" ;;
    *)
        echo "ERROR: no bazeldnf binary available for platform $1" >&2
        return 1
        ;;
    esac
}

function bazeldnf::detect_platform() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    s390x) arch="s390x" ;;
    *)
        echo "ERROR: unsupported architecture $(uname -m)" >&2
        return 1
        ;;
    esac
    echo "${os}-${arch}"
}

function bazeldnf::checksum() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Fail early if WORKSPACE (still used by the Bazel build) pins a different
# bazeldnf version, so the two cannot drift apart silently.
function bazeldnf::check_workspace_version() {
    local workspace="$1/WORKSPACE"
    local ws_version
    [ -f "${workspace}" ] || return 0
    ws_version=$(sed -n 's/.*strip_prefix = "bazeldnf-\(v[^"]*\)".*/\1/p' "${workspace}" | head -1)
    if [ -n "${ws_version}" ] && [ "${ws_version}" != "${BAZELDNF_VERSION}" ]; then
        echo "ERROR: hack/install-bazeldnf.sh uses bazeldnf ${BAZELDNF_VERSION}, but WORKSPACE uses ${ws_version}." >&2
        echo "       Update both to the same version." >&2
        return 1
    fi
}

function bazeldnf::install() {
    local repo_root platform expected_sha tools_dir binary actual_sha
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    bazeldnf::check_workspace_version "${repo_root}"

    platform="$(bazeldnf::detect_platform)"
    expected_sha="$(bazeldnf::sha256_for_platform "${platform}")"

    # One directory per platform: _out is synced between the host and the
    # builder container, which may run on a different OS.
    tools_dir="${repo_root}/_out/tools/bazeldnf-${platform}"
    binary="${tools_dir}/bazeldnf"

    if [ -x "${binary}" ] && [ "$(bazeldnf::checksum "${binary}")" = "${expected_sha}" ]; then
        export PATH="${tools_dir}:${PATH}"
        return 0
    fi

    local url="https://github.com/${BAZELDNF_REPO}/releases/download/${BAZELDNF_VERSION}/bazeldnf-${BAZELDNF_VERSION}-${platform}"
    echo "Downloading bazeldnf ${BAZELDNF_VERSION} for ${platform}..."
    mkdir -p "${tools_dir}"
    # curl has no timeout by default, and --retry does not fire on a stalled transfer
    curl -sSfL --retry 3 --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o "${binary}.tmp" "${url}"

    actual_sha="$(bazeldnf::checksum "${binary}.tmp")"
    if [ "${actual_sha}" != "${expected_sha}" ]; then
        echo "ERROR: bazeldnf checksum verification failed" >&2
        echo "  expected: ${expected_sha}" >&2
        echo "  actual:   ${actual_sha}" >&2
        rm -f "${binary}.tmp"
        return 1
    fi

    chmod +x "${binary}.tmp"
    mv "${binary}.tmp" "${binary}"
    echo "bazeldnf ${BAZELDNF_VERSION} installed to ${binary}"
    export PATH="${tools_dir}:${PATH}"
}

bazeldnf::install
