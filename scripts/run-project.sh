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
#   --cache=cold         Wipe the local Gradle build cache
#                        ($GRADLE_USER_HOME/caches/build-cache-1 — defaults
#                        to ~/.gradle/caches/build-cache-1) before running,
#                        then run scenarios A/B/C/D. Use this to guarantee
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
# All five projects exercise the same scenarios in cold mode and the
# same single warm-cache assertion in warm mode:
#   A) Cold-cache restore: build -> rm -rf build/ -> build -> FROM-CACHE
#   B) Add test class:     rm -rf build/ -> add test -> build -> FROM-CACHE
#   C) Edit resource:      rm -rf build/ -> edit messages.properties -> build -> FROM-CACHE
#   D) Modify @Route Java: rm -rf build/ -> edit HelloView -> build -> NOT_FROM_CACHE
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

CACHE_MODE=warm
PLATFORM_MODE=0
FLOW_OVERRIDE=""

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
  echo "usage: $0 [--cache=cold|warm] <project-dir-name> <version>" >&2
  echo "       $0 --vaadin-platform [--flow-version=<v>] [--cache=cold|warm] <project-dir-name> <version>" >&2
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
    BUNDLE_PREFIX="BOOT-INF/classes/"
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

#---------------------------------------------------------------------
# Warm-cache mode: skip A/B/C/D, run only the FROM-CACHE assertion.
# Mirrors what happens when a fresh CI runner restores a build-cache
# from Actions cache storage and is then asked to build.
#---------------------------------------------------------------------
if [[ "$CACHE_MODE" == "warm" ]]; then
  section "${project}: warm-cache assertion"
  run_gradle warm.log clean "$BUILD_TASK" sourcesJar javadocJar
  assert_outcome warm.log ":vaadinBuildFrontend" FROM-CACHE
  assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
  assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
  assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"
  success_banner "${project}: warm-cache assertion passed"
  exit 0
fi

#---------------------------------------------------------------------
# Cold-cache mode: scenarios A, B, C, D — uniform across all projects.
#---------------------------------------------------------------------

section "${project}: Scenario A (cold-cache restore)"
run_gradle scenario-a-1.log clean "$BUILD_TASK" sourcesJar javadocJar
assert_outcome scenario-a-1.log ":vaadinBuildFrontend" SUCCESS
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"

rm -rf build/
run_gradle scenario-a-2.log "$BUILD_TASK" sourcesJar javadocJar
assert_outcome scenario-a-2.log ":vaadinBuildFrontend" FROM-CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"

section "${project}: Scenario B (add test class)"
rm -rf build/
added_test=src/test/java/com/example/AddedTest.java
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
run_gradle scenario-b.log "$BUILD_TASK" sourcesJar javadocJar
assert_outcome scenario-b.log ":vaadinBuildFrontend" FROM-CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"

section "${project}: Scenario C (edit resource)"
# Use messages.properties — a resource file that is NOT declared as an
# input of vaadinBuildFrontend. (application.properties is declared as an
# @InputFile with content sensitivity, so editing it would correctly
# invalidate the cache and is not a useful negative case here.)
rm -rf build/
resource=src/main/resources/messages.properties
cp "$resource" "$resource.bak"
# Register restore before the destructive edit so an aborted run
# still leaves the working tree clean (EXIT trap → flush_cleanups).
register_cleanup "[[ -f '$resource.bak' ]] && mv '$resource.bak' '$resource'"
echo "# scenario C marker $(date -u +%s)" >> "$resource"
run_gradle scenario-c.log "$BUILD_TASK" sourcesJar javadocJar
assert_outcome scenario-c.log ":vaadinBuildFrontend" FROM-CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"

section "${project}: Scenario D (modify @Route Java)"
rm -rf build/
view=src/main/java/com/example/HelloView.java
cp "$view" "$view.bak"
# Register restore before the destructive edit so an aborted run
# still leaves the working tree clean (EXIT trap → flush_cleanups).
register_cleanup "[[ -f '$view.bak' ]] && mv '$view.bak' '$view'"
# Edit the heading literal so bytecode changes.
sed -i 's/Hello, Vaadin!/Hello, Vaadin (edited)!/' "$view"
run_gradle scenario-d.log "$BUILD_TASK" sourcesJar javadocJar
assert_outcome scenario-d.log ":vaadinBuildFrontend" NOT_FROM_CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"
assert_archive_lacks_vaadin_staging "$SOURCES_JAR"
assert_archive_lacks_vaadin_staging "$JAVADOC_JAR"

success_banner "${project}: all scenarios passed"
