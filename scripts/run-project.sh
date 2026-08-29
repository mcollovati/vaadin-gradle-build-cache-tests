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
#   --cc=off|on|both     Which configuration-cache passes cold mode runs over
#                        the scenario set. Default "both": the same scenarios
#                        run once with --no-configuration-cache and once with
#                        --configuration-cache, and each pass re-wipes the
#                        build cache so both start cold. The CC pass adds
#                        entry-fate assertions (stored / reused / no problems)
#                        and two CC-only scenarios, CC-FRESH and S. "off" is the
#                        historical behaviour; "on" is the quick way to
#                        iterate on a configuration-cache bug. In warm mode
#                        anything but "off" adds a single CC build.
#   --cache=cold         Wipe the local Gradle build cache
#                        ($GRADLE_USER_HOME/caches/build-cache-1 — defaults
#                        to ~/.gradle/caches/build-cache-1) before running,
#                        then run scenarios A–I plus R, per --cc pass. Use
#                        this to guarantee a cold start when validating
#                        cache-population behaviour.
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
#                           on the 2nd)
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
# The configuration cache is a *mode*, not a separate feature: it changes WHEN
# a task's inputs are computed, and so what ends up in its build-cache key.
# vaadin/flow#25387 is precisely that — a build-cache key bug invisible with
# the configuration cache off. So the CC pass (--cc) re-runs the same scenarios
# with --configuration-cache and adds one assertion about the entry's fate:
#
#   A) STORED x2   `clean build ...` and `build ...` request different task
#                  sets, and the task set is part of an entry's identity
#   I) REUSED      the #25387 guard: nothing changed, so nothing may invalidate
#   B–G) REUSED    the uniform invariant — no ordinary source, resource or
#                  frontend edit may invalidate the entry (each of these also
#                  wipes build/ first, so this doubles as "deleting outputs
#                  must not invalidate it either")
#   R) STORED x2   the relocated copy excludes ./.gradle, so it has no entry
#   S) STORED      CC pass only: a file-based `files(...)` dependency (a
#                  contentless marker jar) must not make :vaadinBuildFrontend
#                  unserializable. The minimal reproducer of the
#                  classFinderClasspath defect — H trips the same one, but
#                  with a jar that also carries a frontend module, so a red H
#                  is ambiguous where a red S is not. First of the CC-only
#                  scenarios: one build, and the defect breaks the build.
#   CC-FRESH)      CC pass only: no src/main/frontend (as on a real checkout),
#                  store then reuse. Catches the plugin probing a directory
#                  that the build itself creates.
#   H) STORED      --init-script and a new -P property change the build logic,
#                  so a fresh entry is correct here. Runs LAST in the CC pass
#                  (in its normal place with CC off) because a plugin carrying
#                  the classFinderClasspath serialization defect fails the
#                  *build* here, which would otherwise abort the pass before R
#                  and CC-FRESH report. See run_scenario_h.
#
# A configuration-time input therefore reads as a red CC pass against a green
# CC-off pass, and Gradle names the offending path in the log.
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

# Which configuration-cache passes cold mode runs over the scenario set:
# off (today's behaviour), on (every build under --configuration-cache), or
# both. See the pass loop at the bottom of this file.
CC_MODE=both

# The pass currently executing ("off" or "on"). Set by the pass loop and by
# warm mode; declared here so cc_on() is safe under `set -u` wherever it lands.
CC_PASS=off

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

# Validate and assign a --cc value (off, on or both).
set_cc_mode() {
  case "$1" in
    off|on|both)
      CC_MODE=$1
      ;;
    *)
      echo "run-project: --cc value must be 'off', 'on' or 'both' (got '$1')" >&2
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
    --cc=*)
      set_cc_mode "${1#--cc=}"
      shift
      ;;
    --cc)
      if [[ $# -lt 2 ]]; then
        echo "run-project: --cc requires a value (off|on|both)" >&2
        exit 2
      fi
      set_cc_mode "$2"
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

# Wipe the shared local build cache. Cold mode calls this once per pass (see
# the pass loop at the bottom): scenario A asserts SUCCESS against a cold
# cache, so a second pass over the same scenarios has to start cold too.
wipe_build_cache() {
  local cache_dir="${GRADLE_USER_HOME:-$HOME/.gradle}/caches/build-cache-1"
  if [[ -d "$cache_dir" ]]; then
    echo "Clearing local Gradle build cache at ${cache_dir}"
    rm -rf "$cache_dir"
  else
    echo "Local Gradle build cache not present at ${cache_dir}; nothing to clear"
  fi
}

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
# Whether this project's plugin stack can build under Gradle's configuration
# cache at all. 0 skips the CC pass entirely: a CC-hostile plugin produces
# failures about *itself*, not about the Flow plugin, and Gradle 9 "gracefully
# degrades" (prints "Configuration cache disabled ..." and succeeds with no
# entry), which would leave every CC assertion measuring nothing. Probe before
# flipping it — see the recipe in README's "Configuration cache" section.
CC_COMPATIBLE=1                    # run the configuration-cache pass
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
    # UP-TO-DATE even on the broken plugin). That is the CC pass's job now —
    # every project runs it, so this branch needs no special casing. See
    # scenario I, where the invalidating file is the sibling module's jar.
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

# Configuration-cache flags, spliced AFTER GRADLE_ARGS so they always win.
#
# Default OFF and *explicitly* so: the CC-off pass is only meaningful with the
# configuration cache actually off, and it must stay immune to an ambient
# org.gradle.configuration-cache=true in the user's ~/.gradle/gradle.properties
# (this repo ships no gradle.properties of its own to shadow one). Gradle 9.3
# still defaults to off, but the suite must not depend on that.
CC_FLAG=(--no-configuration-cache)

# Flags for the CC pass. --configuration-cache-problems=fail is already Gradle
# 9.3's default; stated explicitly because org.gradle.configuration-cache.
# problems=warn in a user's gradle.properties would let a problem-ridden entry
# be stored and quietly weaken every CC assertion.
CC_FLAG_ON=(--configuration-cache --configuration-cache-problems=fail)

run_gradle() {
  local log=$1; shift
  # Disable set -e around the pipeline so we can return gradle's exit
  # code (PIPESTATUS[0]) rather than having the pipe trigger an exit
  # before `return` runs. The caller's set -e still applies.
  set +e
  "$GRADLE_BIN" "$@" "${GRADLE_ARGS[@]}" "${CC_FLAG[@]}" 2>&1 | tee "$log"
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

# Configuration-cache assertions. scripts/assert-cc.sh carries the Gradle 9.3
# message reference these parse, plus the three traps that make a naive grep
# useless: "Reusing configuration cache." is printed optimistically *before*
# execution, "entry updated for ..." is a third state, and a gracefully
# degraded build succeeds with no entry at all.
#
# The entry's fate is a sharper diagnostic than the task outcome alone, because
# Gradle names the input that invalidated it — "... cannot be reused because
# file 'lib/build/libs/lib.jar' has changed" points straight at
# vaadin/flow#25387.
#
# They are deliberately no-ops outside the CC pass. That is what lets the
# scenario set stay single-sourced: each scenario states its configuration-cache
# expectation once, inline and unconditionally, and the CC-off pass simply skips
# it instead of the file carrying two copies of every scenario body.
cc_on() { [[ "$CC_PASS" == "on" ]]; }

assert_cc_stored()      { cc_on || return 0; bash "${script_dir}/assert-cc.sh" "$1" STORED; }
assert_cc_reused()      { cc_on || return 0; bash "${script_dir}/assert-cc.sh" "$1" REUSED; }
assert_cc_no_problems() { cc_on || return 0; bash "${script_dir}/assert-cc.sh" "$1" NO_PROBLEMS; }

# Unused by the scenarios below: it exists for the inverse investigation —
# pinning a *known* invalidation while an upstream fix is pending, so that a
# red scenario becomes a machine-checked bug report instead of a note in a log.
assert_cc_not_reused() {
  local log=$1 reason=${2:-}
  cc_on || return 0
  if [[ -n "$reason" ]]; then
    bash "${script_dir}/assert-cc.sh" "$log" NOT_REUSED "$reason"
  else
    bash "${script_dir}/assert-cc.sh" "$log" NOT_REUSED
  fi
}

# Delete every stored configuration-cache entry for this build.
#
# Gradle keeps them in the *build root's* .gradle/configuration-cache — for
# multimodule-jar that is multimodule-jar/.gradle/configuration-cache, not
# web/.gradle. Entries for different requested task sets coexist there, so "the
# previous build stored one" is not a reset; removing the directory is.
#
# Called only where a scenario's premise is a freshly stored entry (A, I and
# CC-FRESH). Everything else deliberately inherits the previous scenario's
# entry, because inheriting is what makes "an ordinary edit must not invalidate
# it" testable at all. Before this existed, scenario I's *first* build reused
# whatever scenario A had left behind, which made its "two identical builds"
# really the run's third and fourth.
cc_reset() {
  rm -rf .gradle/configuration-cache
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

# Build the contentless marker jar used by scenario S, and set $MARKER_JAR.
#
# Unlike the demo-addon fixture this jar carries no classes and no frontend
# resources at all — one text file — because scenario S tests the *shape* of a
# dependency (`files(...)`), not anything the jar contains. Built with the
# JDK's `jar` rather than as a Gradle fixture project: there is nothing to
# compile, and a whole Gradle build per project would cost more than the
# scenario it feeds. Idempotent, and trivially so: the contents never change,
# so an existing jar is always current.
MARKER_JAR=""   # set by build_marker_jar; read by scenario S

build_marker_jar() {
  MARKER_JAR="${repo_root}/fixtures/build/marker-lib.jar"
  if [[ -f "$MARKER_JAR" ]]; then
    return 0
  fi
  local jar_bin=jar
  if ! command -v jar >/dev/null 2>&1; then
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/jar" ]]; then
      jar_bin="${JAVA_HOME}/bin/jar"
    else
      echo "run-project: scenario S needs the JDK's 'jar' tool (not on PATH, and \$JAVA_HOME/bin/jar is missing)" >&2
      return 1
    fi
  fi
  local stage="${repo_root}/fixtures/build/marker-lib"
  rm -rf "$stage"
  mkdir -p "$stage" "$(dirname "$MARKER_JAR")"
  printf 'Scenario S file-dependency marker. Contents deliberately irrelevant.\n' \
    > "${stage}/marker.txt"
  "$jar_bin" cf "$MARKER_JAR" -C "$stage" .
  rm -rf "$stage"
  echo "Built scenario-S marker jar: ${MARKER_JAR}"
}

#---------------------------------------------------------------------
# Warm-cache mode: skip the cold scenarios, run only the FROM-CACHE assertion.
# Mirrors what happens when a fresh CI runner restores a build-cache
# from Actions cache storage and is then asked to build.
#---------------------------------------------------------------------
if [[ "$CACHE_MODE" == "warm" ]]; then
  CC_PASS=off
  section "${project}: warm-cache assertion"
  run_gradle warm.log clean "$BUILD_TASK" "${AUX_TASKS[@]}"
  assert_outcome warm.log "$VBF_TASK" FROM-CACHE
  assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
  assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"

  # Same restored build cache, now with the configuration cache on. This is the
  # one combination cold mode cannot reproduce: a *fresh runner* that has a
  # populated build cache but no configuration-cache entry (entries live in the
  # project's .gradle/ and are never persisted across CI jobs), so it must store
  # a clean entry and still restore the task from the build cache.
  #
  # Asserts STORED, never REUSED: the requested task set is part of an entry's
  # identity, and this invocation's `clean` makes it a set no other scenario
  # uses, so it legitimately gets an entry of its own.
  if [[ "$CC_MODE" != "off" && "$CC_COMPATIBLE" -eq 1 ]]; then
    CC_PASS=on
    section "${project}: warm-cache assertion (configuration cache)"
    cc_reset
    CC_FLAG=("${CC_FLAG_ON[@]}")
    run_gradle warm-cc.log clean "$BUILD_TASK" "${AUX_TASKS[@]}"
    CC_FLAG=(--no-configuration-cache)
    assert_cc_stored warm-cc.log
    assert_cc_no_problems warm-cc.log
    assert_outcome warm-cc.log "$VBF_TASK" FROM-CACHE
    assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  fi

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

# The whole cold scenario set, run once per configuration-cache pass (see the
# pass loop at the end of this file). $CC_PASS is "off" or "on"; the scenarios
# read it only through cc_on / the assert_cc_* helpers, which no-op when it is
# off — so there is exactly one copy of every scenario body, and the CC pass
# adds assertions to it rather than duplicating it.
#
# The body below is deliberately NOT indented into this function: several
# scenarios write fixture files with unquoted-terminator here-documents, whose
# closing EOF must stay at column 0.
run_cold_scenarios() {
CC_PASS=$1

# Start from a clean generated frontend state so a cold run is
# deterministic regardless of what a previous local run left behind — CI
# always runs on a fresh checkout, but locally the (gitignored) packaged
# bundle persists. Flow *reuses* an existing src/main/bundles/prod.bundle
# when it deems the frontend compatible, so a stale bundle from a prior
# scenario/run would poison scenario A's baseline (e.g. a leftover bundle
# already containing scenario F's module makes F's change a no-op). These
# dirs are all generated and gitignored; scenario A rebuilds them.
#
# src/main/frontend goes too, not just its generated/ subdirectory. The whole
# tree is gitignored, so a fresh checkout does not have it — and a leftover
# src/main/frontend/index.html is a *declared output* of vaadinBuildFrontend
# (outputProperties....frontendIndexHtml). If it is on disk without matching
# task history, Gradle marks the task non-cacheable for that build:
#
#   Non-cacheable because Gradle does not know how file
#   'src/main/frontend/index.html' was created ... [OVERLAPPING_OUTPUTS]
#
# which stores nothing, so scenario A-2's FROM-CACHE assertion then fails for
# a reason that has nothing to do with the plugin. (Observed locally after a
# run aborted mid-build; scenario R already excludes this same path from its
# relocated copy for exactly this reason.) Wiping it makes every local pass
# start in the state CI is always in.
echo "Clearing generated frontend state (frontend/, bundles/, dev-bundle/)"
rm -rf "${MODULE_DIR}src/main/frontend" "${MODULE_DIR}src/main/bundles" "${MODULE_DIR}src/main/dev-bundle"

section "${project}: Scenario A (cold-cache restore)"
# Both builds STORE rather than reuse, and correctly so: the requested task set
# is part of an entry's identity, so `clean build ...` and `build ...` are two
# different entries. cc_reset makes the first a genuine store even when a
# previous run or pass left entries behind.
cc_reset
run_gradle scenario-a-1.log clean "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-a-1.log "$VBF_TASK" SUCCESS
assert_cc_stored scenario-a-1.log
assert_cc_no_problems scenario-a-1.log
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
# The pristine build defines the baseline every other scenario compares
# its produced bundle against.
capture_baseline_signature "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"

rm -rf "${BUILD_DIRS[@]}"
run_gradle scenario-a-2.log "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-a-2.log "$VBF_TASK" FROM-CACHE
assert_cc_stored scenario-a-2.log
assert_cc_no_problems scenario-a-2.log
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
# The bug only surfaces under the configuration cache — measured against Vaadin
# 25.2.6, without it the repeat build is UP-TO-DATE even on the broken plugin —
# which is why this scenario is the centrepiece of the CC pass and only a cheap
# sanity check in the CC-off pass. In the CC pass Gradle names the invalidating
# input itself ("cannot be reused because file 'lib/build/libs/lib.jar' has
# changed"), pointing straight at the cause.
#
# cc_reset before the first build is load-bearing, not hygiene: if build 1
# reused the entry scenario A left behind, the dependency-jar fingerprint would
# never be recomputed — the task graph would simply be deserialized — and the
# bug would be masked rather than exposed.
cc_reset
run_gradle scenario-i-1.log "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_cc_stored scenario-i-1.log
assert_cc_no_problems scenario-i-1.log
run_gradle scenario-i-2.log "$BUILD_TASK" "${AUX_TASKS[@]}"
assert_outcome scenario-i-2.log "$VBF_TASK" UP-TO-DATE
assert_cc_reused scenario-i-2.log
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
assert_cc_reused scenario-b.log
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
assert_cc_reused scenario-c.log
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
assert_cc_reused scenario-d.log
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
assert_cc_reused scenario-e.log
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
assert_cc_reused scenario-f.log
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
assert_cc_reused scenario-g.log
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_differs "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_bundle_file_contains "$ARCHIVE_GLOB" "$INDEX_INNER" "$g_marker"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
scenario_end

# Scenario H lives in a function because the two passes run it at different
# points: in its natural place for the CC-off pass, but LAST in the CC pass.
#
# The reason is that on a plugin carrying the configuration-cache
# serialization defect below, H does not merely fail an assertion — the Gradle
# build itself fails, which under `set -e` ends the pass and would take
# scenario R and CC-FRESH down with it. A known-red scenario must not mask the
# ones after it, so in the CC pass it runs once everything else has reported.
#
# Scenario S is the minimal reproducer of that same defect (a contentless jar
# as a `files(...)` dependency) and runs earlier in the CC pass, so on a broken
# plugin the pass reports there — on the scenario whose only variable is the
# dependency's shape — rather than here, where the jar also carries a frontend
# module and a red result has two possible readings.
#
# The defect: with a file-based (`files(...)`) dependency on the classpath,
# GradlePluginAdapter.classFinderClasspath becomes a *filtered* FileCollection
# whose filter is a Java lambda, and Gradle cannot serialize that into the
# entry — "Configuration cache state could not be cached: ... field
# `classFinderClasspath` of `com.vaadin.flow.gradle.GradlePluginAdapter` ...",
# then "Configuration cache entry discarded due to serialization error".
# Reproduced on published Vaadin 25.2.6 and on Flow 25.3-SNAPSHOT, in both
# single- and multi-module projects, and whether the dependency is declared in
# build.gradle or injected by an init script. The same dependency added as a
# Maven coordinate stores cleanly, so it is the file-based form that triggers
# it, not the declaration style or the act of adding a dependency.
run_scenario_h() {
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
# STORED, not reused: the init script and the extra -P property change the
# build logic, so a fresh entry is the correct outcome here.
assert_cc_stored scenario-h.log
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_signature_differs "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_bundle_file_contains "$ARCHIVE_GLOB" "$STATS_INNER" "demo-addon-marker"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
scenario_end
}

# CC-off pass: H in its natural position, before R.
if ! cc_on; then
  run_scenario_h
fi

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
  # The copy excludes ./.gradle, so this tree has no configuration-cache entry
  # of its own and must store a fresh one.
  run_gradle "${project_dir}/scenario-r.log" clean "$BUILD_TASK"
  assert_outcome "${project_dir}/scenario-r.log" "$VBF_TASK" FROM-CACHE
  assert_cc_stored "${project_dir}/scenario-r.log"
  assert_cc_no_problems "${project_dir}/scenario-r.log"
  assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"

  # Scenario I's invariant, seen from the cache *consumer* side: the first
  # build here restored outputs from the shared cache, so an immediate
  # identical build must be UP-TO-DATE.
  #
  # It STORES rather than reuses, and that is correct: the requested task set is
  # part of a configuration-cache entry's identity, and this build asks for
  # "$BUILD_TASK" where the one above asked for "clean $BUILD_TASK" (verified —
  # Gradle reports "no cached configuration is available for tasks: build ..."
  # even with an entry for "clean build ..." on disk). So scenario R guards that
  # a relocated tree stores a clean entry; the reuse invariant is scenario I's
  # and B–G's job.
  run_gradle "${project_dir}/scenario-r2.log" "$BUILD_TASK"
  assert_outcome "${project_dir}/scenario-r2.log" "$VBF_TASK" UP-TO-DATE
  assert_cc_stored "${project_dir}/scenario-r2.log"
  assert_cc_no_problems "${project_dir}/scenario-r2.log"
  assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
)

# Scenarios S and CC-FRESH run in the CC pass only: with the configuration
# cache off there is no entry to store or reuse, so neither would assert
# anything (CC-FRESH would be a slower scenario A, S a slower scenario H).
#
# S goes first, deliberately. Under `set -e` any red scenario aborts the pass
# and hides the ones behind it, so the order here is by cost and severity: S is
# a single build guarding a defect that breaks the *build* outright for anyone
# with a local jar on their classpath, where CC-FRESH spends two builds (one a
# full frontend regeneration) on a wasted reconfiguration. The
# cheap, severe one reports first.
if cc_on; then
  scenario_begin "${project}: Scenario S (file-based dependency: entry must still store)"
  # A `files(...)` dependency must not make :vaadinBuildFrontend
  # unserializable.
  #
  # The defect it guards (see run_scenario_h for the full bean chain): a
  # file-based dependency turns GradlePluginAdapter.classFinderClasspath into
  # a filtered FileCollection whose filter is a Java lambda, which Gradle
  # cannot write into the entry — "Configuration cache state could not be
  # cached: ... field `classFinderClasspath` of `GradlePluginAdapter` ...",
  # then "Configuration cache entry discarded due to serialization error".
  # The build FAILS; it does not degrade.
  #
  # Why this exists next to H, which trips the same defect: H's jar carries a
  # @Route view with a @JsModule, and H's job is "a dependency's frontend is a
  # cache input". It catches the serialization defect only as a side effect,
  # so a red H is two hypotheses. S's jar contains one text file — no classes,
  # no frontend — so a red S has exactly one reading, and the rest of the pass
  # (which declares no file dependencies) is the control.
  build_marker_jar
  # The store step is the failure point, so the premise is "no reusable entry":
  # Gradle skips storing when it can reuse, and then the failure never happens.
  # The init script and the extra -P property would force a fresh entry anyway;
  # cc_reset makes that unconditional rather than incidental.
  cc_reset
  # The exit code is deliberately tolerated so the verdict comes from
  # assert_cc_stored instead of from `set -e`: the helper prints "expected
  # configuration cache entry STORED, got: Configuration cache entry discarded
  # due to serialization error" followed by the log's configuration-cache
  # lines, which name `classFinderClasspath` outright. Aborting on the bare
  # exit code would report only "gradle exited 1".
  run_gradle scenario-s.log "$BUILD_TASK" \
    --init-script "${script_dir}/file-dep-init.gradle" -PfileDepJar="$MARKER_JAR" || true
  assert_cc_stored scenario-s.log
  assert_cc_no_problems scenario-s.log
  # Nothing else is asserted, and that is the point. Whether the added
  # classpath entry moves the build-cache key is H's question; the jar carries
  # nothing that could change the bundle; and on a broken plugin the build dies
  # at configuration time, so there is no archive to inspect anyway.
  scenario_end

  scenario_begin "${project}: Scenario CC-FRESH (fresh checkout: store then reuse)"
  # The state a CI runner is always in and a local run almost never is:
  # .gitignore ignores **/src/main/frontend/ entirely (nothing under it is
  # tracked), so on a fresh checkout that directory does not exist and the first
  # build creates it. If the Flow plugin probes it while the task graph is being
  # configured, Gradle records a file-system-check input on a path that did not
  # exist, and the very next build invalidates with
  #   Calculating task graph as configuration cache cannot be reused because
  #   the file system entry '<module>/src/main/frontend' has been created.
  #
  # scenario_begin has already wiped the build dirs and the packaged bundles;
  # add the generated frontend surface and every stored entry so build 1 sees
  # exactly what CI sees. Everything removed here is generated and gitignored,
  # so there is nothing to register a cleanup for — build 1 regenerates it.
  cc_reset
  rm -rf "${MODULE_DIR}src/main/frontend"

  # Build 1 regenerates the frontend surface from scratch, so its bundle may
  # legitimately differ from scenario A's baseline (Flow regenerates the app
  # shell). Compare build 2 against build 1 instead, then restore the pass-wide
  # baseline for anything that runs after this scenario.
  #
  # No outcome assertion on build 1: the build cache is already warm from the
  # earlier scenarios, so both SUCCESS and FROM-CACHE are correct here. Scenario
  # I sets the same precedent.
  ccfresh_saved_baseline=$BASELINE_SIG
  run_gradle scenario-cc-fresh-1.log "$BUILD_TASK" "${AUX_TASKS[@]}"
  assert_cc_stored scenario-cc-fresh-1.log
  assert_cc_no_problems scenario-cc-fresh-1.log
  assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  capture_baseline_signature "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"

  run_gradle scenario-cc-fresh-2.log "$BUILD_TASK" "${AUX_TASKS[@]}"
  assert_cc_reused scenario-cc-fresh-2.log
  assert_outcome scenario-cc-fresh-2.log "$VBF_TASK" UP-TO-DATE
  assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  assert_signature_same "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  BASELINE_SIG=$ccfresh_saved_baseline
  scenario_end

  # CC pass: scenario H runs last, so that its known configuration-cache
  # serialization failure (see run_scenario_h) cannot abort the pass before R
  # and CC-FRESH have reported. Everything above has already run at this point.
  run_scenario_h
fi
}

#---------------------------------------------------------------------
# Pass loop. The configuration cache is a *mode*, not a separate feature: it
# changes WHEN a task's inputs are computed, and therefore what ends up in its
# build-cache key. vaadin/flow#25387 is exactly that — a build-cache key bug
# invisible with the configuration cache off — so the same scenarios are run
# under both settings and the contrast is the diagnosis. A configuration-time
# input shows up as a red CC pass against a green CC-off pass, and Gradle names
# the offending path in the log.
#
# Each pass re-wipes the shared build cache: scenario A asserts SUCCESS against
# a cold cache, so a second pass over the same scenarios has to start cold too.
#---------------------------------------------------------------------
case "$CC_MODE" in
  off)  cc_passes=(off) ;;
  on)   cc_passes=(on) ;;
  both) cc_passes=(off on) ;;
esac

for cc_pass in "${cc_passes[@]}"; do
  if [[ "$cc_pass" == "on" && "$CC_COMPATIBLE" -ne 1 ]]; then
    section "${project}: configuration-cache pass skipped (CC_COMPATIBLE=0)"
    continue
  fi
  if [[ ${#cc_passes[@]} -gt 1 ]]; then
    section "${project}: ===== configuration cache: ${cc_pass} ====="
  fi
  if [[ "$cc_pass" == "on" ]]; then
    CC_FLAG=("${CC_FLAG_ON[@]}")
  else
    CC_FLAG=(--no-configuration-cache)
  fi
  wipe_build_cache
  cc_reset
  run_cold_scenarios "$cc_pass"
done

success_banner "${project}: all scenarios passed"
