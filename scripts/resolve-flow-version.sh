#!/usr/bin/env bash
# Resolve the Flow version that ships in a given Vaadin platform release.
#
# Usage:
#   resolve-flow-version.sh <vaadin-version>
#
# Prints the Flow version to stdout (e.g. "25.2.4" for Vaadin "25.2.3").
#
# The Vaadin platform version and the Flow version are NOT aligned at the
# patch level (e.g. platform 25.2.3 ships Flow 25.2.4). The authoritative
# mapping lives in the `com.vaadin:vaadin-gradle-plugin:<vaadin-version>`
# POM, which declares a `<flow.version>` property and depends on
# `com.vaadin:flow-gradle-plugin:<flow-version>`. We fetch that POM and
# read the property.
#
# Only Vaadin 25+ is supported. Final/beta/rc releases live on Maven
# Central; alpha and SNAPSHOT builds live in the Vaadin pre-releases repo,
# so both are probed in that order.
#
# Env:
#   CENTRAL_URL      Override the Maven Central base URL.
#   PRERELEASE_URL   Override the Vaadin pre-releases base URL.

set -euo pipefail

CENTRAL_URL="${CENTRAL_URL:-https://repo1.maven.org/maven2}"
PRERELEASE_URL="${PRERELEASE_URL:-https://maven.vaadin.com/vaadin-prereleases}"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <vaadin-version>" >&2
  exit 2
fi

vaadin_version=$1

if [[ -z "$vaadin_version" ]]; then
  echo "resolve-flow-version: empty Vaadin version" >&2
  exit 2
fi

major="${vaadin_version%%.*}"
if [[ ! "$major" =~ ^[0-9]+$ ]] || (( major < 25 )); then
  echo "resolve-flow-version: only Vaadin 25+ is supported (got '${vaadin_version}')" >&2
  exit 2
fi

artifact_dir="com/vaadin/vaadin-gradle-plugin/${vaadin_version}"

# Fetch the vaadin-gradle-plugin POM from one repository base.
# Release (final/beta/rc/alpha) POMs sit at the plain path. SNAPSHOT POMs
# are stored under a timestamped filename, so resolve that filename from
# the version-level maven-metadata.xml first.
fetch_pom() {
  local base=$1
  if [[ "$vaadin_version" == *-SNAPSHOT ]]; then
    local meta timestamp build_number pom_value base_version
    meta=$(curl -fsSL "${base}/${artifact_dir}/maven-metadata.xml" 2>/dev/null) || return 1
    # Build the timestamped SNAPSHOT filename from <snapshot>'s
    # <timestamp> and <buildNumber>, e.g. 25.3-SNAPSHOT ->
    # 25.3-20260714.083811-64.
    timestamp=$(printf '%s\n' "$meta" | grep -oE '<timestamp>[^<]+</timestamp>' | head -1 | sed -E 's:</?timestamp>::g' | tr -d '[:space:]')
    build_number=$(printf '%s\n' "$meta" | grep -oE '<buildNumber>[^<]+</buildNumber>' | head -1 | sed -E 's:</?buildNumber>::g' | tr -d '[:space:]')
    [[ -z "$timestamp" || -z "$build_number" ]] && return 1
    base_version="${vaadin_version%-SNAPSHOT}"
    pom_value="${base_version}-${timestamp}-${build_number}"
    curl -fsSL "${base}/${artifact_dir}/vaadin-gradle-plugin-${pom_value}.pom" 2>/dev/null
  else
    curl -fsSL "${base}/${artifact_dir}/vaadin-gradle-plugin-${vaadin_version}.pom" 2>/dev/null
  fi
}

# SNAPSHOTs only exist in the pre-releases repo; releases are probed on
# Central first, then pre-releases (for alpha builds).
if [[ "$vaadin_version" == *-SNAPSHOT ]]; then
  bases=("$PRERELEASE_URL")
else
  bases=("$CENTRAL_URL" "$PRERELEASE_URL")
fi

pom=""
for base in "${bases[@]}"; do
  if pom=$(fetch_pom "$base"); then
    [[ -n "$pom" ]] && break
  fi
  pom=""
done

if [[ -z "$pom" ]]; then
  echo "resolve-flow-version: could not fetch vaadin-gradle-plugin POM for Vaadin '${vaadin_version}' from Central or pre-releases" >&2
  exit 1
fi

# Extract <flow.version>...</flow.version>. Kept to a single line by the
# platform build, but tolerate surrounding whitespace.
flow_version=$(printf '%s\n' "$pom" \
  | grep -oE '<flow\.version>[^<]+</flow\.version>' \
  | head -1 \
  | sed -E 's:</?flow\.version>::g' \
  | tr -d '[:space:]')

if [[ -z "$flow_version" ]]; then
  echo "resolve-flow-version: no <flow.version> in vaadin-gradle-plugin POM for Vaadin '${vaadin_version}'" >&2
  exit 1
fi

printf '%s\n' "$flow_version"
