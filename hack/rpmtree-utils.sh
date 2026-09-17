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
# Helpers to use the rpmtree() rules in rpm/BUILD.bazel and the pinned
# downloads in WORKSPACE without Bazel. Source this file.
#
# Downloads are verified against the sha256 from WORKSPACE and cached by
# checksum outside the repository (so they don't end up in container build
# contexts). The GCS mirror is tried before the upstream URLs.

RPMTREE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RPMTREE_BUILDFILE=${RPMTREE_BUILDFILE:-${RPMTREE_REPO_ROOT}/rpm/BUILD.bazel}
RPMTREE_WORKSPACE=${RPMTREE_WORKSPACE:-${RPMTREE_REPO_ROOT}/WORKSPACE}
RPMTREE_CACHE_DIR=${RPMTREE_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/kubevirt/rpms}

# Print the lines of the rule called $2 in file $1 (from its name to the
# closing parenthesis).
function rpmtree::_rule() {
    awk -v name="$2" '
        index($0, "name = \"" name "\"") { found = 1 }
        found && /^\)/ { exit }
        found { print }
    ' "$1"
}

# Print the rpm() names an rpmtree() rule depends on, one per line.
function rpmtree::rpms() {
    rpmtree::_rule "${RPMTREE_BUILDFILE}" "$1" |
        awk 'match($0, /"@[^"]+\/\/rpm"/) { print substr($0, RSTART + 2, RLENGTH - 8) }'
}

# Print the symlinks of an rpmtree() rule as "path=target", one per line.
function rpmtree::symlinks() {
    rpmtree::_rule "${RPMTREE_BUILDFILE}" "$1" | awk '
        /^    symlinks = \{/ { inside = 1; next }
        inside && /^    \}/ { exit }
        inside {
            n = split($0, parts, "\"")
            if (n >= 4) print parts[2] "=" parts[4]
        }
    '
}

# Print the file capabilities of an rpmtree() rule as "path=cap1:cap2",
# one path per line.
function rpmtree::capabilities() {
    rpmtree::_rule "${RPMTREE_BUILDFILE}" "$1" | awk '
        function flush() { if (path != "") print path "=" caps; path = ""; caps = "" }
        /^    capabilities = \{/ { inside = 1; next }
        inside && /^    \}/ { flush(); exit }
        inside && /^        "/ {
            flush()
            split($0, parts, "\"")
            path = parts[2]
            next
        }
        inside && /^            "/ {
            split($0, parts, "\"")
            caps = (caps == "" ? parts[2] : caps ":" parts[2])
        }
    '
}

# Print "sha256 <sum>" and "url <url>" lines for a WORKSPACE entry
# (rpm(), http_archive(), http_file()).
function rpmtree::_workspace_entry() {
    rpmtree::_rule "${RPMTREE_WORKSPACE}" "$1" | awk '
        /^    sha256 = / { split($0, parts, "\""); print "sha256 " parts[2] }
        /"https?:\/\// { split($0, parts, "\""); print "url " parts[2] }
    '
}

function rpmtree::_checksum() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Download a WORKSPACE entry into the cache (if not cached yet), verify its
# checksum and print the path of the cached file.
function rpmtree::fetch() {
    local name="$1"
    local entry sha dest url
    entry=$(rpmtree::_workspace_entry "${name}")
    sha=$(echo "${entry}" | awk '$1 == "sha256" { print $2; exit }')
    if [ -z "${sha}" ]; then
        echo "ERROR: no sha256 found for '${name}' in ${RPMTREE_WORKSPACE}" >&2
        return 1
    fi

    dest="${RPMTREE_CACHE_DIR}/${sha}"
    if [ -f "${dest}" ] && [ "$(rpmtree::_checksum "${dest}")" = "${sha}" ]; then
        echo "${dest}"
        return 0
    fi

    mkdir -p "${RPMTREE_CACHE_DIR}"
    # GCS mirror first, then the upstream URLs in the order WORKSPACE lists them.
    for url in $(echo "${entry}" | awk '$1 == "url" && $2 ~ /storage\.googleapis\.com/ { print $2 }') \
        $(echo "${entry}" | awk '$1 == "url" && $2 !~ /storage\.googleapis\.com/ { print $2 }'); do
        # curl has no timeout by default, and --retry does not fire on a stalled transfer
        if ! curl -sSfL --retry 3 --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o "${dest}.tmp" "${url}"; then
            echo "WARNING: download failed: ${url}" >&2
            continue
        fi
        if [ "$(rpmtree::_checksum "${dest}.tmp")" != "${sha}" ]; then
            echo "WARNING: checksum mismatch: ${url}" >&2
            continue
        fi
        mv "${dest}.tmp" "${dest}"
        echo "${dest}"
        return 0
    done

    rm -f "${dest}.tmp"
    echo "ERROR: could not download '${name}' with sha256 ${sha}" >&2
    return 1
}

# Download all RPMs of an rpmtree() rule and print their cached paths,
# one per line.
function rpmtree::fetch_rpms() {
    local rpmtree_name="$1"
    local rpms rpm
    rpms=$(rpmtree::rpms "${rpmtree_name}")
    if [ -z "${rpms}" ]; then
        echo "ERROR: no RPMs found for rpmtree '${rpmtree_name}' in ${RPMTREE_BUILDFILE}" >&2
        return 1
    fi
    for rpm in ${rpms}; do
        rpmtree::fetch "${rpm}" || return 1
    done
}

# Write the root filesystem tar of an rpmtree() rule, including its symlinks
# and capabilities, like Bazel's rpmtree rule does. Needs bazeldnf on PATH.
#   rpmtree::rpm2tar <rpmtree_name> <output_tar>
function rpmtree::rpm2tar() {
    local rpmtree_name="$1"
    local output_tar="$2"
    local paths path line
    local args=()

    paths=$(rpmtree::fetch_rpms "${rpmtree_name}") || return 1
    for path in ${paths}; do
        args+=(--input "${path}")
    done
    while read -r line; do
        [ -n "${line}" ] && args+=(--symlinks "${line}")
    done <<<"$(rpmtree::symlinks "${rpmtree_name}")"
    while read -r line; do
        [ -n "${line}" ] && args+=(--capabilities "${line}")
    done <<<"$(rpmtree::capabilities "${rpmtree_name}")"

    mkdir -p "$(dirname "${output_tar}")"
    bazeldnf rpm2tar "${args[@]}" --output "${output_tar}"
}
