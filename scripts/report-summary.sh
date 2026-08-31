#!/usr/bin/env bash
# Render one or more run reports written by scripts/run-project.sh into a
# summary that names every failed job and the scenario it failed in.
#
# Usage:
#   report-summary.sh [--title=<t>] [--format=markdown|annotations]
#                     [--expect-from-suite] <report-file>...
#
# A report file is the KV file run-project.sh writes on exit (default
# <project-dir>/run-report.env): job, project, mode, cc, status, scenario,
# detail, log, exit_code, scenarios, duration.
#
# Options:
#   --title=<t>          Heading of the markdown table (default
#                        "Build-cache validation summary").
#   --format=markdown    Default. A GitHub-flavoured Markdown table on
#                        stdout, failures first, plus a one-line verdict.
#                        In CI this is redirected into $GITHUB_STEP_SUMMARY.
#   --format=annotations Workflow commands on stdout instead — one
#                        "::error title=<job>::<scenario> — <detail>" per
#                        failure, so the failures also appear as annotations
#                        at the top of the run page. A separate format
#                        rather than extra output in markdown mode, because
#                        workflow commands written into $GITHUB_STEP_SUMMARY
#                        are inert.
#   --expect-from-suite  Cross-check the reports against the CI matrix
#                        derived from ALL_PROJECTS in run-suite.sh (the
#                        canonical project list): cold/<p>/cc-{off,on} plus
#                        warm/<p>. An expected job with no report is listed
#                        as MISSING — that is what a job cancelled or timed
#                        out before its upload step looks like, and without
#                        this it would silently vanish from the table.
#   --help, -h           Show this help and exit.
#
# Standalone on purpose, like assert-task-outcome.sh and assert-cc.sh: point
# it at a directory of downloaded artifacts to re-render a past run's summary
#   bash scripts/report-summary.sh */run-report.env
#
# Exit status: 0 if every report says PASS, 1 if any is FAIL or MISSING
# (so the CI job that renders the summary fails too), 2 on usage error.

set -euo pipefail

TITLE="Build-cache validation summary"
FORMAT=markdown
EXPECT_FROM_SUITE=0

script_dir=$(cd "$(dirname "$0")" && pwd)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title=*) TITLE="${1#--title=}"; shift ;;
    --title)
      if [[ $# -lt 2 ]]; then echo "report-summary: --title requires a value" >&2; exit 2; fi
      TITLE="$2"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    --format)
      if [[ $# -lt 2 ]]; then echo "report-summary: --format requires a value" >&2; exit 2; fi
      FORMAT="$2"; shift 2 ;;
    --expect-from-suite) EXPECT_FROM_SUITE=1; shift ;;
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    -*) echo "report-summary: unknown option '$1'" >&2; exit 2 ;;
    *) break ;;
  esac
done

case "$FORMAT" in
  markdown|annotations) ;;
  *) echo "report-summary: --format must be 'markdown' or 'annotations' (got '${FORMAT}')" >&2; exit 2 ;;
esac

if [[ $# -eq 0 && "$EXPECT_FROM_SUITE" -eq 0 ]]; then
  echo "usage: $0 [--title=<t>] [--format=markdown|annotations] [--expect-from-suite] <report-file>..." >&2
  exit 2
fi

# Rows are accumulated as separated records so they can be sorted and
# rendered twice (table, annotations) without re-reading anything:
#   status SEP job SEP scenario SEP detail SEP log SEP duration
SEP=$'\x1f'   # unit separator: unlike tab, IFS keeps empty fields
rows=()
seen_jobs=()

# Read one KV report file into the row list. An unreadable or empty file is a
# row too: "the job produced no report" is exactly the case a summary must not
# hide.
read_report() {
  local file=$1
  local job="" scenario="" detail="" status="" log="" duration="" key value
  if [[ ! -s "$file" ]]; then
    rows+=("MISSING${SEP}${file}${SEP}—${SEP}no run report at ${file}${SEP}${SEP}")
    return
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      job)      job=$value ;;
      status)   status=$value ;;
      scenario) scenario=$value ;;
      detail)   detail=$value ;;
      log)      log=$value ;;
      duration) duration=$value ;;
    esac
  done < "$file"
  job=${job:-$file}
  status=${status:-MISSING}
  if [[ "$status" == "PASS" ]]; then
    scenario=""
    log=""
  fi
  seen_jobs+=("$job")
  rows+=("${status}${SEP}${job}${SEP}${scenario:-—}${SEP}${detail}${SEP}${log}${SEP}${duration}")
}

for f in "${@:-}"; do
  if [[ -n "$f" ]]; then read_report "$f"; fi
done

# Expected-job cross-check. The CI shape (two cold CC legs plus one warm job
# per project) lives here rather than being passed in, so that adding a
# project to ALL_PROJECTS is the only edit needed — the same coupling the
# workflow matrices already have.
if [[ "$EXPECT_FROM_SUITE" -eq 1 ]]; then
  suite="${script_dir}/run-suite.sh"
  if [[ ! -f "$suite" ]]; then
    echo "report-summary: --expect-from-suite needs ${suite}" >&2
    exit 2
  fi
  mapfile -t all_projects < <(
    sed -n '/^ALL_PROJECTS=(/,/^)/p' "$suite" | sed -e '1d' -e '$d' -e 's/[[:space:]]//g' | grep -v '^$'
  )
  if [[ ${#all_projects[@]} -eq 0 ]]; then
    echo "report-summary: could not read ALL_PROJECTS from ${suite}" >&2
    exit 2
  fi
  expected=()
  for p in "${all_projects[@]}"; do
    expected+=("cold / ${p} / cc-off" "cold / ${p} / cc-on" "warm / ${p}")
  done
  for want in "${expected[@]}"; do
    found=0
    for have in ${seen_jobs[@]+"${seen_jobs[@]}"}; do
      if [[ "$have" == "$want" ]]; then found=1; break; fi
    done
    if [[ $found -eq 0 ]]; then
      rows+=("MISSING${SEP}${want}${SEP}—${SEP}job reported nothing (cancelled, timed out, or skipped)${SEP}${SEP}")
    fi
  done
fi

# Failures first, then missing reports, then passes; alphabetical within each
# group. The point of the table is that the bad news is at the top.
rank() {
  case "$1" in
    FAIL)    echo 0 ;;
    MISSING) echo 1 ;;
    *)       echo 2 ;;
  esac
}

sorted=()
mapfile -t sorted < <(
  for row in ${rows[@]+"${rows[@]}"}; do
    printf '%s%s%s\n' "$(rank "${row%%${SEP}*}")" "$SEP" "$row"
  done | sort -t"$SEP" -k1,1 -k3,3 | cut -d"$SEP" -f2-
)

fails=0
for row in ${sorted[@]+"${sorted[@]}"}; do
  status=${row%%${SEP}*}
  [[ "$status" == "PASS" ]] || fails=$((fails + 1))
done
total=${#sorted[@]}

# GitHub swallows a bare % (it starts a workflow-command escape) and | ends a
# table cell.
esc_annotation() { printf '%s' "${1//\%/%25}"; }
esc_cell() { local v=${1//|/\\|}; printf '%s' "$v"; }

icon() {
  case "$1" in
    PASS)    printf '✅ PASS' ;;
    FAIL)    printf '❌ FAIL' ;;
    MISSING) printf '⚠️ MISSING' ;;
    *)       printf '%s' "$1" ;;
  esac
}

if [[ "$FORMAT" == "annotations" ]]; then
  for row in ${sorted[@]+"${sorted[@]}"}; do
    IFS="$SEP" read -r status job scenario detail log duration <<<"$row"
    if [[ "$status" == "PASS" ]]; then continue; fi
    where=""
    if [[ -n "$scenario" && "$scenario" != "—" ]]; then
      where="$(esc_annotation "$scenario") — "
    fi
    printf '::error title=%s::%s%s%s\n' \
      "$(esc_annotation "$job")" \
      "$where" \
      "$(esc_annotation "$detail")" \
      "${log:+ (log: $(esc_annotation "$log"))}"
  done
else
  echo "## ${TITLE}"
  echo
  if [[ $fails -eq 0 ]]; then
    echo "All ${total} job(s) passed."
  else
    echo "**${fails} of ${total} job(s) failed.**"
  fi
  echo
  echo "| Job | Status | Scenario | Detail | Time |"
  echo "| --- | --- | --- | --- | --- |"
  for row in ${sorted[@]+"${sorted[@]}"}; do
    IFS="$SEP" read -r status job scenario detail log duration <<<"$row"
    printf '| %s | %s | %s | %s | %s |\n' \
      "$(esc_cell "$job")" \
      "$(icon "$status")" \
      "$(esc_cell "${scenario:-—}")" \
      "${detail:+\`$(esc_cell "$detail")\`}${log:+<br>log: \`$(esc_cell "$log")\`}" \
      "${duration:+${duration}s}"
  done
fi

[[ $fails -eq 0 ]]
