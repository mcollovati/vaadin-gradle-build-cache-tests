#!/usr/bin/env bash
# Parse a Gradle --console=plain log and assert the outcome of a task.
#
# Usage:
#   assert-task-outcome.sh <log-file> <task-path> <expected-outcome>
#
# expected-outcome is one of:
#   SUCCESS         the task line has no suffix (it executed and produced outputs)
#   FROM-CACHE      the task line ends with FROM-CACHE
#   UP-TO-DATE      the task line ends with UP-TO-DATE
#   NOT_FROM_CACHE  the task line is SUCCESS (no FROM-CACHE and no UP-TO-DATE suffix)
#   ANY_CACHE_HIT   FROM-CACHE or UP-TO-DATE
#
# Exits 0 on match, 1 with a diagnostic on mismatch.

set -euo pipefail

# Colour output when stdout is a real terminal. NO_COLOR=1 disables;
# FORCE_COLOR=1 enables even when piped. Mirrors the convention in
# scripts/run-project.sh so the two scripts agree on when to emit
# ANSI codes.
if [[ -n "${FORCE_COLOR:-}" ]] || { [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; }; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
else
  C_RESET=''; C_BOLD=''
  C_RED=''; C_GREEN=''
fi

ok() {
  printf '%sOK  %s %s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$1"
}

fail() {
  printf '%sFAIL%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$1" >&2
}

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <log-file> <task-path> <expected-outcome>" >&2
  exit 2
fi

log_file=$1
task_path=$2
expected=$3

if [[ ! -f "$log_file" ]]; then
  echo "assert-task-outcome: log file not found: $log_file" >&2
  exit 2
fi

# Find the last "> Task :foo" line for this task (a single build may print
# the line at multiple points; the final occurrence is the executed one).
task_line=$(grep -E "^> Task ${task_path}( |$)" "$log_file" | tail -n 1 || true)

if [[ -z "$task_line" ]]; then
  fail "task ${task_path} did not appear in $log_file"
  echo "--- last 40 lines of log ---" >&2
  tail -n 40 "$log_file" >&2
  exit 1
fi

# Strip the "> Task :path" prefix to get just the outcome suffix (or empty).
outcome=${task_line#"> Task ${task_path}"}
outcome=${outcome# }  # drop leading space if present

case "$expected" in
  SUCCESS)
    if [[ -z "$outcome" ]]; then
      ok "${task_path} = SUCCESS"
      exit 0
    fi
    ;;
  FROM-CACHE)
    if [[ "$outcome" == "FROM-CACHE" ]]; then
      ok "${task_path} = FROM-CACHE"
      exit 0
    fi
    ;;
  UP-TO-DATE)
    if [[ "$outcome" == "UP-TO-DATE" ]]; then
      ok "${task_path} = UP-TO-DATE"
      exit 0
    fi
    ;;
  NOT_FROM_CACHE)
    if [[ -z "$outcome" ]]; then
      ok "${task_path} = SUCCESS (NOT_FROM_CACHE)"
      exit 0
    fi
    ;;
  ANY_CACHE_HIT)
    if [[ "$outcome" == "FROM-CACHE" || "$outcome" == "UP-TO-DATE" ]]; then
      ok "${task_path} = ${outcome}"
      exit 0
    fi
    ;;
  *)
    echo "assert-task-outcome: unknown expected outcome '${expected}'" >&2
    exit 2
    ;;
esac

actual=${outcome:-SUCCESS}
fail "${task_path}: expected ${expected}, got ${actual}"
echo "task line: ${task_line}" >&2
exit 1
