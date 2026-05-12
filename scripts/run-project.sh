#!/usr/bin/env bash
# Run build-cache scenarios for one of the test projects.
#
# Usage:
#   run-project.sh [--clear-cache|-c] <project-dir-name> <flow-version>
#
# Options:
#   --clear-cache, -c    Wipe the local Gradle build cache
#                        ($GRADLE_USER_HOME/caches/build-cache-1 — defaults
#                        to ~/.gradle/caches/build-cache-1) before running.
#                        Use this to guarantee a cold start when validating
#                        FROM-CACHE assertions.
#   --help, -h           Show this help and exit.
#
# Env:
#   GRADLE_BIN           Override the Gradle binary (default: ./gradlew in
#                        the project, else system 'gradle').
#   GRADLE_USER_HOME     Standard Gradle override. The cleared cache path
#                        is "${GRADLE_USER_HOME:-$HOME/.gradle}/caches/build-cache-1".
#
# Positive projects (plain-jar, war, spring-boot-jar) exercise scenarios:
#   A) Cold-cache restore: build -> rm -rf build/ -> build -> FROM-CACHE
#   B) Add test class:     rm -rf build/ -> add test -> build -> FROM-CACHE
#   C) Edit resource:      rm -rf build/ -> edit messages.properties -> build -> FROM-CACHE
#   D) Modify @Route Java: rm -rf build/ -> edit HelloView -> build -> NOT_FROM_CACHE
#
# Negative projects (shaded-jar, custom-jar-task) run only a single build and
# assert that the produced archive does NOT contain META-INF/VAADIN/webapp/.

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

CLEAR_CACHE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clear-cache|-c)
      CLEAR_CACHE=true
      shift
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

if [[ $# -ne 2 ]]; then
  echo "usage: $0 [--clear-cache|-c] <project-dir-name> <flow-version>" >&2
  exit 2
fi

project=$1
flow_version=$2

repo_root=$(cd "$(dirname "$0")/.." && pwd)
script_dir="${repo_root}/scripts"
project_dir="${repo_root}/${project}"

if [[ ! -d "$project_dir" ]]; then
  echo "run-project: unknown project '${project}'" >&2
  exit 2
fi

if [[ "$CLEAR_CACHE" == "true" ]]; then
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
IS_NEGATIVE=false
case "$project" in
  plain-jar)
    BUILD_TASK="build"
    ARCHIVE_GLOB="build/libs/plain-jar.jar"
    BUNDLE_PREFIX=""
    ;;
  war)
    BUILD_TASK="build"
    ARCHIVE_GLOB="build/libs/war.war"
    BUNDLE_PREFIX="WEB-INF/classes/"
    ;;
  spring-boot-jar)
    BUILD_TASK="bootJar"
    ARCHIVE_GLOB="build/libs/spring-boot-jar.jar"
    BUNDLE_PREFIX="BOOT-INF/classes/"
    ;;
  shaded-jar)
    BUILD_TASK="shadowJar"
    ARCHIVE_GLOB="build/libs/shaded-jar-all.jar"
    BUNDLE_PREFIX=""
    IS_NEGATIVE=true
    ;;
  custom-jar-task)
    BUILD_TASK="customJar"
    ARCHIVE_GLOB="build/libs/custom-jar.jar"
    BUNDLE_PREFIX=""
    IS_NEGATIVE=true
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

assert_archive_lacks_bundle() {
  local archive=$1
  if [[ ! -f "$archive" ]]; then
    printf '%sFAIL%s archive not found: %s\n' "$C_RED$C_BOLD" "$C_RESET" "$archive" >&2
    return 1
  fi
  local hits
  hits=$(unzip -l "$archive" | grep -cF "META-INF/VAADIN/webapp/" || true)
  if [[ "${hits:-0}" -ne 0 ]]; then
    printf '%sFAIL%s negative project %s unexpectedly bundled the frontend:\n' "$C_RED$C_BOLD" "$C_RESET" "$project" >&2
    unzip -l "$archive" | grep -F "META-INF/VAADIN/webapp/" >&2
    return 1
  fi
  printf '%sOK  %s archive %s does not contain META-INF/VAADIN/webapp/ (expected for %s)\n' "$C_GREEN$C_BOLD" "$C_RESET" "$archive" "$project"
}

assert_outcome() {
  bash "${script_dir}/assert-task-outcome.sh" "$@"
}

#---------------------------------------------------------------------
# Negative projects: build once, assert bundle absence.
#---------------------------------------------------------------------
if [[ "$IS_NEGATIVE" == "true" ]]; then
  section "${project}: negative single-build run"
  run_gradle build.log clean "$BUILD_TASK"
  assert_archive_lacks_bundle "$ARCHIVE_GLOB"
  success_banner "${project}: negative assertion passed"
  exit 0
fi

#---------------------------------------------------------------------
# Positive projects: scenarios A, B, C, D.
#---------------------------------------------------------------------

section "${project}: Scenario A (cold-cache restore)"
run_gradle scenario-a-1.log clean "$BUILD_TASK"
assert_outcome scenario-a-1.log ":vaadinBuildFrontend" SUCCESS
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"

rm -rf build/
run_gradle scenario-a-2.log "$BUILD_TASK"
assert_outcome scenario-a-2.log ":vaadinBuildFrontend" FROM-CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"

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
run_gradle scenario-b.log "$BUILD_TASK"
assert_outcome scenario-b.log ":vaadinBuildFrontend" FROM-CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"

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
run_gradle scenario-c.log "$BUILD_TASK"
assert_outcome scenario-c.log ":vaadinBuildFrontend" FROM-CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"

section "${project}: Scenario D (modify @Route Java)"
rm -rf build/
view=src/main/java/com/example/HelloView.java
cp "$view" "$view.bak"
# Register restore before the destructive edit so an aborted run
# still leaves the working tree clean (EXIT trap → flush_cleanups).
register_cleanup "[[ -f '$view.bak' ]] && mv '$view.bak' '$view'"
# Edit the heading literal so bytecode changes.
sed -i 's/Hello, Vaadin!/Hello, Vaadin (edited)!/' "$view"
run_gradle scenario-d.log "$BUILD_TASK"
assert_outcome scenario-d.log ":vaadinBuildFrontend" NOT_FROM_CACHE
assert_archive_has_bundle "$ARCHIVE_GLOB" "$BUNDLE_PREFIX"

success_banner "${project}: all scenarios passed"
