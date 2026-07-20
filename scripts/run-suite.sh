#!/usr/bin/env bash
# Run the whole build-cache suite: drive scripts/run-project.sh over every
# test project and collect per-project PASS/FAIL into a final summary.
#
# Usage:
#   run-suite.sh [--cache=cold|warm] [--fail-fast] [--projects="p1 p2 ..."] <flow-version>
#
# Options:
#   --cache=cold         Default. Run each project with --cache=cold, i.e.
#                        wipe the shared Gradle build cache and run
#                        scenarios A/B/C/D. Each project's cold run is
#                        self-contained (it primes and hits its own cache
#                        within scenario A), so running every project in
#                        turn is a complete local validation.
#   --cache=warm         Run each project with --cache=warm (clean build
#                        must hit FROM-CACHE). NOTE: this expects every
#                        project's cache to already be populated. Because
#                        cold mode wipes the *shared* build-cache-1 on each
#                        invocation, a local `--cache=cold` suite run does
#                        NOT leave all projects' caches in place — the last
#                        cold project wins. Warm-all is therefore a CI
#                        concern, where each project's cache is persisted
#                        and restored in isolation (see build-cache.yml).
#   --fail-fast          Stop at the first failing project. Default is to
#                        run every project and report all results.
#   --projects="a b c"   Space-separated subset to run instead of all.
#                        Order is preserved; unknown names are rejected.
#   --help, -h           Show this help and exit.
#
# Env and Gradle overrides (GRADLE_BIN, GRADLE_USER_HOME, NO_COLOR,
# FORCE_COLOR) are honoured by the underlying run-project.sh unchanged.
#
# Exit status: 0 if every project passed, 1 if any failed, 2 on usage error.

set -euo pipefail

if [[ -n "${FORCE_COLOR:-}" ]] || { [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; }; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

# Canonical project list — keep in sync with the case statement in
# run-project.sh, the matrices in .github/workflows/build-cache.yml, and
# the table in README.md.
ALL_PROJECTS=(
  plain-jar
  war
  spring-boot-jar
  shaded-jar
  custom-jar-task
  custom-frontend-output
  custom-frontend-output-flat
)

CACHE_MODE=cold
FAIL_FAST=0
SELECTED=()

# Validate and assign a --cache value (cold or warm).
set_cache_mode() {
  case "$1" in
    cold|warm)
      CACHE_MODE=$1
      ;;
    *)
      echo "run-suite: --cache value must be 'cold' or 'warm' (got '$1')" >&2
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
        echo "run-suite: --cache requires a value (cold|warm)" >&2
        exit 2
      fi
      set_cache_mode "$2"
      shift 2
      ;;
    --fail-fast)
      FAIL_FAST=1
      shift
      ;;
    --projects=*)
      # shellcheck disable=SC2206  # word-splitting on the space-separated list is intended.
      SELECTED=(${1#--projects=})
      shift
      ;;
    --projects)
      if [[ $# -lt 2 ]]; then
        echo "run-suite: --projects requires a value" >&2
        exit 2
      fi
      # shellcheck disable=SC2206
      SELECTED=($2)
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
      echo "run-suite: unknown option '$1'" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 1 ]]; then
  echo "usage: $0 [--cache=cold|warm] [--fail-fast] [--projects=\"p1 p2 ...\"] <flow-version>" >&2
  exit 2
fi

flow_version=$1

script_dir=$(cd "$(dirname "$0")" && pwd)
runner="${script_dir}/run-project.sh"

if [[ ! -x "$runner" && ! -f "$runner" ]]; then
  echo "run-suite: cannot find run-project.sh at ${runner}" >&2
  exit 2
fi

# Resolve the project list: an explicit --projects subset (validated
# against the canonical list) or all projects in canonical order.
projects=()
if [[ ${#SELECTED[@]} -gt 0 ]]; then
  for p in "${SELECTED[@]}"; do
    found=0
    for known in "${ALL_PROJECTS[@]}"; do
      if [[ "$p" == "$known" ]]; then found=1; break; fi
    done
    if [[ $found -eq 0 ]]; then
      echo "run-suite: unknown project '${p}' (known: ${ALL_PROJECTS[*]})" >&2
      exit 2
    fi
    projects+=("$p")
  done
else
  projects=("${ALL_PROJECTS[@]}")
fi

echo "${C_BOLD}${C_CYAN}Running suite: cache=${CACHE_MODE}, flow=${flow_version}, projects=${#projects[@]}${C_RESET}"
echo "${C_DIM}${projects[*]}${C_RESET}"

statuses=()   # parallel to `projects`: PASS or FAIL
durations=()  # parallel to `projects`: seconds
failures=0

for project in "${projects[@]}"; do
  printf '\n%s########################################################%s\n' "${C_BOLD}${C_CYAN}" "$C_RESET"
  printf '%s#  %s (%s)%s\n' "${C_BOLD}${C_CYAN}" "$project" "$CACHE_MODE" "$C_RESET"
  printf '%s########################################################%s\n\n' "${C_BOLD}${C_CYAN}" "$C_RESET"

  start=$SECONDS
  # Run directly (not in a pipe) so run-project.sh's own tty/colour
  # detection and live output are preserved. Guard with if/else so a
  # failure does not trip our own set -e — we want to keep going.
  if bash "$runner" "--cache=${CACHE_MODE}" "$project" "$flow_version"; then
    statuses+=("PASS")
  else
    statuses+=("FAIL")
    failures=$((failures + 1))
  fi
  durations+=("$((SECONDS - start))")

  if [[ "${statuses[-1]}" == "FAIL" && $FAIL_FAST -eq 1 ]]; then
    echo "${C_YELLOW}run-suite: --fail-fast set, stopping after ${project}${C_RESET}" >&2
    break
  fi
done

# Summary.
rule="════════════════════════════════════════════════════════"
printf '\n%s%s%s\n' "${C_BOLD}${C_CYAN}" "$rule" "$C_RESET"
printf '%s  Suite summary (cache=%s)%s\n' "${C_BOLD}${C_CYAN}" "$CACHE_MODE" "$C_RESET"
printf '%s%s%s\n' "${C_BOLD}${C_CYAN}" "$rule" "$C_RESET"

for i in "${!statuses[@]}"; do
  st="${statuses[$i]}"
  if [[ "$st" == "PASS" ]]; then
    colour="$C_GREEN"
  else
    colour="$C_RED"
  fi
  printf '  %s%-4s%s  %-26s %ss\n' \
    "${colour}${C_BOLD}" "$st" "$C_RESET" "${projects[$i]}" "${durations[$i]}"
done

# Note any projects that were skipped by --fail-fast.
run_count=${#statuses[@]}
if [[ $run_count -lt ${#projects[@]} ]]; then
  for ((i=run_count; i<${#projects[@]}; i++)); do
    printf '  %sSKIP%s  %-26s %s\n' "${C_YELLOW}${C_BOLD}" "$C_RESET" "${projects[$i]}" "(fail-fast)"
  done
fi

printf '%s%s%s\n\n' "${C_BOLD}${C_CYAN}" "$rule" "$C_RESET"

if [[ $failures -gt 0 ]]; then
  printf '%s%s FAILED: %d/%d project(s) failed%s\n' \
    "$C_RED$C_BOLD" "✗" "$failures" "$run_count" "$C_RESET" >&2
  exit 1
fi

printf '%s%s PASSED: all %d project(s) passed%s\n' \
  "$C_GREEN$C_BOLD" "✓" "$run_count" "$C_RESET"
