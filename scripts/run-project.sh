#!/usr/bin/env bash
# Run build-cache scenarios for one of the test projects.
#
# Usage:
#   run-project.sh [--cache=cold|warm] <project-dir-name> <version>
#   run-project.sh --vaadin-platform [--flow-version=<v>] [--cache=cold|warm] <project-dir-name> <version>
#
# The trailing <version> is interpreted per mode:
#   * Source mode (default): <version> is a Flow version. Builds the
#     project under <project-dir-name>/ against a locally-installed Flow,
#     applying the com.vaadin.flow plugin at that version.
#   * Published mode (--vaadin-platform): <version> is a Vaadin *platform*
#     version (25+). Builds the mirrored project under
#     platform/<project-dir-name>/ against published Vaadin artifacts,
#     applying the com.vaadin platform plugin at that version and
#     resolving com.vaadin:flow from Maven Central / the Vaadin
#     pre-releases repo. The Flow version is derived from the platform
#     version (scripts/resolve-flow-version.sh) unless --flow-version
#     overrides it.
#
# Options:
#   --vaadin-platform    Enable published mode: treat <version> as a Vaadin
#                        platform version (see above).
#   --flow-version=<v>   Published mode only: override the derived Flow
#                        version with <v>.
#   --cache-debug        Pass -Dorg.gradle.caching.debug=true to every Gradle
#                        invocation, so each cacheable task logs the
#                        individual inputs hashed into its build-cache key
#                        ("Appending ... to build cache key" lines) and the
#                        final key. Diffing those lines between two builds
#                        pinpoints which input changed — e.g. if scenario R
#                        ever regresses to a cache miss at a new path. Also
#                        enabled via CACHE_DEBUG=1.
#   --cache=cold         Wipe the local Gradle build cache
#                        ($GRADLE_USER_HOME/caches/build-cache-1 — defaults
#                        to ~/.gradle/caches/build-cache-1) before running,
#                        then run scenarios A–I plus R. Use this to guarantee
#                        a cold start when validating cache-population
#                        behaviour.
#   --cache=warm         Default. Do NOT touch the local Gradle build cache.
#                        Run only the warm-cache assertion: clean build
#                        -> :vaadinBuildFrontend must come FROM-CACHE.
#                        Expects the cache to be already populated (e.g.
#                        from a prior cold run or a restored Actions cache).
#   --help, -h           Show this help and exit.
#
# Env:
#   GRADLE_BIN           Override the Gradle binary (default: ./gradlew in
#                        the project, else system 'gradle').
#   GRADLE_USER_HOME     Standard Gradle override. The wiped cache path
#                        is "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/build-cache-1".
#
# All projects exercise the same scenarios in cold mode and the same
# single warm-cache assertion in warm mode. Each scenario also checks
# the produced bundle content (stats.json signature / staged marker),
# so a false cache hit serving a stale bundle is caught, not just a
# wrong task outcome.
#
# Cache-hit guards (bundle unchanged vs the scenario-A baseline):
#   A) Cold-cache restore:  build -> rm -rf build/ -> build   (FROM-CACHE)
#   I) Repeat build:        two identical builds in a row     (UP-TO-DATE
#                           on the 2nd; under --configuration-cache where
#                           the project sets CC_SCENARIO=1)
#   B) Add test class:      non-input source added            (FROM-CACHE)
#   C) Edit resource:       messages.properties, not an input (FROM-CACHE)
#   E) Comment-only Java:   trailing comment, same bytecode   (FROM-CACHE)
#   R) Relocatability:      copy at a different absolute path (FROM-CACHE,
#                           then UP-TO-DATE on its repeat build)
# Cache-miss guards (NOT FROM-CACHE):
#   D) Modify @Route Java:  main-classpath bytecode changes (bundle same)
#   F) Add @JsModule:       project frontend module (bundle changes)
#   G) Edit index.html:     frontend template input (bundle changes)
#   H) Add-on dependency:   jar-carried frontend module (bundle changes)
#
# Every project's archive must contain META-INF/VAADIN/webapp/ after the
# build. A correctly behaving Flow Gradle plugin wires every Vaadin
# application archive task (jar, war, bootJar, shadowJar, custom Jar
# subclasses) to vaadinBuildFrontend; failures here surface plugin
# regressions that drop or narrow that wiring.
#
# Symmetric negative assertion: each project's sourcesJar and javadocJar
# must contain NO META-INF/VAADIN/* entries. A regression that
# over-eagerly wires bundle-staging into auxiliary Jar tasks (so the
# frontend bundle, flow-build-info.json, stats.json, etc. leak into
# sources/javadoc archives) surfaces here.

set -euo pipefail

# Colour output when stdout is a real terminal. NO_COLOR=1 disables;
# FORCE_COLOR=1 enables even when piped (e.g. `... | less -R` or in
# CI).
if [[ -n "${FORCE_COLOR:-}" ]] || { [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; }; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

section() {
  local rule="────────────────────────────────────────────────────────"
  printf '\n%s%s%s\n'   "${C_BOLD}${C_CYAN}" "$rule" "$C_RESET"
  printf '%s  %s%s\n'   "${C_BOLD}${C_CYAN}" "$1" "$C_RESET"
  printf '%s%s%s\n\n'   "${C_BOLD}${C_CYAN}" "$rule" "$C_RESET"
}

success_banner() {
  local rule="════════════════════════════════════════════════════════"
  printf '\n%s%s%s\n'   "${C_BOLD}${C_GREEN}" "$rule" "$C_RESET"
  printf '%s  %s%s\n'   "${C_BOLD}${C_GREEN}" "$1" "$C_RESET"
  printf '%s%s%s\n\n'   "${C_BOLD}${C_GREEN}" "$rule" "$C_RESET"
}

# Print the failing line and command before the shell exits via `set -e`.
# Makes silent exits (e.g. a substitution returning non-zero under
# pipefail) immediately diagnosable.
trap 'rc=$?; printf "%srun-project: exit %s at line %s: %s%s\n" "$C_RED" "$rc" "$LINENO" "$BASH_COMMAND" "$C_RESET" >&2' ERR

# Stack of cleanup actions. Each scenario registers its undo (restore
# a backed-up file, delete a created file) BEFORE the destructive
# step, so an aborted run still leaves a clean working tree.
# Executed in LIFO order on script exit (success, failure, Ctrl-C).
pending_cleanups=()

register_cleanup() {
  pending_cleanups+=("$1")
}

flush_cleanups() {
  local i action
  for ((i=${#pending_cleanups[@]}-1; i>=0; i--)); do
    action="${pending_cleanups[$i]}"
    eval "$action" 2>/dev/null || true
  done
  pending_cleanups=()
}

trap flush_cleanups EXIT

# Cold-mode scenarios are hermetic: scenario_begin records the current
# cleanup-stack depth (and wipes build/), scenario_end runs every cleanup
# registered since — in LIFO order — restoring the working tree
# immediately so one scenario's edit never leaks into the next. The EXIT
# trap still flushes anything left if a run aborts mid-scenario.
scenario_mark=0

scenario_begin() {
  section "$1"
  scenario_mark=${#pending_cleanups[@]}
  rm -rf "${BUILD_DIRS[@]}"
  # Remove Flow's packaged application bundle before every scenario.
  # Flow *reuses* an existing src/main/bundles/prod.bundle when it deems
  # the frontend compatible, so a bundle compiled by an earlier scenario
  # could be served unchanged even after a frontend edit — masking the
  # very change F/G/H assert. A fresh CI checkout never has this file, so
  # removing it makes local runs match CI: any build that actually
  # executes vaadinBuildFrontend compiles a bundle reflecting the current
  # sources. It is NOT a Gradle cache input, so FROM-CACHE scenarios are
  # unaffected (the task is restored from Gradle's cache, not recompiled).
  rm -rf "${MODULE_DIR}src/main/bundles" "${MODULE_DIR}src/main/dev-bundle"
}

scenario_end() {
  local i action
  for ((i=${#pending_cleanups[@]}-1; i>=scenario_mark; i--)); do
    action="${pending_cleanups[$i]}"
    eval "$action" 2>/dev/null || true
  done
  if [[ "$scenario_mark" -eq 0 ]]; then
    pending_cleanups=()
  else
    pending_cleanups=("${pending_cleanups[@]:0:scenario_mark}")
  fi
}

CACHE_MODE=warm
PLATFORM_MODE=0
FLOW_OVERRIDE=""
# When set, add -Dorg.gradle.caching.debug=true so Gradle logs every input
# hashed into each task's build-cache key. Enable with --cache-debug or
# CACHE_DEBUG=1.
CACHE_DEBUG=${CACHE_DEBUG:-0}

# Validate and assign a --cache value (cold or warm).
set_cache_mode() {
  case "$1" in
    cold|warm)
      CACHE_MODE=$1
      ;;
    *)
      echo "run-project: --cache value must be 'cold' or 'warm' (got '$1')" >&2
      exit 2
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache=*)
      set_cache_mode "${1#--cache=}"
      shift
      ;;
    --cache)
      if [[ $# -lt 2 ]]; then
        echo "run-project: --cache requires a value (cold|warm)" >&2
        exit 2
      fi
      set_cache_mode "$2"
      shift 2
      ;;
    --vaadin-platform)
      PLATFORM_MODE=1
      shift
      ;;
    --cache-debug)
      CACHE_DEBUG=1
      shift
      ;;
    --flow-version=*)
      FLOW_OVERRIDE="${1#--flow-version=}"
      shift
      ;;
    --flow-version)
      if [[ $# -lt 2 ]]; then
        echo "run-project: --flow-version requires a value" >&2
        exit 2
      fi
      FLOW_OVERRIDE="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "run-project: unknown option '$1'" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

repo_root=$(cd "$(dirname "$0")/.." && pwd)
script_dir="${repo_root}/scripts"

usage() {
  echo "usage: $0 [--cache=cold|warm] [--cache-debug] <project-dir-name> <version>" >&2
  echo "       $0 --vaadin-platform [--flow-version=<v>] [--cache=cold|warm] [--cache-debug] <project-dir-name> <version>" >&2
}

# Both modes take exactly <project> <version>; --vaadin-platform only
# changes how <version> is interpreted (Vaadin platform vs Flow).
if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi
project=$1
version=$2

if [[ "$PLATFORM_MODE" -eq 1 ]]; then
  # <version> is a Vaadin platform version; the mirrored project lives
  # under platform/. Derive the Flow version unless --flow-version
  # overrides it.
  vaadin_version=$version
  if [[ -n "$FLOW_OVERRIDE" ]]; then
    flow_version=$FLOW_OVERRIDE
    echo "Vaadin ${vaadin_version} with Flow ${flow_version} (override)"
  else
    echo "Resolving Flow version for Vaadin ${vaadin_version}..."
    flow_version=$(bash "${script_dir}/resolve-flow-version.sh" "$vaadin_version")
    echo "Vaadin ${vaadin_version} -> Flow ${flow_version}"
  fi
  project_dir="${repo_root}/platform/${project}"
else
  if [[ -n "$FLOW_OVERRIDE" ]]; then
    echo "run-project: --flow-version is only valid with --vaadin-platform" >&2
    exit 2
  fi
  flow_version=$version
  project_dir="${repo_root}/${project}"
fi

if [[ ! -d "$project_dir" ]]; then
  echo "run-project: unknown project '${project}' (looked in ${project_dir})" >&2
  exit 2
fi

if [[ "$CACHE_MODE" == "cold" ]]; then
  cache_dir="${GRADLE_USER_HOME:-$HOME/.gradle}/caches/build-cache-1"
  if [[ -d "$cache_dir" ]]; then
    echo "Clearing local Gradle build cache at ${cache_dir}"
    rm -rf "$cache_dir"
  else
    echo "Local Gradle build cache not present at ${cache_dir}; nothing to clear"
  fi
fi

cd "$project_dir"

# Per-project parameters.
#
# The defaults describe a single-module project: sources at the project
# root, one build/ directory, the Vaadin task at the root of the build.
# multimodule-jar overrides all four — its Vaadin module is the :web
# subproject — which is why the scenarios below address source paths
# through $MODULE_DIR and the task through $VBF_TASK instead of
# hardcoding them.
MODULE_DIR=""                      # path prefix (trailing /) of the Vaadin module
VBF_TASK=":vaadinBuildFrontend"    # task path the scenarios assert on
BUILD_DIRS=(build)                 # build dirs wiped between scenarios
AUX_TASKS=(sourcesJar javadocJar)  # sources/javadoc tasks built alongside
CC_SCENARIO=0                      # run scenario I under --configuration-cache
case "$project" in
  plain-jar)
    BUILD_TASK="build"
    ARCHIVE_GLOB="build/libs/plain-jar.jar"
    BUNDLE_PREFIX=""
    SOURCES_JAR="build/libs/plain-jar-sources.jar"
    JAVADOC_JAR="build/libs/plain-jar-javadoc.jar"
    ;;
  war)
    BUILD_TASK="build"
    ARCHIVE_GLOB="build/libs/war.war"
    BUNDLE_PREFIX="WEB-INF/classes/"
    SOURCES_JAR="build/libs/war-sources.jar"
    JAVADOC_JAR="build/libs/war-javadoc.jar"
    ;;
  spring-boot-jar)
    BUILD_TASK="bootJar"
    ARCHIVE_GLOB="build/libs/spring-boot-jar.jar"
    # Bundle prefix is "" (archive root), NOT "BOOT-INF/classes/". Since
    # Flow PR #25001 (25.3.0-alpha4) vaadinBuildFrontend writes to a
    # separate build/vaadin-build-frontend dir, and the bootJar packaging
    # stages that output at the archive root (META-INF/VAADIN/...) rather
    # than under BOOT-INF/classes/. See vaadin/flow#25021. Only empty
    # BOOT-INF/classes/META-INF/VAADIN/ dir placeholders remain there.
    BUNDLE_PREFIX=""
    SOURCES_JAR="build/libs/spring-boot-jar-sources.jar"
    JAVADOC_JAR="build/libs/spring-boot-jar-javadoc.jar"
    ;;
  shaded-jar)
    BUILD_TASK="shadowJar"
    ARCHIVE_GLOB="build/libs/shaded-jar-all.jar"
    BUNDLE_PREFIX=""
    SOURCES_JAR="build/libs/shaded-jar-sources.jar"
    JAVADOC_JAR="build/libs/shaded-jar-javadoc.jar"
    ;;
  custom-jar-task)
    BUILD_TASK="customJar"
    ARCHIVE_GLOB="build/libs/custom-jar.jar"
    BUNDLE_PREFIX=""
    SOURCES_JAR="build/libs/custom-jar-task-sources.jar"
    JAVADOC_JAR="build/libs/custom-jar-task-javadoc.jar"
    ;;
  custom-frontend-output)
    # Mirrors plain-jar; the project overrides
    # vaadin.frontendOutputDirectory in build.gradle. The plugin's
    # jar-packaging logic walks parentFile.parentFile from that path
    # to stage the bundle, so the in-archive layout still has
    # META-INF/VAADIN/webapp/ at the root — BUNDLE_PREFIX stays "".
    BUILD_TASK="build"
    ARCHIVE_GLOB="build/libs/custom-frontend-output.jar"
    BUNDLE_PREFIX=""
    SOURCES_JAR="build/libs/custom-frontend-output-sources.jar"
    JAVADOC_JAR="build/libs/custom-frontend-output-javadoc.jar"
    ;;
  multimodule-jar)
    # The only multi-module project: :lib (plain java) + :web (Vaadin,
    # depending on :lib). Everything the scenarios touch lives under web/,
    # and the task under test is :web:vaadinBuildFrontend. Both modules'
    # build dirs are wiped between scenarios so lib.jar is as absent at the
    # start of each scenario as it is in a fresh checkout — the state that
    # exposes vaadin/flow#25387 (see scenario I).
    MODULE_DIR="web/"
    VBF_TASK=":web:vaadinBuildFrontend"
    BUILD_DIRS=(build lib/build web/build)
    AUX_TASKS=(:web:sourcesJar :web:javadocJar)
    BUILD_TASK=":web:build"
    ARCHIVE_GLOB="web/build/libs/web.jar"
    BUNDLE_PREFIX=""
    SOURCES_JAR="web/build/libs/web-sources.jar"
    JAVADOC_JAR="web/build/libs/web-javadoc.jar"
    # vaadin/flow#25387 only manifests under Gradle's configuration cache
    # (verified against Vaadin 25.2.6: without it the repeat build is
    # UP-TO-DATE even on the broken plugin), so scenario I runs its two
    # builds with --configuration-cache here. Scoped to this project so the
    # other six are not exposed to unrelated configuration-cache
    # incompatibilities in their plugin stacks (Shadow, Spring Boot).
    CC_SCENARIO=1
    ;;
  *)
    echo "run-project: unknown project '${project}'" >&2
    exit 2
    ;;
esac

GRADLE_ARGS=(
  "--build-cache"
  "--console=plain"
  "--no-daemon"
  "-Pvaadin.productionMode"
  "-PflowVersion=${flow_version}"
)
# Published mode also drives the com.vaadin platform plugin version.
if [[ "$PLATFORM_MODE" -eq 1 ]]; then
  GRADLE_ARGS+=("-PvaadinVersion=${vaadin_version}")
fi
# Log the individual inputs hashed into each task's build-cache key.
if [[ "$CACHE_DEBUG" -eq 1 ]]; then
  GRADLE_ARGS+=("-Dorg.gradle.caching.debug=true")
fi

# Prefer the project's Gradle wrapper if present so the suite works
# without a system Gradle install. Fall back to system `gradle`.
# Callers can force a specific binary by exporting GRADLE_BIN.
if [[ -z "${GRADLE_BIN:-}" ]]; then
  if [[ -x ./gradlew ]]; then
    GRADLE_BIN=./gradlew
  else
    GRADLE_BIN=gradle
  fi
fi
echo "Using gradle binary: ${GRADLE_BIN}"

run_gradle() {
  local log=$1; shift
  # Disable set -e around the pipeline so we can return gradle's exit
  # code (PIPESTATUS[0]) rather than having the pipe trigger an exit
  # before `return` runs. The caller's set -e still applies.
  set +e
  "$GRADLE_BIN" "$@" "${GRADLE_ARGS[@]}" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "run-project: gradle exited ${rc} (see $(pwd)/${log})" >&2
  fi
  return "$rc"
}

assert_archive_has_bundle() {
  local archive=$1
  local prefix=$2
  local marker="${prefix}META-INF/VAADIN/webapp/"
  if [[ ! -f "$archive" ]]; then
    printf '%sFAIL%s archive not found: %s\n' "$C_RED$C_BOLD" "$C_RESET" "$archive" >&2
    return 1
  fi
  # `|| true` so that a no-match grep (exit 1) under pipefail does not
  # propagate non-zero out of the substitution and silently terminate
  # the script via set -e.
  local hits
  hits=$(unzip -l "$archive" | grep -cF "${marker}" || true)
  if [[ "${hits:-0}" -eq 0 ]]; then
    printf '%sFAIL%s archive %s missing %s\n' "$C_RED$C_BOLD" "$C_RESET" "$archive" "$marker" >&2
    unzip -l "$archive" | grep -F "META-INF/VAADIN" >&2 || true
    return 1
  fi
  printf '%sOK  %s archive %s contains %s (%s entries)\n' "$C_GREEN$C_BOLD" "$C_RESET" "$archive" "$marker" "$hits"
}

# Negative counterpart of assert_archive_has_bundle: sources and javadoc
# jars must be clean of every META-INF/VAADIN/* entry the Flow plugin
# stages (frontend bundle, flow-build-info.json, stats.json, etc.). A
# regression that wires bundle-staging into auxiliary Jar tasks surfaces
# here.
assert_archive_lacks_vaadin_staging() {
  local archive=$1
  local marker="META-INF/VAADIN/"
  if [[ ! -f "$archive" ]]; then
    printf '%sFAIL%s archive not found: %s\n' "$C_RED$C_BOLD" "$C_RESET" "$archive" >&2
    return 1
  fi
  local hits
  hits=$(unzip -l "$archive" | grep -cF "$marker" || true)
  if [[ "${hits:-0}" -gt 0 ]]; then
    printf '%sFAIL%s archive %s must not contain %s (%s entries)\n' \
      "$C_RED$C_BOLD" "$C_RESET" "$archive" "$marker" "$hits" >&2
    unzip -l "$archive" | grep -F "$marker" >&2 || true
    return 1
  fi
  printf '%sOK  %s archive %s clean of %s\n' \
    "$C_GREEN$C_BOLD" "$C_RESET" "$archive" "$marker"
}

assert_outcome() {
  bash "${script_dir}/assert-task-outcome.sh" "$@"
}

# Assert Gradle *reused* its configuration-cache entry instead of storing a
# fresh one. On a repeat build with nothing changed, "Configuration cache
# entry stored." means the previous entry was invalidated — and Gradle names
# the input that did it ("... cannot be reused because file X has changed"),
# which is a sharper diagnostic than the task outcome alone. Used by
# scenario I, where the invalidating file is the sibling module's jar.
assert_cc_reused() {
  local log=$1
  if grep -qF "Configuration cache entry reused." "$log"; then
    printf '%sOK  %s configuration cache entry reused\n' "$C_GREEN$C_BOLD" "$C_RESET"
    return 0
  fi
  printf '%sFAIL%s configuration cache entry was not reused on an unchanged build\n' \
    "$C_RED$C_BOLD" "$C_RESET" >&2
  grep -E "configuration cache cannot be reused|Configuration cache entry" "$log" >&2 || \
    printf '       (no configuration-cache lines in %s)\n' "$log" >&2
  return 1
}

#---------------------------------------------------------------------
# Bundle-content assertions (#2). Outcome checks alone cannot tell a
# correct cache hit from a false hit that served a *stale* bundle, so we
# also fingerprint the produced bundle. We use it two ways:
#   * a signature proves a FROM-CACHE restore served the *same* bundle,
#     or that a real frontend change produced a *different* one;
#   * targeted greps confirm a specific module/marker is present.
#
# The signature is a normalized hash of META-INF/VAADIN/config/stats.json,
# which records the bundle's frontendHashes + packageJsonHash +
# bundleImports + npmModules — the true digest of frontend state. We hash
# stats.json rather than the produced .js chunks because the bundler
# tree-shakes an unused module out of the compiled output (so an added
# @JsModule can leave the chunks byte-identical) while stats.json still
# records the new import. Normalization strips all whitespace and drops
# the "pre-compiled" flag, because Flow writes stats.json pretty-printed
# when it *compiles* the bundle but compact (and flagged pre-compiled)
# when it *reuses* the packaged bundle — formatting that must not by
# itself read as a bundle change. (scenario_begin removes the packaged
# bundle so any build that executes vaadinBuildFrontend compiles fresh
# and stats.json reflects the current sources.)
#---------------------------------------------------------------------
BASELINE_SIG=""

bundle_signature() {
  local archive=$1 prefix=$2 raw
  # Guard unzip: it exits 11 ("no matching files") when stats.json is
  # absent. Under `set -euo pipefail` an unguarded unzip in this
  # command substitution propagates that 11 straight through the
  # caller's `X=$(bundle_signature ...)` assignment — killing the script
  # with a bare exit code, past both the ERR trap and any FAIL branch.
  # `|| raw=""` turns "absent" into an empty signature so callers detect
  # it explicitly (see capture_baseline_signature / assert_signature_*).
  raw=$(unzip -p "$archive" "${prefix}META-INF/VAADIN/config/stats.json" 2>/dev/null) || raw=""
  [[ -z "$raw" ]] && return 0
  printf '%s' "$raw" \
    | tr -d ' \t\n\r' \
    | sed -E 's/,?"pre-compiled":(true|false)//g; s/,\}/}/g' \
    | sha256sum | cut -d' ' -f1
}

capture_baseline_signature() {
  BASELINE_SIG=$(bundle_signature "$1" "$2")
  if [[ -z "$BASELINE_SIG" ]]; then
    printf '%sFAIL%s could not read %sMETA-INF/VAADIN/config/stats.json from %s to capture baseline signature\n' \
      "$C_RED$C_BOLD" "$C_RESET" "$2" "$1" >&2
    printf '       archive VAADIN staging actually present:\n' >&2
    unzip -l "$1" | grep -F "META-INF/VAADIN" >&2 || printf '       (none)\n' >&2
    return 1
  fi
  printf '%sOK  %s baseline bundle signature %s captured\n' \
    "$C_GREEN$C_BOLD" "$C_RESET" "${BASELINE_SIG:0:12}"
}

assert_signature_same() {
  local archive=$1 prefix=$2 sig
  sig=$(bundle_signature "$archive" "$prefix")
  if [[ "$sig" != "$BASELINE_SIG" ]]; then
    printf '%sFAIL%s bundle signature changed (%s != baseline %s): a cache hit served a different bundle\n' \
      "$C_RED$C_BOLD" "$C_RESET" "${sig:0:12}" "${BASELINE_SIG:0:12}" >&2
    return 1
  fi
  printf '%sOK  %s bundle signature matches baseline (%s)\n' \
    "$C_GREEN$C_BOLD" "$C_RESET" "${sig:0:12}"
}

assert_signature_differs() {
  local archive=$1 prefix=$2 sig
  sig=$(bundle_signature "$archive" "$prefix")
  if [[ -z "$sig" ]]; then
    printf '%sFAIL%s could not read stats.json from %s\n' "$C_RED$C_BOLD" "$C_RESET" "$archive" >&2
    return 1
  fi
  if [[ "$sig" == "$BASELINE_SIG" ]]; then
    printf '%sFAIL%s bundle signature unchanged (%s): the frontend change never reached the bundle\n' \
      "$C_RED$C_BOLD" "$C_RESET" "${sig:0:12}" >&2
    return 1
  fi
  printf '%sOK  %s bundle signature differs from baseline (%s vs %s)\n' \
    "$C_GREEN$C_BOLD" "$C_RESET" "${sig:0:12}" "${BASELINE_SIG:0:12}"
}

# Assert a named file inside the archive contains a marker string.
assert_bundle_file_contains() {
  local archive=$1 inner=$2 marker=$3 hits
  hits=$(unzip -p "$archive" "$inner" 2>/dev/null | grep -cF "$marker" || true)
  if [[ "${hits:-0}" -eq 0 ]]; then
    printf '%sFAIL%s %s in %s missing expected marker %s\n' \
      "$C_RED$C_BOLD" "$C_RESET" "$inner" "$archive" "$marker" >&2
    return 1
  fi
  printf '%sOK  %s %s contains %s (%s)\n' \
    "$C_GREEN$C_BOLD" "$C_RESET" "$inner" "$marker" "$hits"
}

# Build the demo-addon fixture jar used by scenario H. Idempotent and
# incremental, so re-running per project is cheap. Uses the same Flow
# version as the project under test so it resolves in both modes.
build_addon_jar() {
  local addon_dir="${repo_root}/fixtures/demo-addon"
  echo "Building add-on fixture jar (${addon_dir})"
  "$GRADLE_BIN" -p "$addon_dir" jar \
    --console=plain --no-daemon "-PflowVersion=${flow_version}" \
    > "${project_dir}/scenario-h-addon.log" 2>&1 || {
      echo "run-project: failed to build add-on fixture (see ${project_dir}/scenario-h-addon.log)" >&2
      return 1
    }
}

#---------------------------------------------------------------------
# Warm-cache mode: skip the cold scenarios, run only the FROM-CACHE assertion.
# Mirrors what happens when a fresh CI runner restores a build-cache
# from Actions cache storage and is then asked to build.
#---------------------------------------------------------------------
if [[ "$CACHE_MODE" == "warm" ]]; then
  section "${project}: warm-cache assertion"
  run_gradle warm.log clean "$BUILD_TASK" "${AUX_TASKS[@]}"
  assert_outcome warm.log "$VBF_TASK" FROM-CACHE
  assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
  assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
  success_banner "${project}: warm-cache assertion passed"
  exit 0
fi

#---------------------------------------------------------------------
# Cold-cache mode: scenarios A–I plus R — uniform across all projects.
#
# Cache-hit guards (bundle unchanged):
#   A  cold restore         build → rm build/ → build          FROM-CACHE
#   I  repeat build         two identical builds in a row       UP-TO-DATE
#   B  add test class       non-input source added             FROM-CACHE
#   C  edit resource        messages.properties (not an input) FROM-CACHE
#   E  comment-only Java    byte-identical bytecode            FROM-CACHE
#   R  relocatability       copy at a different absolute path  FROM-CACHE,
#                           then UP-TO-DATE on its repeat build
# Cache-miss guards (must NOT come FROM-CACHE):
#   D  edit @Route Java     main-classpath bytecode changes (bundle same)
#   F  add @JsModule         project frontend module (bundle changes)
#   G  edit index.html       frontend template input (bundle changes)
#   H  add-on dependency     jar-carried frontend module (bundle changes)
#
# Every scenario also asserts the produced bundle content: hits keep the
# baseline stats.json signature; frontend-changing misses (F/G/H) change
# it (and stage the expected marker), catching a stale-restore false hit.
#---------------------------------------------------------------------

STATS_INNER="${BUNDLE_PREFIX}META-INF/VAADIN/config/stats.json"
INDEX_INNER="${BUNDLE_PREFIX}META-INF/VAADIN/webapp/index.html"
view="${MODULE_DIR}src/main/java/com/example/HelloView.java"

# Start from a clean generated frontend state so a cold run is
# deterministic regardless of what a previous local run left behind — CI
# always runs on a fresh checkout, but locally the (gitignored) packaged
# bundle persists. Flow *reuses* an existing src/main/bundles/prod.bundle
# when it deems the frontend compatible, so a stale bundle from a prior
# scenario/run would poison scenario A's baseline (e.g. a leftover bundle
# already containing scenario F's module makes F's change a no-op). These
# dirs are all generated and gitignored; scenario A rebuilds them.
echo "Clearing generated frontend state (bundles/, dev-bundle/, frontend/generated/)"
rm -rf "${MODULE_DIR}src/main/bundles" "${MODULE_DIR}src/main/dev-bundle" "${MODULE_DIR}src/main/frontend/generated"

section "${project}: Scenario A (cold-cache restore)"
run_gradle scenario-a-1.log clean "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-a-1.log "$VBF_TASK" SUCCESS
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
# The pristine build defines the baseline every other scenario compares
# its produced bundle against.
capture_baseline_signature "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"

rm -rf "${BUILD_DIRS[@]}"
run_gradle scenario-a-2.log "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-a-2.log "$VBF_TASK" FROM-CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"

scenario_begin "${project}: Scenario I (repeat build with no changes)"
# Two identical consecutive builds. scenario_begin has wiped every module's
# build/, so the first build starts from the same state as a fresh
# checkout — in particular a multi-module project's sibling jar does not
# exist yet when :vaadinBuildFrontend's inputs are snapshotted. The second
# build changes nothing, so it must be UP-TO-DATE.
#
# That is the invariant vaadin/flow#25387 breaks: the Flow plugin folds the
# runtime classpath's dependency jars into a scalar @Input via a provider
# that does not carry the file collection's task dependencies, so the value
# is computed before the sibling jar exists and flips once it does. The task
# then re-runs under a second cache key even though nothing changed —
# reported as SUCCESS, or as FROM-CACHE when that second key is already in
# the cache. UP-TO-DATE is the only correct outcome.
#
# The bug only surfaces under the configuration cache (measured against
# Vaadin 25.2.6: without --configuration-cache the repeat build is
# UP-TO-DATE even on the broken plugin), so projects that set
# CC_SCENARIO=1 run both builds with it and additionally assert Gradle
# reused its entry. Gradle names the invalidating input in that case
# ("cannot be reused because file 'lib/build/libs/lib.jar' has changed"),
# which points straight at the cause.
cc_args=()
if [[ "$CC_SCENARIO" -eq 1 ]]; then
  cc_args=(--configuration-cache)
fi
run_gradle scenario-i-1.log "$BUILD_TASK" "${AUX_TASKS[@]}" "${cc_args[@]}"
run_gradle scenario-i-2.log "$BUILD_TASK" "${AUX_TASKS[@]}" "${cc_args[@]}"
assert_outcome scenario-i-2.log "$VBF_TASK" UP-TO-DATE
if [[ "$CC_SCENARIO" -eq 1 ]]; then
  assert_cc_reused scenario-i-2.log
fi
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
scenario_end

scenario_begin "${project}: Scenario B (add test class)"
added_test="${MODULE_DIR}src/test/java/com/example/AddedTest.java"
mkdir -p "$(dirname "$added_test")"
# Register undo before creating the file so an aborted run still
# leaves the working tree clean (EXIT trap → flush_cleanups).
register_cleanup "rm -f '$added_test'"
cat > "$added_test" <<'EOF'
package com.example;

import org.junit.jupiter.api.Test;

public class AddedTest {
    @Test
    public void shouldCompile() {
    }
}
EOF
run_gradle scenario-b.log "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-b.log "$VBF_TASK" FROM-CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
scenario_end

scenario_begin "${project}: Scenario C (edit resource)"
# Use messages.properties — a resource file that is NOT declared as an
# input of vaadinBuildFrontend. (application.properties is declared as an
# @InputFile with content sensitivity, so editing it would correctly
# invalidate the cache and is not a useful negative case here.)
resource="${MODULE_DIR}src/main/resources/messages.properties"
cp "$resource" "$resource.bak"
# Register restore before the destructive edit so an aborted run
# still leaves the working tree clean (EXIT trap → flush_cleanups).
register_cleanup "[[ -f '$resource.bak' ]] && mv '$resource.bak' '$resource'"
echo "# scenario C marker $(date -u +%s)" >> "$resource"
run_gradle scenario-c.log "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-c.log "$VBF_TASK" FROM-CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
scenario_end

scenario_begin "${project}: Scenario D (modify @Route Java)"
cp "$view" "$view.bak"
# Register restore before the destructive edit so an aborted run
# still leaves the working tree clean (EXIT trap → flush_cleanups).
register_cleanup "[[ -f '$view.bak' ]] && mv '$view.bak' '$view'"
# Edit the heading literal so bytecode changes. The heading is rendered
# server-side, so the frontend bundle is byte-identical — hence
# NOT_FROM_CACHE (bytecode is a cache input) but signature unchanged.
sed -i 's/Hello, Vaadin!/Hello, Vaadin (edited)!/' "$view"
run_gradle scenario-d.log "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-d.log "$VBF_TASK" NOT_FROM_CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
scenario_end

scenario_begin "${project}: Scenario E (comment-only Java edit)"
cp "$view" "$view.bak"
register_cleanup "[[ -f '$view.bak' ]] && mv '$view.bak' '$view'"
# Append a comment AFTER the final closing brace: no code line numbers
# shift, so javac emits byte-identical bytecode. A cache key that keys on
# source text or timestamps (rather than normalized compiled output)
# would wrongly miss here; a correct one still hits.
printf '\n// scenario E: comment-only edit — must not invalidate the bundle\n' >> "$view"
run_gradle scenario-e.log "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-e.log "$VBF_TASK" FROM-CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
scenario_end

scenario_begin "${project}: Scenario F (add @JsModule to a view)"
# A project-local frontend module referenced from a scanned @Route view.
# This genuinely changes the bundle, so it must miss the cache and the
# new module must appear in the produced bundle's stats.json.
marker_js="${MODULE_DIR}src/main/frontend/marker-widget.js"
mkdir -p "$(dirname "$marker_js")"
register_cleanup "rm -f '$marker_js'"
cat > "$marker_js" <<'EOF'
// scenario F: project frontend module pulled in by @JsModule
export const markerWidget = 'marker-widget';
EOF
cp "$view" "$view.bak"
register_cleanup "[[ -f '$view.bak' ]] && mv '$view.bak' '$view'"
sed -i 's#^import com.vaadin.flow.router.Route;#import com.vaadin.flow.component.dependency.JsModule;\nimport com.vaadin.flow.router.Route;#' "$view"
sed -i 's#^@Route("")#@JsModule("./marker-widget.js")\n@Route("")#' "$view"
run_gradle scenario-f.log "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-f.log "$VBF_TASK" NOT_FROM_CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_differs "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_bundle_file_contains "$ARCHIVE_GLOB" "$STATS_INNER" "marker-widget"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
scenario_end

scenario_begin "${project}: Scenario G (edit frontend/index.html)"
# index.html is the app-shell template and a declared frontend input.
# Editing it must miss the cache and the edit must reach the built
# webapp/index.html (proving the produced bundle, not a stale one).
# Flow does NOT auto-generate this file (only frontend/generated/), so it
# is a user-owned file that may be absent; seed the canonical template
# when missing. Creating a user app shell where there was none is itself
# a genuine frontend-input change, so the assertion holds either way.
idx="${MODULE_DIR}src/main/frontend/index.html"
mkdir -p "$(dirname "$idx")"
if [[ -f "$idx" ]]; then
  cp "$idx" "$idx.bak"
  register_cleanup "[[ -f '$idx.bak' ]] && mv '$idx.bak' '$idx'"
else
  register_cleanup "rm -f '$idx'"
  cat > "$idx" <<'HTML'
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
</head>
<body>
  <!-- This outlet div is where the views are rendered -->
  <div id="outlet"></div>
</body>
</html>
HTML
fi
g_marker="scenario-g-marker-$(date -u +%s)"
sed -i "s#</head>#  <meta name=\"${g_marker}\" content=\"1\" />\n</head>#" "$idx"
run_gradle scenario-g.log "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-g.log "$VBF_TASK" NOT_FROM_CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_differs "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_bundle_file_contains "$ARCHIVE_GLOB" "$INDEX_INNER" "$g_marker"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
scenario_end

scenario_begin "${project}: Scenario H (add-on dependency with frontend resources)"
# A frontend resource carried by a dependency jar. The add-on ships a
# @Route view (discovered classpath-wide) whose @JsModule stages
# demo-addon-marker.js — with no change to the project's own sources, so
# this isolates "a dependency's frontend is a cache input" from any
# main-classpath bytecode change. Injected via an init script so no
# project build.gradle is edited (keeps the scenario uniform).
build_addon_jar
addon_jar="${repo_root}/fixtures/demo-addon/build/libs/demo-addon.jar"
run_gradle scenario-h.log "$BUILD_TASK" "${AUX_TASKS[@]}" \
  --init-script "${script_dir}/addon-init.gradle" -PdemoAddonJar="$addon_jar"
assert_outcome scenario-h.log "$VBF_TASK" NOT_FROM_CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_differs "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_bundle_file_contains "$ARCHIVE_GLOB" "$STATS_INNER" "demo-addon-marker"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
scenario_end

section "${project}: Scenario R (relocatability — build at a different path)"
# The whole point of a *shared* build cache is reuse across checkouts at
# different absolute paths. Build a copy of the project at a fresh path
# against the SAME cache: a path-independent cache key yields FROM-CACHE;
# a key that leaked an absolute path would miss here.
reloc_dir=$(mktemp -d "${TMPDIR:-/tmp}/reloc-${project}-XXXXXX")
register_cleanup "rm -rf '$reloc_dir'"
# Copy with tar --dereference so the platform mirrors' top-level symlinks
# (src, gradle, gradlew) become real files — a fully independent tree at a
# new absolute path. Exclude node_modules (its .bin holds broken/circular
# symlinks that --dereference would choke on) and the stale build/.gradle
# state, so the relocated build can only avoid re-execution via the
# *shared* build cache.
#
# Also exclude the generated frontend surface (all gitignored: the whole
# src/main/frontend tree, src/main/bundles, src/main/dev-bundle). A fresh
# git checkout — what this scenario emulates — has none of these; the build
# regenerates them. Copying them in instead produces pre-existing output
# files at a checkout with no .gradle history, which Gradle flags as
# OVERLAPPING_OUTPUTS ("does not know how file src/main/frontend/index.html
# was created") and marks :vaadinBuildFrontend non-cacheable — a false
# failure that masks the actual path-dependent-cache-key bug R exists to
# catch. Dropping them lets R isolate that one bug.
# Excludes are derived from the per-project parameters so they land on
# the right module: node_modules and the generated frontend live in the
# Vaadin module ($MODULE_DIR), and a multi-module project has one build
# dir per module ($BUILD_DIRS).
tar_excludes=(--exclude=./.gradle "--exclude=./${MODULE_DIR}node_modules")
for bd in "${BUILD_DIRS[@]}"; do
  tar_excludes+=("--exclude=./${bd}")
done
tar_excludes+=(
  "--exclude=./${MODULE_DIR}src/main/frontend"
  "--exclude=./${MODULE_DIR}src/main/bundles"
  "--exclude=./${MODULE_DIR}src/main/dev-bundle"
)
tar -cf - --dereference "${tar_excludes[@]}" -C . . | tar -xf - -C "$reloc_dir"
chmod +x "$reloc_dir/gradlew" 2>/dev/null || true
(
  cd "$reloc_dir"
  run_gradle "${project_dir}/scenario-r.log" clean "$BUILD_TASK"
  assert_outcome "${project_dir}/scenario-r.log" "$VBF_TASK" FROM-CACHE
  assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"

  # Scenario I's invariant, seen from the cache *consumer* side: the first
  # build here restored outputs from the shared cache, so an immediate
  # identical build must be UP-TO-DATE. Note this runs without
  # --configuration-cache, so it does not reproduce vaadin/flow#25387 (that
  # needs the configuration cache — see scenario I); it is the cheap
  # general guard that a relocated consumer settles after one build.
  run_gradle "${project_dir}/scenario-r2.log" "$BUILD_TASK"
  assert_outcome "${project_dir}/scenario-r2.log" "$VBF_TASK" UP-TO-DATE
  assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
)

success_banner "${project}: all scenarios passed"
