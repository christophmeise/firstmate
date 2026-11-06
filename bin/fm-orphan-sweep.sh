#!/usr/bin/env bash
# fm-orphan-sweep.sh - stop orphaned no-mistakes validation databases, and report
# anything else that is burning a core.
#
# Usage:
#   fm-orphan-sweep.sh [check] [--dry-run]
#   fm-orphan-sweep.sh --dry-run
#   fm-orphan-sweep.sh arm
#   fm-orphan-sweep.sh disarm
#   fm-orphan-sweep.sh --help
#
# `check` prints one line when firstmate should act and nothing otherwise, so it
# composes with the watcher state-check contract. `arm` writes
# state/orphan-sweep.check.sh and binds its bytes with fm-check-register.sh, so
# the watcher dispatches it on its normal FM_CHECK_INTERVAL cadence and turns the
# line into a `check:` wake. The shim and its binding live in state/, so an armed
# home stays armed across sessions and restarts and nothing re-arms it at startup.
# Arming is a deliberate per-machine opt-in rather than a bootstrap default,
# because this is the one check that signals processes; arm it in one home per
# machine, since the sweep covers the whole machine for the current user.
# `disarm` removes the shim, its binding, and the record, and keeps the audit log.
#
# `--dry-run` prints what a sweep would stop, leave, and report, ignores the
# interval gate, sends no signal, and writes nothing.
#
# What may be stopped. A process is stopped only when every one of these holds,
# and any question that cannot be answered leaves the process alone:
#
#   allowlist   it is the one class below, matched on its full command line, and
#               owned by the current user
#   orphaned    its ppid is 1; a living parent, whoever it is, means leave it
#   age         it is older than the class threshold
#   not live    its working directory is not inside the worktree or temp
#               directory of any task record in any local home, and it holds no
#               established TCP connection
#
#   mysqld      a no-mistakes validation database: exactly one
#               --datadir=<...>/no-mistakes-evidence/<run-id>/mysql/data. The
#               run must also be recorded as finished in no-mistakes' own
#               database; a pending, running, unknown, or unrecorded run leaves
#               it alone. Default minimum age 2 hours.
#
# chrome-devtools-axi bridges are not on the list and are never signalled here:
# bin/fm-automation-browser-reap.sh, which the watcher runs, is their only owner.
# A new class needs what this one has: a real observed orphan, a narrow match, a
# check that proves it belongs to nothing live, and no other owner.
#
# How it stops. Candidates are evaluated and sent SIGTERM one at a time, then
# share one bounded wait, then whatever remains gets SIGKILL. Immediately before
# every signal a fresh process table must show the same pid, start time, and
# command with ppid still 1, so a reused pid is never signalled. Signals go to one
# exact pid; there is no pattern, group, or negative-pid form anywhere in this file.
#
# After a stopped mysqld is confirmed gone, its own socket, socket lock, and pid
# file are removed if they are still what it left: named on its command line,
# owned by this user, recording its pid where the file records one, and named by
# no other running process. Evidence directories are never deleted.
#
# Report-only findings, each once per process (pid and start time) for as long
# as that process lives:
#
#   hot         any process of this user, other than one in an operating-system
#               path, that has used more than 80% of a core for over an hour.
#               Measured from the CPU-time difference between sweeps, or from
#               lifetime average on first sight. Never acted on.
#   unverified  an allowlisted orphan past its age threshold whose liveness could
#               not be answered, so a sweep that has gone blind is not silent.
#
# Every stop is appended to state/orphan-sweep.log as tab-separated time, outcome,
# class, pid, start time, last signal, reason, removed files, and command, capped
# at 64 KiB by dropping the oldest lines. state/.orphan-sweep holds the interval
# gate, the once-per-process keys, and the CPU samples.
#
# Settings, read from the environment. A check sees only the watcher's own
# environment, so `arm` copies any of them that are set into the shim:
#
#   FM_ORPHAN_SWEEP_INTERVAL        seconds between sweeps, default 1800, 0 disables
#                                   the gate, otherwise 60..86400
#   FM_ORPHAN_SWEEP_MYSQLD_MIN_AGE  seconds, default 7200, at least 60
#   FM_ORPHAN_SWEEP_TERM_GRACE      seconds between SIGTERM and SIGKILL, default 10,
#                                   1..60, cut down to fit the watcher's per-check
#                                   bound (FM_CHECK_TIMEOUT) when it would not
#   FM_ORPHAN_SWEEP_PROBE_SECS      seconds allowed for one ps, lsof, or sqlite3 read,
#                                   default 5, 1..30, cut to a third of that bound
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.orphan-sweep"
AUDIT="$STATE/orphan-sweep.log"
CHECK_ID=orphan-sweep
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-orphan-sweep-v1
MAX_LINE=1000
REPORT_PREFIX='orphan sweep: '
REPORT_LOOK='look: '
REPORT_TEXT=
AUDIT_MAX_BYTES=65536
KILL_WAIT_SECS=3
HOT_SHARE_PERCENT=80
HOT_SECS=3600
HOT_MIN_SAMPLE_SECS=60
SETTINGS='FM_ORPHAN_SWEEP_INTERVAL FM_ORPHAN_SWEEP_MYSQLD_MIN_AGE FM_ORPHAN_SWEEP_TERM_GRACE FM_ORPHAN_SWEEP_PROBE_SECS'

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-orphan-sweep.sh [check] [--dry-run]  sweep once; one line when firstmate should act, silent otherwise
  fm-orphan-sweep.sh --dry-run            print what a sweep would stop, leave, and report; changes nothing
  fm-orphan-sweep.sh arm                  write and register state/orphan-sweep.check.sh
  fm-orphan-sweep.sh disarm               remove the check shim, its trust binding, and the record
  fm-orphan-sweep.sh --help               print this help

See docs/configuration.md "Orphan process sweep" for what it stops and its settings.
EOF
}

die_usage() {
  printf 'fm-orphan-sweep: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# whole_number_setting <name> <value> <min> <max> <description>
whole_number_setting() {
  case "$2" in
    ''|*[!0-9]*) ;;
    *) [ "${#2}" -le 9 ] && [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] && return 0 ;;
  esac
  printf 'fm-orphan-sweep: %s must be %s\n' "$1" "$5" >&2
  exit 2
}

INTERVAL=${FM_ORPHAN_SWEEP_INTERVAL:-1800}
[ "$INTERVAL" = 0 ] || whole_number_setting FM_ORPHAN_SWEEP_INTERVAL "$INTERVAL" 60 86400 \
  '0 or a whole number from 60 to 86400'
MYSQLD_MIN_AGE=${FM_ORPHAN_SWEEP_MYSQLD_MIN_AGE:-7200}
whole_number_setting FM_ORPHAN_SWEEP_MYSQLD_MIN_AGE "$MYSQLD_MIN_AGE" 60 99999999 'a whole number of at least 60'
TERM_GRACE=${FM_ORPHAN_SWEEP_TERM_GRACE:-10}
whole_number_setting FM_ORPHAN_SWEEP_TERM_GRACE "$TERM_GRACE" 1 60 'a whole number from 1 to 60'
PROBE_SECS=${FM_ORPHAN_SWEEP_PROBE_SECS:-5}
whole_number_setting FM_ORPHAN_SWEEP_PROBE_SECS "$PROBE_SECS" 1 30 'a whole number from 1 to 30'

# A run the watcher kills prints nothing, so the whole sweep has to fit inside its
# per-check bound: evaluation, the grace, and the short wait after SIGKILL.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
PROBE_MAX=$((CHECK_TIMEOUT / 3))
[ "$PROBE_MAX" -ge 1 ] || PROBE_MAX=1
[ "$PROBE_SECS" -le "$PROBE_MAX" ] || PROBE_SECS=$PROBE_MAX
RESERVED_SECS=$((PROBE_SECS + KILL_WAIT_SECS + 2))
GRACE_MAX=$((CHECK_TIMEOUT - RESERVED_SECS - 1))
[ "$GRACE_MAX" -ge 1 ] || GRACE_MAX=1
[ "$TERM_GRACE" -le "$GRACE_MAX" ] || TERM_GRACE=$GRACE_MAX
EVALUATE_SECS=$((CHECK_TIMEOUT - RESERVED_SECS - TERM_GRACE))
[ "$EVALUATE_SECS" -ge 1 ] || EVALUATE_SECS=1

# The record epoch is overridable so a test can drive the gate and the CPU
# samples; the evaluation budget always uses real time.
record_epoch_now() {
  case "${FM_ORPHAN_SWEEP_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_ORPHAN_SWEEP_NOW" ;;
  esac
}

human_age() {
  local secs=$1
  if [ "$secs" -ge 86400 ]; then
    printf '%sd' "$((secs / 86400))"
  elif [ "$secs" -ge 3600 ]; then
    printf '%sh' "$((secs / 3600))"
  else
    printf '%sm' "$((secs / 60))"
  fi
}

# --- process table ----------------------------------------------------------

# SNAP holds this user's processes, one per line, tab-separated:
#   pid ppid elapsed-secs cpu-secs start command
# A failed or empty read returns 1 and leaves SNAP empty, and everything that
# needs the table treats that as a question that could not be answered.
SNAP=
OWN_UID=$(id -u)

snapshot() {
  local raw
  SNAP=
  raw=$(fm_run_timed "$PROBE_SECS" ps -axww -o pid=,ppid=,uid=,etime=,time=,pcpu=,lstart=,command= 2>/dev/null) || return 1
  SNAP=$(printf '%s\n' "$raw" | awk -v uid="$OWN_UID" '
    function secs(t,   parts, n, i, days, total, dayparts) {
      days = 0
      if (index(t, "-")) { split(t, dayparts, "-"); days = dayparts[1]; t = dayparts[2] }
      n = split(t, parts, ":")
      total = 0
      for (i = 1; i <= n; i++) total = total * 60 + parts[i]
      return int(days * 86400 + total)
    }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 == uid && NF >= 12 {
      line = $0
      sub(/^[ \t]+/, "", line)
      for (i = 0; i < 11; i++) sub(/^[^ \t]+[ \t]+/, "", line)
      gsub(/\t/, " ", line)
      printf "%s\t%s\t%d\t%d\t%s %s %s %s %s\t%s\n", $1, $2, secs($4), secs($5), $7, $8, $9, $10, $11, line
    }')
  [ -n "$SNAP" ]
}

# identity_state <pid> <start> <command>: takes a fresh table and answers 0 when
# this exact process is still there as an orphan, 1 when it is not (gone, or the
# pid now names something else), and 2 when the table could not be read.
identity_state() {
  local row pid ppid start command
  snapshot || return 2
  row=$(printf '%s\n' "$SNAP" | awk -F'\t' -v p="$1" '$1 == p { print; exit }')
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r pid ppid _ _ start command <<<"$row"
  [ "$pid" = "$1" ] && [ "$ppid" = 1 ] && [ "$start" = "$2" ] && [ "$command" = "$3" ]
}

# The single place a signal leaves this script. One exact pid, proved identical
# by a table read in the same breath, or nothing is sent. `env` reaches the
# external kill, so the call is the same one a PATH fake can observe.
signal_exact() {  # <signal> <pid> <start> <command>
  case "$2" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  [ "$2" != "$$" ] || return 1
  identity_state "$2" "$3" "$4" || return 1
  env kill "-$1" "$2" 2>/dev/null
}

# --- allowlist --------------------------------------------------------------

CLASS=
RUN_ID=

classify() {  # <command>
  local token datadir='' count=0
  local -a argv
  CLASS=
  RUN_ID=
  read -r -a argv <<<"$1"
  [ "${#argv[@]}" -ge 1 ] || return 1
  [ "${argv[0]##*/}" = mysqld ] || return 1
  for token in "${argv[@]}"; do
    case "$token" in
      --datadir=*) datadir=${token#--datadir=}; count=$((count + 1)) ;;
    esac
  done
  [ "$count" = 1 ] || return 1
  [[ "$datadir" =~ ^/.*/no-mistakes-evidence/([0-9A-HJKMNP-TV-Z]{26})/mysql/data/?$ ]] || return 1
  RUN_ID=${BASH_REMATCH[1]}
  CLASS=mysqld
}

# --- liveness ---------------------------------------------------------------

# Every worktree and task temp directory recorded by any local home, as
# "<task>\t<path>" lines. Read at most once per sweep, and only when a candidate
# needs it. LIVE_PATHS_ERROR set means the question cannot be answered.
LIVE_PATHS=
LIVE_PATHS_READ=0
LIVE_PATHS_ERROR=

live_paths_add() {  # <task> <path>
  local path=${2%/} resolved
  [ -n "$path" ] || return 0
  LIVE_PATHS="$LIVE_PATHS$1"$'\t'"$path"$'\n'
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 0
  [ "$resolved" = "$path" ] || LIVE_PATHS="$LIVE_PATHS$1"$'\t'"$resolved"$'\n'
}

live_paths_read() {
  local state meta task line
  [ "$LIVE_PATHS_READ" = 0 ] || return 0
  LIVE_PATHS_READ=1
  # Older libraries lack this enumerator. "Could not list the live tasks" must
  # never read as "there are none", whatever the reason it failed.
  if ! command -v fm_local_firstmate_state_dirs >/dev/null 2>&1 \
    || ! fm_local_firstmate_state_dirs "$STATE"; then
    LIVE_PATHS_ERROR=${FM_LOCAL_FIRSTMATE_ERROR:-live tasks could not be listed}
    return 0
  fi
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    [ -e "$state" ] || continue
    if [ ! -d "$state" ] || [ ! -r "$state" ]; then
      LIVE_PATHS_ERROR="task records are unreadable at $state"
      return 0
    fi
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      if [ ! -r "$meta" ]; then
        LIVE_PATHS_ERROR="task record is unreadable at $meta"
        return 0
      fi
      task=${meta##*/}
      task=${task%.meta}
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          worktree=*) live_paths_add "$task" "${line#worktree=}" ;;
          tasktmp=*) live_paths_add "$task" "${line#tasktmp=}" ;;
        esac
      done < "$meta"
    done
  done
}

# Sets LIVE_TASK when <cwd> is at or under a recorded path.
LIVE_TASK=
cwd_live_task() {  # <cwd>
  local task path
  LIVE_TASK=
  while IFS=$'\t' read -r task path; do
    [ -n "$path" ] || continue
    case "$1/" in
      "$path"/*) LIVE_TASK=$task; return 0 ;;
    esac
  done <<<"$LIVE_PATHS"
  return 1
}

# lsof exits 1 both for "nothing matched" and for a real failure. So the working
# directory read, which must print a path, is what proves lsof can see this
# process at all, and a later empty answer from it can then be believed.
process_cwd() {  # <pid>
  local out
  out=$(fm_run_timed "$PROBE_SECS" lsof -a -p "$1" -d cwd -Fn 2>/dev/null) || return 1
  printf '%s\n' "$out" | sed -n 's/^n//p' | head -1
}

# 0 when the process holds an established TCP connection, 1 when it provably does
# not, 2 when lsof's answer cannot be read as either.
has_established_connection() {  # <pid>
  local out status=0
  out=$(fm_run_timed "$PROBE_SECS" lsof -nP -a -p "$1" -iTCP -sTCP:ESTABLISHED -Fn 2>&1) || status=$?
  if [ "$status" = 1 ] && [ -z "$out" ]; then
    return 1
  fi
  if [ "$status" = 0 ] && printf '%s\n' "$out" | grep -q '^n'; then
    return 0
  fi
  return 2
}

# Prints the run's recorded status word, or nothing when it cannot be read. The
# id was validated by classify, so it is safe inside the SQL literal.
run_status() {  # <run-id>
  local db
  db=$(fm_nm_state_db "$FM_HOME")
  [ -f "$db" ] || return 1
  fm_run_timed "$PROBE_SECS" sqlite3 -readonly "file:$db?mode=ro" \
    "select status from runs where id='$1';" 2>/dev/null
}

# Sets VERDICT to stop, leave, or unverified, and WHY to the reason.
VERDICT=
WHY=

decide() {  # <verdict> <why>
  VERDICT=$1
  WHY=$2
  [ "$1" = stop ]
}

evaluate() {  # <pid> <ppid> <elapsed> <run-id>
  local pid=$1 ppid=$2 elapsed=$3 run=$4 cwd status word
  [ "$ppid" = 1 ] || { decide leave "parent $ppid is alive"; return; }
  [ "$elapsed" -ge "$MYSQLD_MIN_AGE" ] || { decide leave "younger than ${MYSQLD_MIN_AGE}s"; return; }

  live_paths_read
  [ -z "$LIVE_PATHS_ERROR" ] || { decide unverified "$LIVE_PATHS_ERROR"; return; }
  cwd=$(process_cwd "$pid")
  case "$cwd" in
    /*) ;;
    *) decide unverified "working directory could not be read"; return ;;
  esac
  if cwd_live_task "$cwd"; then
    decide leave "tied to live task $LIVE_TASK"
    return
  fi

  status=0
  has_established_connection "$pid" || status=$?
  case "$status" in
    0) decide leave "holds an established connection"; return ;;
    1) ;;
    *) decide unverified "connections could not be read"; return ;;
  esac

  word=$(run_status "$run") || word=
  case "$(fm_nm_run_status_class "$word")" in
    terminal) decide stop "validation database of $word run $run" ;;
    live) decide leave "run $run is active" ;;
    *) decide unverified "status of run $run could not be read" ;;
  esac
}

# --- cleanup of what a stopped process owned --------------------------------

# Prints the path of each file removed. A file named on the command line of any
# other process stays, and so does anything that is not plainly what the stopped
# process left behind.
remove_owned_files() {  # <pid> <command>
  local pid=$1 token datadir='' socket='' pidfile='' recorded
  local -a argv
  read -r -a argv <<<"$2"
  for token in "${argv[@]}"; do
    case "$token" in
      --datadir=*) datadir=${token#--datadir=}; datadir=${datadir%/} ;;
      --socket=*) socket=${token#--socket=} ;;
      --pid-file=*) pidfile=${token#--pid-file=} ;;
    esac
  done
  [ -n "$datadir" ] || return 0
  snapshot || return 0
  if [ -n "$socket" ] && path_is_unreferenced "$socket"; then
    case "$socket" in
      /tmp/nm*/*|/private/tmp/nm*/*) ;;
      /tmp/nm*.sock|/private/tmp/nm*.sock|"$datadir"/*)
        if [ -S "$socket" ] && [ ! -L "$socket" ] && [ -O "$socket" ] && rm -f -- "$socket"; then
          printf '%s\n' "$socket"
          if [ -f "$socket.lock" ] && [ ! -L "$socket.lock" ] && [ -O "$socket.lock" ]; then
            IFS= read -r recorded < "$socket.lock" || true
            [ "${recorded:-}" != "$pid" ] || { rm -f -- "$socket.lock" && printf '%s\n' "$socket.lock"; }
          fi
        fi
        ;;
    esac
  fi
  if [ -n "$pidfile" ] && path_is_unreferenced "$pidfile"; then
    case "$pidfile" in
      /tmp/nm*/*|/private/tmp/nm*/*) ;;
      /tmp/nm*.pid|/private/tmp/nm*.pid|"$datadir"/*)
        if [ -f "$pidfile" ] && [ ! -L "$pidfile" ] && [ -O "$pidfile" ]; then
          IFS= read -r recorded < "$pidfile" || true
          [ "${recorded:-}" != "$pid" ] || { rm -f -- "$pidfile" && printf '%s\n' "$pidfile"; }
        fi
        ;;
    esac
  fi
}

path_is_unreferenced() {  # <path>
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    */../*) return 1 ;;
  esac
  ! printf '%s\n' "$SNAP" | grep -qF -- "$1"
}

# --- record and audit -------------------------------------------------------

RECORD_EPOCH=0
RECORD_SEEN=
RECORD_CPU=

record_read() {
  local line first=1
  RECORD_EPOCH=0
  RECORD_SEEN=
  RECORD_CPU=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      epoch=*)
        line=${line#epoch=}
        case "$line" in
          ''|*[!0-9]*) RECORD_EPOCH=0 ;;
          *) RECORD_EPOCH=$line ;;
        esac
        ;;
      seen$'\t'*) RECORD_SEEN="$RECORD_SEEN${line#seen$'\t'}"$'\n' ;;
      cpu$'\t'*) RECORD_CPU="$RECORD_CPU${line#cpu$'\t'}"$'\n' ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {  # <seen-keys> <cpu-rows>
  local tmp line
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    while IFS= read -r line; do
      [ -z "$line" ] || printf 'seen\t%s\n' "$line"
    done <<<"$1"
    while IFS= read -r line; do
      [ -z "$line" ] || printf 'cpu\t%s\n' "$line"
    done <<<"$2"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
}

audit_append() {  # <outcome> <class> <pid> <start> <signal> <why> <removed> <command>
  local size tmp
  [ ! -L "$AUDIT" ] || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:0:300}" >> "$AUDIT" || return 1
  chmod 0600 "$AUDIT" 2>/dev/null || true
  size=$(wc -c < "$AUDIT" | tr -d ' ')
  [ "$size" -gt "$AUDIT_MAX_BYTES" ] || return 0
  tmp=$(mktemp "$AUDIT.XXXXXX" 2>/dev/null) || return 1
  # Keep the newest half, starting at a whole line.
  if tail -c "$((AUDIT_MAX_BYTES / 2))" "$AUDIT" | sed 1d > "$tmp" && chmod 0600 "$tmp"; then
    mv -f -- "$tmp" "$AUDIT" || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
}

# --- sweep ------------------------------------------------------------------

DRY_RUN=0
STOPPED=
LOOK_QUEUE=
NEW_SEEN=

add_stopped() { STOPPED="${STOPPED:+$STOPPED, }$1"; }

# Queue <text> to be reported once for <key>, a pid|start|kind or tool key. A
# text too long for a line of its own is shortened here, so every queued entry
# can fit on some sweep's line.
look_once() {  # <key> <text>
  case $'\n'"$RECORD_SEEN" in
    *$'\n'"$1"$'\n'*)
      NEW_SEEN="$NEW_SEEN$1"$'\n'
      return 0
      ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then
    printf 'would report: %s\n' "$2"
    return 0
  fi
  fm_cap_line_var "${2//$'\n'/ }" "$((MAX_LINE - ${#REPORT_PREFIX} - ${#REPORT_LOOK}))"
  LOOK_QUEUE="$LOOK_QUEUE$1"$'\t'"$FM_LINE_CAP_LINE"$'\n'
}

# Prints the one report line, if there is anything to say. A queued entry goes on
# the line whole or not at all, and only an entry on the line counts as reported,
# so one that does not fit is queued again by the next sweep that still sees it.
report_line() {
  local head=$REPORT_PREFIX lead key entry candidate looks=''
  [ -z "$STOPPED" ] || head="${head}stopped $STOPPED"
  lead="$head${STOPPED:+; }$REPORT_LOOK"
  while IFS=$'\t' read -r key entry; do
    [ -n "$key" ] || continue
    candidate="${looks:+$looks; }$entry"
    [ "$((${#lead} + ${#candidate}))" -le "$MAX_LINE" ] || continue
    looks=$candidate
    NEW_SEEN="$NEW_SEEN$key"$'\n'
  done <<<"$LOOK_QUEUE"
  [ -n "$STOPPED$looks" ] || return 0
  if [ -n "$looks" ]; then
    head="$lead$looks"
  fi
  fm_cap_line_var "$head" "$MAX_LINE"
  REPORT_TEXT=$FM_LINE_CAP_LINE
}

# Keys for processes still running stay reported, so a process that dips and
# returns is still reported only once. Keys for anything else need the condition
# to have been seen again this sweep, which look_once already recorded.
carried_seen_keys() {
  local key pid start rest
  while IFS='|' read -r pid start rest; do
    [ -n "$rest" ] || continue
    key="$pid|$start|$rest"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if printf '%s\n' "$SNAP" | awk -F'\t' -v p="$pid" -v s="$start" '$1 == p && $5 == s { found = 1 } END { exit !found }'; then
      printf '%s\n' "$key"
    fi
  done <<<"$RECORD_SEEN"
}

# Reads the prior samples and the current table, and prints one "cpu" line per
# sample to keep and one "hot" line per process over the threshold.
hot_scan() {  # <now> <stopped-pids>
  { printf '%s' "$RECORD_CPU" | awk '{ print "prev\t" $0 }'; printf '%s\n' "$SNAP" | awk '{ print "row\t" $0 }'; } |
    awk -F'\t' -v now="$1" -v stopped=" $2 " -v self="$$" -v share="$HOT_SHARE_PERCENT" \
      -v hot_secs="$HOT_SECS" -v min_sample="$HOT_MIN_SAMPLE_SECS" '
      $1 == "prev" { k = $2 SUBSEP $3; pcpu[k] = $4; pepoch[k] = $5; phot[k] = $6; next }
      $1 != "row" { next }
      {
        pid = $2; elapsed = $4; cpu = $5; start = $6; command = $7
        k = pid SUBSEP start
        hot = 0; sample_cpu = cpu; sample_epoch = now
        if (k in pcpu) {
          wall = now - pepoch[k]
          if (wall < min_sample) {
            hot = phot[k]; sample_cpu = pcpu[k]; sample_epoch = pepoch[k]
          } else if ((cpu - pcpu[k]) * 100 >= share * wall) {
            hot = phot[k] > 0 ? phot[k] : pepoch[k]
          }
        } else if (elapsed >= min_sample && cpu * 100 >= share * elapsed) {
          hot = now - elapsed
        }
        if (cpu >= min_sample || hot > 0) {
          printf "cpu\t%s\t%s\t%d\t%d\t%d\n", pid, start, sample_cpu, sample_epoch, hot
        }
        if (hot > 0 && now - hot >= hot_secs && pid != self && index(stopped, " " pid " ") == 0 \
          && command !~ /^(\/System\/|\/usr\/libexec\/|\/usr\/sbin\/|\/sbin\/|\/Library\/Apple\/)/) {
          printf "hot\t%s\t%s\t%d\t%s\n", pid, start, now - hot, command
        }
      }'
}

# Candidates that got SIGTERM, one per line: pid, class, start, why, command.
PENDING=
STOPPED_PIDS=

finish_stop() {  # <pid> <class> <start> <why> <command> <signal>
  local removed
  removed=$(remove_owned_files "$1" "$5" | tr '\n' ' ')
  removed=${removed% }
  audit_append stopped "$2" "$1" "$3" "$6" "$4" "$removed" "$5" || true
  add_stopped "$2 pid $1 ($6)"
  STOPPED_PIDS="$STOPPED_PIDS $1"
}

stop_pending() {
  local pid class start why command waited=0 still status
  [ -n "$PENDING" ] || return 0
  while [ "$waited" -lt "$TERM_GRACE" ]; do
    sleep 1
    waited=$((waited + 1))
    still=
    while IFS=$'\t' read -r pid class start why command; do
      [ -n "$pid" ] || continue
      status=0
      identity_state "$pid" "$start" "$command" || status=$?
      if [ "$status" = 1 ]; then
        finish_stop "$pid" "$class" "$start" "$why" "$command" SIGTERM
      else
        still="$still$pid"$'\t'"$class"$'\t'"$start"$'\t'"$why"$'\t'"$command"$'\n'
      fi
    done <<<"$PENDING"
    PENDING=$still
    [ -n "$PENDING" ] || return 0
  done

  while IFS=$'\t' read -r pid class start why command; do
    [ -n "$pid" ] || continue
    signal_exact KILL "$pid" "$start" "$command" || true
  done <<<"$PENDING"

  waited=0
  while [ -n "$PENDING" ] && [ "$waited" -lt "$KILL_WAIT_SECS" ]; do
    sleep 1
    waited=$((waited + 1))
    still=
    while IFS=$'\t' read -r pid class start why command; do
      [ -n "$pid" ] || continue
      status=0
      identity_state "$pid" "$start" "$command" || status=$?
      if [ "$status" = 1 ]; then
        finish_stop "$pid" "$class" "$start" "$why" "$command" SIGKILL
      else
        still="$still$pid"$'\t'"$class"$'\t'"$start"$'\t'"$why"$'\t'"$command"$'\n'
      fi
    done <<<"$PENDING"
    PENDING=$still
  done

  while IFS=$'\t' read -r pid class start why command; do
    [ -n "$pid" ] || continue
    audit_append failed "$class" "$pid" "$start" SIGKILL "$why" '' "$command" || true
    look_once "$pid|$start|survived" "$class pid $pid could not be confirmed stopped after SIGKILL"
  done <<<"$PENDING"
  PENDING=
}

SWEEP_ROWS=

sweep_candidates() {
  local deadline pid ppid elapsed start command
  deadline=$(($(date +%s) + EVALUATE_SECS))
  # A copy, because evaluating and signalling each replace SNAP with a newer table.
  SWEEP_ROWS=$SNAP
  while IFS=$'\t' read -r pid ppid elapsed _ start command; do
    [ -n "$pid" ] || continue
    classify "$command" || continue
    [ "$(date +%s)" -lt "$deadline" ] || break
    if evaluate "$pid" "$ppid" "$elapsed" "$RUN_ID"; then
      if [ "$DRY_RUN" = 1 ]; then
        printf 'would stop: %s pid %s, age %s: %s\n' "$CLASS" "$pid" "$(human_age "$elapsed")" "$WHY"
      elif signal_exact TERM "$pid" "$start" "$command"; then
        PENDING="$PENDING$pid"$'\t'"$CLASS"$'\t'"$start"$'\t'"$WHY"$'\t'"$command"$'\n'
      fi
    else
      if [ "$DRY_RUN" = 1 ]; then
        printf 'would leave: %s pid %s, age %s: %s\n' "$CLASS" "$pid" "$(human_age "$elapsed")" "$WHY"
      fi
      # A process that exited mid-question answers nothing, and needs no look.
      if [ "$VERDICT" = unverified ] && identity_state "$pid" "$start" "$command"; then
        look_once "$pid|$start|unverified" "$CLASS pid $pid is orphaned but was left alone: $WHY"
      fi
    fi
  done <<<"$SWEEP_ROWS"
  stop_pending
}

action_check() {
  local now line text pid start secs command scan cpu_rows
  record_read
  now=$(record_epoch_now)
  if [ "$DRY_RUN" = 0 ] && [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$now" -ge "$RECORD_EPOCH" ] && [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    return 0
  fi

  if ! snapshot; then
    look_once "ps" "the process table could not be read, so nothing was swept"
    [ "$DRY_RUN" = 0 ] || return 0
    report_line
    [ -z "$REPORT_TEXT" ] || printf '%s\n' "$REPORT_TEXT"
    record_write "$(printf '%s%s' "$RECORD_SEEN" "$NEW_SEEN" | LC_ALL=C sort -u)" "$RECORD_CPU" || true
    return 0
  fi

  sweep_candidates

  snapshot || SNAP=$SWEEP_ROWS
  scan=$(hot_scan "$now" "$STOPPED_PIDS")
  cpu_rows=$(printf '%s\n' "$scan" | awk 'sub(/^cpu\t/, "")')
  while IFS=$'\t' read -r line pid start secs command; do
    [ "$line" = hot ] || continue
    text="${command:0:80} (pid $pid) has used over ${HOT_SHARE_PERCENT}% of a core for $(human_age "$secs"), left alone"
    look_once "$pid|$start|hot" "$text"
  done <<<"$scan"

  [ "$DRY_RUN" = 0 ] || return 0

  # Report before recording, so a record that cannot be written costs a repeated
  # report rather than a lost one.
  report_line
  [ -z "$REPORT_TEXT" ] || printf '%s\n' "$REPORT_TEXT"
  record_write "$(printf '%s%s' "$NEW_SEEN" "$(carried_seen_keys)" | LC_ALL=C sort -u)" "$cpu_rows" || true
  return 0
}

# --- arm and disarm ---------------------------------------------------------

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory. Settings present at arm time are embedded too.
shim_content() {  # <home>
  local name
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-orphan-sweep.sh - orphan process sweep poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$1")"
  for name in $SETTINGS; do
    [ -z "${!name:-}" ] || printf 'export %s=%q\n' "$name" "${!name}"
  done
  printf 'exec %q check\n' "$SCRIPT_DIR/fm-orphan-sweep.sh"
}

SHIM_TMP=
ARM_BACKUP=

fail() {
  printf 'fm-orphan-sweep: %s\n' "$1" >&2
  exit 1
}

shim_write() {  # <wanted-bytes> <state-device>
  local want=$1 device=$2
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  SHIM_TMP=$(umask 077; mktemp "$STATE/.orphan-sweep-shim.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$SHIM_TMP" \
    || ! chmod 0700 "$SHIM_TMP" \
    || ! fm_pr_private_file_valid "$SHIM_TMP" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$SHIM_TMP" "$CHECK_SHIM"; then
    rm -f -- "$SHIM_TMP"
    SHIM_TMP=
    return 1
  fi
  SHIM_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {  # <state-device>
  local device=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.orphan-sweep-shim.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

# An unregistered shim wakes firstmate on every cycle about an unauthenticated
# check, so a failed arm never leaves one behind.
arm_rollback() {
  [ -z "$SHIM_TMP" ] || rm -f -- "$SHIM_TMP"
  SHIM_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
}

arm_failed() {  # <message>
  trap - HUP INT TERM
  arm_rollback
  fail "$1"
}

action_arm() {
  local state_device home want
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unavailable"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || fail "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  state_device=$(fm_pr_file_device "$STATE") || fail "state directory is unavailable"
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup "$state_device") || fail "could not save the existing check shim"
  fi
  trap 'arm_failed "arming was interrupted"' HUP INT TERM
  shim_write "$want" "$state_device" || arm_failed "check shim path is unavailable"
  FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null || arm_failed "could not register the check shim"
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check)
    case "${2:-}" in
      '') [ "$#" -le 1 ] || die_usage "unexpected argument" ;;
      --dry-run) [ "$#" -eq 2 ] || die_usage "unexpected argument"; DRY_RUN=1 ;;
      *) die_usage "unknown option: $2" ;;
    esac
    action_check
    ;;
  --dry-run)
    [ "$#" -eq 1 ] || die_usage "unexpected argument"
    DRY_RUN=1
    action_check
    ;;
  arm)
    [ "$#" -eq 1 ] || die_usage "unexpected argument"
    action_arm
    ;;
  disarm)
    [ "$#" -eq 1 ] || die_usage "unexpected argument"
    action_disarm
    ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
