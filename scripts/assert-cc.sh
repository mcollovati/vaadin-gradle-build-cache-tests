#!/usr/bin/env bash
# Parse a Gradle --console=plain log and assert what happened to the
# *configuration cache* entry.
#
# Usage:
#   assert-cc.sh <log-file> <expected-state> [expected-reason-substring]
#
# expected-state is one of:
#   STORED       a fresh entry was written
#   REUSED       the previous entry was reused as-is
#   UPDATED      the entry was partially invalidated and updated in place
#   NOT_REUSED   the task graph was recalculated. With a third argument, the
#                reason Gradle printed must contain that substring, e.g.
#                   assert-cc.sh log NOT_REUSED "lib/build/libs/lib.jar"
#   NO_PROBLEMS  the build reported zero configuration-cache problems
#
# Gradle 9.3.0 message reference. Every string below was extracted from the
# distribution rather than recalled -- to re-verify after a Gradle upgrade:
#
#   d=$(echo ~/.gradle/wrapper/dists/gradle-<v>-bin/*/gradle-<v>)
#   unzip -p "$d/lib/plugins/gradle-configuration-cache-<v>.jar" '*.class' \
#     | grep -a -o "Configuration cache[[:print:]]\{0,70\}" | sort -u
#
#   store    "Calculating task graph as no cached configuration is available
#             for tasks: :web:build :web:sourcesJar :web:javadocJar"
#            ... "Configuration cache entry stored."   (or "stored with 3 problems.")
#   reuse    "Reusing configuration cache."
#            ... "Configuration cache entry reused."   (or "reused with 1 problem.")
#   update   "Configuration cache entry updated for :web, 1 up-to-date."
#   invalid  "Calculating task graph as configuration cache cannot be reused
#             because file 'lib/build/libs/lib.jar' has changed."
#            (also "... because the file system entry '<path>' has been
#             created/removed", "... directory content", "... system property")
#   discard  "Configuration cache entry discarded." / "... with N problems." /
#            "... due to serialization error." / "... with too many problems (N)."
#   degrade  "Configuration cache disabled" (+ composed reason, e.g. because an
#            incompatible task was found; also "... as cache is in read-only mode.")
#   summary  "N problems were found storing the configuration cache..."
#
# Three traps this parser exists to avoid, each of which would otherwise
# produce a silently vacuous pass:
#
#   * "Reusing configuration cache." is printed BEFORE execution and is not
#     proof of reuse -- the entry can still be discarded afterwards. Only the
#     last "Configuration cache entry ..." line is authoritative.
#   * "Configuration cache entry updated for ..." is a third state (partial,
#     per-project invalidation) that is neither stored nor reused.
#   * Graceful degradation makes the build SUCCEED with no entry at all, so a
#     bare "the log does not say reused" test would pass while measuring
#     nothing. Degradation is reported as its own failure.

set -euo pipefail

if [[ -n "${FORCE_COLOR:-}" ]] || { [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; }; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''
fi

ok()   { printf '%sOK  %s %s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$1"; }
fail() { printf '%sFAIL%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$1" >&2; }

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <log-file> <STORED|REUSED|UPDATED|NOT_REUSED|NO_PROBLEMS> [reason-substring]" >&2
  exit 2
fi

log_file=$1
expected=$2
want_reason=${3:-}

if [[ ! -f "$log_file" ]]; then
  echo "assert-cc: log file not found: $log_file" >&2
  exit 2
fi

# `|| true` on every grep: a no-match (exit 1) under pipefail would otherwise
# propagate out of the command substitution and kill the script via set -e.
# tail -n 1 because the status line is printed once per build and the last one
# describes the root build's entry.
status=$(grep   -E '^Configuration cache entry '  "$log_file" | tail -n 1 || true)
calc=$(grep     -E '^Calculating task graph as '  "$log_file" | tail -n 1 || true)
degraded=$(grep -E '^Configuration cache disabled' "$log_file" | tail -n 1 || true)
problems=$(grep -E '[0-9]+ problems? (were|was) found' "$log_file" | tail -n 1 || true)

dump_context() {
  echo "--- configuration-cache lines in ${log_file} ---" >&2
  grep -nE '^(Calculating task graph|Reusing configuration cache|Configuration cache)' \
    "$log_file" >&2 || \
    echo "  (none - was --configuration-cache actually passed?)" >&2
  grep -F 'See the complete report at' "$log_file" >&2 || true
}

# Degradation short-circuit: the build succeeded but no entry exists, so none
# of the state assertions below can be meaningful.
if [[ -n "$degraded" && "$expected" != "NO_PROBLEMS" ]]; then
  fail "configuration cache was disabled for this build, so '${expected}' cannot hold"
  echo "  ${degraded}" >&2
  dump_context
  exit 1
fi

case "$expected" in
  STORED)
    # Prefix match so "stored with N problems." still counts as stored;
    # NO_PROBLEMS is the assertion that rejects the problem-carrying variant.
    case "$status" in
      "Configuration cache entry stored"*) ok "configuration cache entry stored"; exit 0 ;;
    esac
    ;;
  REUSED)
    case "$status" in
      "Configuration cache entry reused"*) ok "configuration cache entry reused"; exit 0 ;;
    esac
    ;;
  UPDATED)
    case "$status" in
      "Configuration cache entry updated"*) ok "configuration cache entry updated"; exit 0 ;;
    esac
    ;;
  NOT_REUSED)
    case "$status" in
      "Configuration cache entry reused"*)
        fail "configuration cache entry was reused, expected it NOT to be"
        dump_context
        exit 1
        ;;
    esac
    if [[ -z "$calc" ]]; then
      fail "no 'Calculating task graph as ...' line: cannot prove the entry was not reused"
      dump_context
      exit 1
    fi
    if [[ -n "$want_reason" && "$calc" != *"$want_reason"* ]]; then
      fail "entry was not reused, but for the wrong reason (expected it to mention '${want_reason}')"
      echo "  ${calc}" >&2
      exit 1
    fi
    ok "configuration cache entry not reused: ${calc#Calculating task graph as }"
    exit 0
    ;;
  NO_PROBLEMS)
    if [[ -n "$problems" ]]; then
      fail "configuration cache problems reported: ${problems}"
      dump_context
      exit 1
    fi
    # "stored with 3 problems." / "reused with 1 problem." / "discarded with ..."
    if [[ "$status" == *" with "*"problem"* ]]; then
      fail "configuration cache entry carries problems: ${status}"
      dump_context
      exit 1
    fi
    ok "no configuration cache problems"
    exit 0
    ;;
  *)
    echo "assert-cc: unknown expected state '${expected}'" >&2
    exit 2
    ;;
esac

fail "expected configuration cache entry ${expected}, got: ${status:-<no status line>}"
[[ -n "$calc" ]] && echo "  ${calc}" >&2
dump_context
exit 1
