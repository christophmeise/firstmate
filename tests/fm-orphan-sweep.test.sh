#!/usr/bin/env bash
# Tests for fm-orphan-sweep.sh, the orphaned local process sweep.
#
# Every case runs against a faked process table: ps, lsof, sqlite3, and the
# external kill are PATH fakes reading files under the case's own directory, so
# no case can see or signal a real process on this host. The kill fake records
# each call and removes the row, which is how a case proves both what was
# signalled and that nothing else was.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-orphan-sweep.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-orphan-sweep)
MY_UID=$(id -u)
RUN=01M6NG9MYSZ2FVXZ0NAMPQ6YMT
EVIDENCE=/var/folders/xx/T/no-mistakes-evidence
LSTART='Thu Nov  5 10:00:00 2026'
BRIDGE_CMD='node /Users/me/.nvm/versions/node/v22/lib/node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js'
MYSQLD_CMD="/opt/homebrew/opt/mysql/bin/mysqld --no-defaults --datadir=$EVIDENCE/$RUN/mysql/data --socket=/tmp/nm1234.sock --skip-networking"

# new_world <name>: a home, an empty table, and the fakes. Sets W.
new_world() {
  W="$TMP_ROOT/$1"
  mkdir -p "$W/home/state" "$W/home/data" "$W/ps" "$W/lsof" "$W/runs" "$W/nm"
  : > "$W/nm/state.sqlite"
  : > "$W/kill.log"
  : > "$W/ps/1"
  mkdir -p "$W/fakebin"
  cat > "$W/fakebin/ps" <<'SH'
#!/usr/bin/env bash
# Only the sweep's whole-table read is faked; the watcher's own pid lookups
# reach the real ps.
[ "${1:-}" = -axww ] || exec /bin/ps "$@"
[ ! -e "$FAKE/ps.fail" ] || exit 1
n=$(cat "$FAKE/ps.count" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FAKE/ps.count"
[ ! -e "$FAKE/ps.fail.$n" ] || exit 1
while [ "$n" -gt 1 ] && [ ! -e "$FAKE/ps/$n" ]; do n=$((n - 1)); done
cat "$FAKE/ps/$n"
# A real table always holds at least the caller's own shell.
printf '     2      1 %5s  30-00:00:00    0:01.00   0.0 Thu Nov  5 10:00:00 2026 /bin/zsh\n' "$(id -u)"
SH
  cat > "$W/fakebin/kill" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/kill.log"
sig=$1 pid=$2
if [ "$sig" = -TERM ] && [ -e "$FAKE/ignore-term.$pid" ]; then exit 0; fi
for table in "$FAKE"/ps/*; do
  grep -Ev "^ *$pid " "$table" > "$table.tmp" || true
  mv "$table.tmp" "$table"
done
SH
  cat > "$W/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
pid=
while [ "$#" -gt 0 ]; do
  case "$1" in -p) pid=$2; shift ;; esac
  case "$1" in -d|-iTCP) mode=$1 ;; esac
  shift
done
[ ! -e "$FAKE/lsof/$pid.fail" ] || { echo "lsof: boom" >&2; exit 1; }
if [ "$mode" = -d ]; then
  [ -e "$FAKE/lsof/$pid.cwd" ] || exit 1
  printf 'p%s\nfcwd\nn%s\n' "$pid" "$(cat "$FAKE/lsof/$pid.cwd")"
  exit 0
fi
[ ! -e "$FAKE/lsof/$pid.tcp-fail" ] || { echo "lsof: boom" >&2; exit 1; }
[ -e "$FAKE/lsof/$pid.established" ] || exit 1
printf 'p%s\nf20\nn127.0.0.1:1->127.0.0.1:2\n' "$pid"
SH
  cat > "$W/fakebin/sqlite3" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FAKE/sqlite.fail" ] || exit 1
id=${3#*id=\'}
id=${id%%\'*}
[ ! -e "$FAKE/runs/$id" ] || cat "$FAKE/runs/$id"
SH
  chmod +x "$W"/fakebin/*
}

# row <table> <pid> <ppid> <etime> <time> <command> [uid]
row() {
  printf '%6s %6s %5s %12s %10s %5s %s %s\n' \
    "$2" "$3" "${7:-$MY_UID}" "$4" "$5" 0.0 "$LSTART" "$6" >> "$W/ps/$1"
}

# A finished run's database, orphaned, old, and quiet, and a bridge in the same
# state, which belongs to another owner and must never be signalled here.
orphan_mysqld() {  # <pid>
  row 1 "$1" 1 '22:00:00' '0:01.00' "$MYSQLD_CMD"
  printf '%s\n' /private/var/folders/xx/worktrees/gone > "$W/lsof/$1.cwd"
  printf '%s\n' completed > "$W/runs/$RUN"
}

orphan_bridge() {  # <pid>
  row 1 "$1" 1 '11-00:00:00' '0:01.00' "$BRIDGE_CMD"
  printf '%s\n' /Users/me/.treehouse/gone/1/scripe > "$W/lsof/$1.cwd"
}

sweep() {  # [args...]
  env PATH="$W/fakebin:$PATH" FAKE="$W" FM_HOME="$W/home" NM_HOME="$W/nm" \
    FM_ORPHAN_SWEEP_INTERVAL="${INTERVAL_OVERRIDE:-0}" FM_ORPHAN_SWEEP_TERM_GRACE=1 \
    ${NOW_OVERRIDE:+FM_ORPHAN_SWEEP_NOW="$NOW_OVERRIDE"} "$SWEEP" "$@"
}

killed() { cat "$W/kill.log"; }

assert_nothing_signalled() {  # <message>
  [ ! -s "$W/kill.log" ] || fail "$1: signalled $(killed)"
}

test_a_finished_runs_database_is_stopped_and_audited() {
  local out
  new_world mysqld
  orphan_mysqld 4001
  out=$(sweep check)
  assert_equals "-TERM 4001" "$(killed)" "the database was not stopped by exact pid"
  assert_contains "$out" "orphan sweep: stopped mysqld pid 4001 (SIGTERM)" "the stop was not reported"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the report was not one line"
  assert_contains "$(cat "$W/home/state/orphan-sweep.log")" "completed run $RUN" "the audit log does not say why"
  assert_contains "$(cat "$W/home/state/orphan-sweep.log")" "$MYSQLD_CMD" "the audit log does not say what"
  pass "a finished run's orphaned database is stopped, reported, and audited"
}

test_a_process_that_ignores_sigterm_gets_sigkill() {
  local out
  new_world stubborn
  orphan_mysqld 4002
  : > "$W/ignore-term.4002"
  out=$(sweep check)
  assert_equals $'-TERM 4002\n-KILL 4002' "$(killed)" "SIGKILL did not follow an ignored SIGTERM"
  assert_contains "$out" "mysqld pid 4002 (SIGKILL)" "the report does not say SIGKILL was needed"
  pass "a process that ignores SIGTERM is killed after the grace"
}

test_a_bridge_orphan_is_never_signalled() {
  local out
  new_world bridge
  orphan_bridge 4003
  out=$(sweep check)
  assert_equals "" "$out" "a bridge orphan was reported"
  assert_nothing_signalled "a bridge orphan"
  assert_absent "$W/home/state/orphan-sweep.log" "a bridge orphan reached the stop audit"
  assert_not_contains "$(sweep --dry-run)" "4003" "a dry run treated a bridge orphan as a candidate"
  pass "an old idle browser bridge is never signalled, because the reaper owns it"
}

test_a_clean_table_is_silent() {
  local out
  new_world quiet
  row 1 100 1 '30-00:00:00' '1:00.00' 'redis-server *:6379'
  out=$(sweep check)
  assert_equals "" "$out" "a sweep with nothing to do printed"
  assert_absent "$W/home/state/orphan-sweep.log" "a sweep that stopped nothing wrote the audit log"
  assert_nothing_signalled "a clean table"
  pass "a sweep that finds nothing is silent"
}

test_a_process_with_a_living_parent_is_refused() {
  local out
  new_world parented
  orphan_mysqld 4004
  sed -i.bak 's/^\( *4004 *\)1 /\1777 /' "$W/ps/1"
  rm -f "$W/ps/1.bak"
  out=$(sweep check)
  assert_equals "" "$out" "a parented process was reported"
  assert_nothing_signalled "a process with a living parent"
  pass "a process whose parent is alive is left alone"
}

test_a_young_database_is_refused() {
  local out
  new_world young
  row 1 4006 1 '01:59:00' '0:01.00' "$MYSQLD_CMD"
  printf '/gone\n' > "$W/lsof/4006.cwd"
  printf 'completed\n' > "$W/runs/$RUN"
  out=$(sweep check)
  assert_equals "" "$out" "a young database was reported"
  assert_nothing_signalled "a young database"
  pass "a database under its age threshold is left alone"
}

test_an_active_run_keeps_its_database() {
  local status out
  new_world activerun
  orphan_mysqld 4008
  for status in running pending; do
    printf '%s\n' "$status" > "$W/runs/$RUN"
    out=$(sweep check)
    assert_equals "" "$out" "an active run's database was reported for $status"
    assert_nothing_signalled "a $status run"
  done
  pass "an active run's database is left alone"
}

test_an_unanswerable_run_leaves_the_database_and_says_so_once() {
  local out
  new_world unknownrun
  orphan_mysqld 4009
  rm -f "$W/runs/$RUN"
  out=$(sweep check)
  assert_nothing_signalled "an unrecorded run"
  assert_contains "$out" "mysqld pid 4009 is orphaned but was left alone: status of run $RUN could not be read" \
    "an unverifiable orphan was not reported"
  assert_equals "" "$(sweep check)" "the unverifiable orphan was reported twice"

  new_world brokendb
  orphan_mysqld 4010
  : > "$W/sqlite.fail"
  out=$(sweep check)
  assert_nothing_signalled "an unreadable database"
  assert_contains "$out" "left alone" "an unreadable run database was not reported"

  new_world weirdstatus
  orphan_mysqld 4011
  printf 'fixing\n' > "$W/runs/$RUN"
  sweep check >/dev/null
  assert_nothing_signalled "an unknown run status"
  pass "a run status that cannot be answered leaves the database alone"
}

test_a_live_task_in_this_home_keeps_its_process() {
  local out
  new_world livetask
  mkdir -p "$W/worktree/sub"
  orphan_mysqld 4012
  (cd "$W/worktree/sub" && pwd -P) > "$W/lsof/4012.cwd"
  printf 'kind=ship\nworktree=%s\ntasktmp=/tmp/nope\n' "$W/worktree" > "$W/home/state/some-task-t1.meta"
  out=$(sweep check)
  assert_equals "" "$out" "a live task's database was reported"
  assert_nothing_signalled "a live task's database"

  rm -f "$W/home/state/some-task-t1.meta"
  sweep check >/dev/null
  assert_equals "-TERM 4012" "$(killed)" "the same database was not stopped once its task was gone"
  pass "a process in a live task's worktree is left alone"
}

test_a_live_task_in_another_home_keeps_its_process() {
  local child out
  new_world otherhome
  child="$W/mate"
  mkdir -p "$child/state" "$W/worktree"
  printf -- '- mate-a - Second mate (home: %s; scope: all; projects: none; added 2026-01-01)\n' "$child" \
    > "$W/home/data/secondmates.md"
  printf 'worktree=/nope\ntasktmp=%s\n' "$W/worktree" > "$child/state/other-task-t1.meta"
  orphan_mysqld 4013
  (cd "$W/worktree" && pwd -P) > "$W/lsof/4013.cwd"
  out=$(sweep check)
  assert_equals "" "$out" "another home's task process was reported"
  assert_nothing_signalled "another home's task process"
  pass "a process tied to a task in another local home is left alone"
}

test_an_unreadable_home_registry_leaves_everything_alone() {
  local out
  new_world badregistry
  printf -- '- not a valid record\n' > "$W/home/data/secondmates.md"
  orphan_mysqld 4014
  out=$(sweep check)
  assert_nothing_signalled "an unreadable home registry"
  assert_contains "$out" "left alone" "a blind sweep was silent"
  pass "live tasks that cannot be enumerated leave every candidate alone"
}

# A home can run older code than this script expects. Losing either library
# function must cost the sweep its candidates, never its safety check.
test_missing_liveness_libraries_leave_everything_alone() {
  local out SWEEP
  new_world oldlibs
  mkdir -p "$W/code"
  cp -R "$ROOT/bin" "$W/code/bin"
  printf 'unset -f fm_local_firstmate_state_dirs\n' >> "$W/code/bin/fm-wake-lib.sh"
  SWEEP="$W/code/bin/fm-orphan-sweep.sh"
  orphan_mysqld 4041
  out=$(sweep check 2>/dev/null)
  assert_nothing_signalled "a home whose libraries cannot list live tasks"
  assert_contains "$out" "live tasks could not be listed" "a blind sweep was silent"

  new_world oldlibs-run
  mkdir -p "$W/code"
  cp -R "$ROOT/bin" "$W/code/bin"
  printf 'unset -f fm_nm_state_db fm_nm_run_status_class\n' >> "$W/code/bin/fm-nm-run-lib.sh"
  SWEEP="$W/code/bin/fm-orphan-sweep.sh"
  orphan_mysqld 4042
  out=$(sweep check 2>/dev/null)
  assert_nothing_signalled "a home whose libraries cannot read a run's status"
  assert_contains "$out" "could not be read" "a blind sweep was silent"
  pass "older libraries that cannot answer leave every candidate alone"
}

test_a_connected_database_is_refused() {
  local out
  new_world dbconn
  orphan_mysqld 4017
  : > "$W/lsof/4017.established"
  out=$(sweep check)
  assert_equals "" "$out" "a connected database was reported"
  assert_nothing_signalled "a connected database"
  pass "a database with an established connection is left alone"
}

test_an_unreadable_process_is_refused() {
  local out
  new_world nolsof
  orphan_mysqld 4018
  : > "$W/lsof/4018.fail"
  out=$(sweep check)
  assert_nothing_signalled "a process lsof cannot read"
  assert_contains "$out" "working directory could not be read" "the blind spot was not reported"
  pass "a process whose working directory cannot be read is left alone"
}

# One candidate that every other check would stop, so the refusal under test is
# the only thing between it and a signal.
assert_refused_with_one_line() {  # <pid> <reason>
  local out
  out=$(sweep check)
  assert_nothing_signalled "$2"
  assert_contains "$out" "mysqld pid $1 is orphaned but was left alone: $2" "the refusal was not reported"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the refusal was not one line"
}

test_unreadable_connections_are_refused() {
  new_world notcp
  orphan_mysqld 4043
  : > "$W/lsof/4043.tcp-fail"
  assert_refused_with_one_line 4043 "connections could not be read"
  pass "a process whose connections cannot be read is left alone"
}

test_a_table_lost_before_the_signal_sends_nothing() {
  new_world nosignal
  orphan_mysqld 4044
  : > "$W/ps.fail.2"
  sweep check >/dev/null
  assert_nothing_signalled "a pid whose identity could not be re-verified"
  pass "a table lost right before SIGTERM sends nothing"
}

test_unreadable_task_records_are_refused() {
  local child
  if [ "$MY_UID" = 0 ]; then
    pass "unreadable task records need a non-root user (skipped)"
    return 0
  fi
  new_world badmeta
  orphan_mysqld 4045
  : > "$W/home/state/some-task-t1.meta"
  chmod 000 "$W/home/state/some-task-t1.meta"
  assert_refused_with_one_line 4045 "task record is unreadable at $W/home/state/some-task-t1.meta"
  chmod 600 "$W/home/state/some-task-t1.meta"

  new_world badstate
  child="$W/mate"
  mkdir -p "$child/state"
  printf -- '- mate-a - Second mate (home: %s; scope: all; projects: none; added 2026-01-01)\n' "$child" \
    > "$W/home/data/secondmates.md"
  orphan_mysqld 4046
  chmod 000 "$child/state"
  assert_refused_with_one_line 4046 "task records are unreadable at $child/state"
  chmod 700 "$child/state"
  pass "a task record or state directory that cannot be read leaves every candidate alone"
}

test_only_the_allowlist_can_be_stopped() {
  local out pid=5000 command
  new_world allowlist
  printf 'completed\n' > "$W/runs/$RUN"
  while IFS= read -r command; do
    pid=$((pid + 1))
    row 1 "$pid" 1 '30-00:00:00' '0:01.00' "$command"
    printf '/gone\n' > "$W/lsof/$pid.cwd"
  done <<EOF
redis-server *:6379
/usr/local/bin/no-mistakes daemon run --root /Users/me/.no-mistakes
/Users/me/.nvm/bin/node /Users/me/.nvm/lib/node_modules/lavish-axi/dist/cli.mjs server
/opt/homebrew/opt/mysql/bin/mysqld --datadir=/opt/homebrew/var/mysql
/opt/homebrew/opt/mysql/bin/mysqld --datadir=/tmp/no-mistakes-evidence/not-a-run/mysql/data
/opt/homebrew/opt/mysql/bin/mysqld --datadir=$EVIDENCE/$RUN/mysql/data --datadir=/other
/opt/homebrew/opt/mysql/bin/mysqld_safe --datadir=$EVIDENCE/$RUN/mysql/data
$BRIDGE_CMD --extra
node /tmp/chrome-devtools-axi-bridge.js
vim $BRIDGE_CMD
/Applications/Mail.app/Contents/MacOS/Mail
EOF
  row 1 6000 1 '30-00:00:00' '0:01.00' "$MYSQLD_CMD" 12345
  out=$(sweep check)
  assert_equals "" "$out" "a process off the allowlist was reported"
  assert_nothing_signalled "a process off the allowlist"
  pass "nothing off the allowlist, and nothing of another user, can be stopped"
}

test_a_reused_pid_is_never_signalled() {
  local out
  new_world reuse-start
  orphan_mysqld 4019
  sed 's/Thu Nov  5 10:00:00 2026/Fri Nov  6 09:00:00 2026/' "$W/ps/1" > "$W/ps/2"
  out=$(sweep check)
  assert_nothing_signalled "a pid with a new start time"
  assert_equals "" "$out" "a skipped pid was reported as stopped"

  new_world reuse-command
  orphan_mysqld 4020
  sed 's#--skip-networking#--skip-networking --port=3307#' "$W/ps/1" > "$W/ps/2"
  sweep check >/dev/null
  assert_nothing_signalled "a pid with a new command"

  new_world reuse-parent
  orphan_mysqld 4021
  sed 's/^\( *4021 *\)1 /\1999 /' "$W/ps/1" > "$W/ps/2"
  sweep check >/dev/null
  assert_nothing_signalled "a pid that gained a parent"
  pass "pid identity is re-verified before SIGTERM"
}

test_a_pid_reused_during_the_grace_gets_no_sigkill() {
  new_world reuse-grace
  orphan_mysqld 4022
  : > "$W/ignore-term.4022"
  cp "$W/ps/1" "$W/ps/2"
  sed 's/Thu Nov  5 10:00:00 2026/Fri Nov  6 09:00:00 2026/' "$W/ps/1" > "$W/ps/3"
  sweep check >/dev/null
  assert_equals "-TERM 4022" "$(killed)" "SIGKILL reached a pid that had been reused"
  pass "pid identity is re-verified before SIGKILL"
}

test_the_interval_gate_holds_whatever_the_cadence() {
  local out
  new_world gate
  INTERVAL_OVERRIDE=1800
  NOW_OVERRIDE=1000000
  sweep check >/dev/null
  orphan_mysqld 4023
  NOW_OVERRIDE=1001799
  out=$(sweep check)
  assert_equals "" "$out" "a sweep ran inside the interval"
  assert_nothing_signalled "a gated sweep"
  NOW_OVERRIDE=1001800
  sweep check >/dev/null
  assert_equals "-TERM 4023" "$(killed)" "the sweep did not run once the interval passed"
  NOW_OVERRIDE=
  INTERVAL_OVERRIDE=
  pass "a sweep runs at most once per interval"
}

test_the_default_interval_is_thirty_minutes() {
  new_world gatedefault
  env PATH="$W/fakebin:$PATH" FAKE="$W" FM_HOME="$W/home" NM_HOME="$W/nm" FM_ORPHAN_SWEEP_NOW=1000000 "$SWEEP" check
  orphan_mysqld 4024
  env PATH="$W/fakebin:$PATH" FAKE="$W" FM_HOME="$W/home" NM_HOME="$W/nm" FM_ORPHAN_SWEEP_NOW=1001799 "$SWEEP" check
  assert_nothing_signalled "the default gate"
  pass "the default interval is 30 minutes"
}

test_a_hot_unknown_process_is_reported_once_and_untouched() {
  local out
  new_world hot
  row 1 7001 500 '03:00:00' '170:00.00' '/usr/local/bin/python3 crunch.py'
  out=$(sweep check)
  assert_contains "$out" "/usr/local/bin/python3 crunch.py (pid 7001) has used over 80% of a core" "a hot process was not reported"
  assert_nothing_signalled "a hot process"
  assert_equals "" "$(sweep check)" "a hot process was reported twice"
  assert_absent "$W/home/state/orphan-sweep.log" "a report-only finding reached the stop audit"
  pass "a hot unknown process gets one line and no action"
}

test_cpu_is_measured_between_sweeps() {
  local out
  new_world hotsample
  # Idle for a day, so its lifetime average says nothing about the last hours.
  row 1 7002 500 '1-00:00:00' '10:00.00' '/usr/local/bin/node spin.js'
  NOW_OVERRIDE=2000000
  assert_equals "" "$(sweep check)" "an idle process was reported"
  : > "$W/ps/1"
  row 1 7002 500 '1-00:30:00' '38:00.00' '/usr/local/bin/node spin.js'
  NOW_OVERRIDE=2001800
  assert_equals "" "$(sweep check)" "a process hot for only half an hour was reported"
  : > "$W/ps/1"
  row 1 7002 500 '1-01:00:00' '66:00.00' '/usr/local/bin/node spin.js'
  NOW_OVERRIDE=2003600
  out=$(sweep check)
  assert_contains "$out" "(pid 7002) has used over 80% of a core for 1h" "an hour of sampled load was not reported"
  : > "$W/ps/1"
  row 1 7002 500 '1-01:30:00' '67:00.00' '/usr/local/bin/node spin.js'
  NOW_OVERRIDE=2005400
  assert_equals "" "$(sweep check)" "a cooled process was reported"
  : > "$W/ps/1"
  row 1 7002 500 '1-03:00:00' '150:00.00' '/usr/local/bin/node spin.js'
  NOW_OVERRIDE=2010800
  assert_equals "" "$(sweep check)" "a process that dipped and returned was reported a second time"
  NOW_OVERRIDE=
  pass "CPU use is measured between sweeps and reported once per process"
}

test_system_and_cool_processes_are_not_reported() {
  local out
  new_world coolproc
  row 1 7003 1 '05:00:00' '280:00.00' '/System/Library/PrivateFrameworks/x.framework/photoanalysisd'
  row 1 7004 1 '05:00:00' '60:00.00' '/usr/local/bin/python3 mostly-idle.py'
  row 1 7005 1 '00:30:00' '29:00.00' '/usr/local/bin/python3 just-started.py'
  out=$(sweep check)
  assert_equals "" "$out" "a system, cool, or brief process was reported"
  pass "operating-system paths and processes under the threshold are not reported"
}

test_a_refused_hot_orphan_still_gets_a_look() {
  local out
  new_world hotrefused
  row 1 4025 1 '22:00:00' '1300:00.00' "$MYSQLD_CMD"
  printf '/gone\n' > "$W/lsof/4025.cwd"
  printf 'running\n' > "$W/runs/$RUN"
  out=$(sweep check)
  assert_nothing_signalled "a hot database of a recorded running run"
  assert_contains "$out" "(pid 4025) has used over 80% of a core" "a stuck hot database was not surfaced"
  pass "a hot orphan the sweep may not stop is still surfaced"
}

test_reports_over_the_line_cap_wait_for_a_later_sweep() {
  local pid out all='' sweeps=0 count
  new_world hotflood
  for pid in $(seq 7100 7119); do
    row 1 "$pid" 500 '03:00:00' '170:00.00' "/usr/local/bin/python3 /opt/jobs/a-long-worker-path/crunch-$pid.py --with-a-long-argument"
  done
  out=$(sweep check)
  while [ -n "$out" ]; do
    sweeps=$((sweeps + 1))
    [ "$sweeps" -le 6 ] || fail "the reports never drained"
    assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "a report was not one line"
    [ "${#out}" -le 1000 ] || fail "a report ran to ${#out} characters"
    all="$all$out"$'\n'
    out=$(sweep check)
  done
  [ "$sweeps" -ge 2 ] || fail "the table did not overflow the cap, so this proves nothing"
  for pid in $(seq 7100 7119); do
    count=$(printf '%s' "$all" | grep -oF "(pid $pid) has used over 80% of a core for 3h, left alone" | wc -l | tr -d ' ')
    assert_equals 1 "$count" "pid $pid was not reported whole exactly once"
  done
  assert_equals 20 "$(printf '%s' "$all" | grep -oF 'left alone' | wc -l | tr -d ' ')" "an entry was reported more than once"
  assert_nothing_signalled "a table of hot processes"
  pass "reports over the line cap arrive whole on later sweeps, each exactly once"
}

test_an_entry_longer_than_the_cap_is_reported_once_shortened() {
  local out long
  new_world longentry
  long=/$(awk 'BEGIN { for (i = 0; i < 1200; i++) printf "a" }')
  printf -- '- mate-a - Second mate (home: %s; scope: all; projects: none; added 2026-01-01)\n' "$long" \
    > "$W/home/data/secondmates.md"
  orphan_mysqld 4047
  out=$(sweep check)
  assert_nothing_signalled "an unavailable home"
  assert_contains "$out" "mysqld pid 4047 is orphaned but was left alone" "an entry too long for any line was never reported"
  [ "${#out}" -le 1000 ] || fail "the report ran to ${#out} characters"
  assert_equals "" "$(sweep check)" "the shortened entry was reported twice"
  pass "an entry too long for any line is shortened and reported once"
}

test_a_stop_keeps_the_line_and_the_reports_it_leaves_no_room_for_wait() {
  local pid out next waiting=
  new_world stopflood
  orphan_mysqld 4048
  for pid in $(seq 7200 7219); do
    row 1 "$pid" 500 '03:00:00' '170:00.00' "/usr/local/bin/python3 /opt/jobs/a-long-worker-path/crunch-$pid.py --with-a-long-argument"
  done
  out=$(sweep check)
  assert_equals "-TERM 4048" "$(killed)" "the database was not stopped"
  assert_contains "$out" "orphan sweep: stopped mysqld pid 4048 (SIGTERM); look: " "the stop did not lead the line"
  [ "${#out}" -le 1000 ] || fail "the report ran to ${#out} characters"
  assert_contains "$out" ", left alone" "the stop left no report on the line"
  case "$out" in
    *', left alone') ;;
    *) fail "the line ended on a cut entry: $out" ;;
  esac
  for pid in $(seq 7200 7219); do
    case "$out" in
      *"(pid $pid)"*) ;;
      *) waiting=$pid; break ;;
    esac
  done
  [ -n "$waiting" ] || fail "the table did not overflow the cap, so this proves nothing"
  next=$(sweep check)
  assert_not_contains "$next" "stopped" "the stop was reported again"
  assert_contains "$next" "(pid $waiting)" "a report that did not fit beside the stop was lost"
  pass "a stop leads the line and reports that do not fit beside it wait"
}

test_owned_files_are_removed_only_when_safe() {
  local data sock pidfile
  new_world cleanup
  data="$W/evidence/no-mistakes-evidence/$RUN/mysql/data"
  mkdir -p "$data"
  sock="/tmp/nmfmtest$$.sock"
  pidfile="$data/host.pid"
  perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die' "$sock"
  printf '4026\n' > "$sock.lock"
  printf '4026\n' > "$pidfile"
  printf 'row\n' > "$data/ibdata1"
  row 1 4026 1 '22:00:00' '0:01.00' "/usr/bin/mysqld --datadir=$data --socket=$sock --pid-file=$pidfile"
  printf '/gone\n' > "$W/lsof/4026.cwd"
  printf 'failed\n' > "$W/runs/$RUN"
  sweep check >/dev/null
  assert_equals "-TERM 4026" "$(killed)" "the database was not stopped"
  assert_absent "$sock" "the stale socket stayed"
  assert_absent "$sock.lock" "the stale socket lock stayed"
  assert_absent "$pidfile" "the stale pid file stayed"
  assert_present "$data/ibdata1" "evidence was deleted"
  assert_contains "$(cat "$W/home/state/orphan-sweep.log")" "$sock" "the audit does not list the removed socket"
  pass "a stopped database's socket and pid files are removed and its evidence is kept"
}

# The exact shape of the process from the incident: a bare argv[0], a $TMPDIR
# ending in a slash that doubles the separator, a TCP port, and both the socket
# and the pid file directly under /tmp rather than in the data directory.
test_the_incident_command_line_is_matched_and_cleaned_up() {
  local sock pidfile command out
  new_world incident
  sock="/tmp/nmfmtest$$i.sock"
  pidfile="/tmp/nmfmtest$$i.pid"
  command="mysqld --no-defaults --datadir=/var/folders/ds/xx/T//no-mistakes-evidence/$RUN/mysql/data --port=33119 --bind-address=127.0.0.1 --mysqlx=OFF --socket=$sock --pid-file=$pidfile --daemonize"
  perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die' "$sock"
  printf '4040\n' > "$sock.lock"
  printf '4040\n' > "$pidfile"
  row 1 4040 1 '22:00:00' '1320:00.00' "$command"
  printf '/var/folders/ds/xx/T/no-mistakes-evidence/%s/mysql/data\n' "$RUN" > "$W/lsof/4040.cwd"
  printf 'completed\n' > "$W/runs/$RUN"
  : > "$W/ignore-term.4040"
  out=$(sweep check)
  assert_equals $'-TERM 4040\n-KILL 4040' "$(killed)" "the incident process was not stopped by SIGTERM then SIGKILL"
  assert_contains "$out" "stopped mysqld pid 4040 (SIGKILL)" "the stop was not reported"
  assert_not_contains "$out" "of a core" "a stopped process was also reported as hot"
  assert_absent "$sock" "the incident socket stayed"
  assert_absent "$sock.lock" "the incident socket lock stayed"
  assert_absent "$pidfile" "the incident pid file stayed"
  pass "the incident's exact command line is matched, stopped, and cleaned up"
}

test_files_it_cannot_prove_it_owned_stay() {
  local data
  new_world cleanup-refusals
  data="$W/evidence/no-mistakes-evidence/$RUN/mysql/data"
  mkdir -p "$data"
  printf 'not a socket\n' > "$W/plain.sock"
  printf '9999\n' > "$data/other.pid"
  ln -s "$W/plain.sock" "$data/link.sock"
  row 1 4027 1 '22:00:00' '0:01.00' "/usr/bin/mysqld --datadir=$data --socket=$data/link.sock --pid-file=$data/other.pid"
  printf '/gone\n' > "$W/lsof/4027.cwd"
  printf 'cancelled\n' > "$W/runs/$RUN"
  sweep check >/dev/null
  assert_present "$data/other.pid" "a pid file recording another pid was removed"
  assert_present "$W/plain.sock" "a symlink target was removed"
  [ -L "$data/link.sock" ] || fail "a symlinked socket path was removed"

  new_world cleanup-shared
  data="$W/evidence/no-mistakes-evidence/$RUN/mysql/data"
  mkdir -p "$data"
  printf '4028\n' > "$data/host.pid"
  row 1 4028 1 '22:00:00' '0:01.00' "/usr/bin/mysqld --datadir=$data --pid-file=$data/host.pid"
  row 1 4029 500 '22:00:00' '0:01.00' "/usr/local/bin/tail -f $data/host.pid"
  printf '/gone\n' > "$W/lsof/4028.cwd"
  printf 'completed\n' > "$W/runs/$RUN"
  sweep check >/dev/null
  assert_equals "-TERM 4028" "$(killed)" "the database was not stopped"
  assert_present "$data/host.pid" "a file named by another live process was removed"
  pass "files that are not provably the stopped process's stay"
}

test_the_audit_log_is_capped() {
  local size
  new_world auditcap
  awk 'BEGIN { for (i = 0; i < 2000; i++) printf "2026-01-01T00:00:00Z\tstopped\tmysqld\t%d\tx\tSIGTERM\twhy\t\tcmd padding padding padding\n", i }' \
    > "$W/home/state/orphan-sweep.log"
  orphan_mysqld 4030
  sweep check >/dev/null
  size=$(wc -c < "$W/home/state/orphan-sweep.log" | tr -d ' ')
  [ "$size" -le 65536 ] || fail "the audit log grew to $size bytes"
  assert_contains "$(tail -1 "$W/home/state/orphan-sweep.log")" "4030" "the newest entry was dropped"
  assert_contains "$(head -1 "$W/home/state/orphan-sweep.log")" "2026-01-01T00:00:00Z" "the cut left a partial line"
  pass "the audit log stays under its cap and keeps the newest entries"
}

test_dry_run_changes_nothing_and_ignores_the_gate() {
  local out before
  new_world dryrun
  orphan_mysqld 4031
  orphan_mysqld 4032
  row 1 4033 1 '01:00:00' '0:01.00' "$MYSQLD_CMD"
  row 1 7006 500 '03:00:00' '170:00.00' '/usr/local/bin/python3 crunch.py'
  NOW_OVERRIDE=3000000
  INTERVAL_OVERRIDE=1800
  sweep check >/dev/null
  : > "$W/kill.log"
  rm -f "$W/ps.count"
  : > "$W/ps/1"
  orphan_mysqld 4031
  orphan_mysqld 4032
  row 1 4033 1 '01:00:00' '0:01.00' "$MYSQLD_CMD"
  row 1 7007 500 '03:00:00' '170:00.00' '/usr/local/bin/python3 other.py'
  before=$(cat "$W/home/state/.orphan-sweep")
  out=$(sweep --dry-run)
  assert_contains "$out" "would stop: mysqld pid 4031" "the dry run does not name the database"
  assert_contains "$out" "would stop: mysqld pid 4032" "the dry run does not name every database"
  assert_contains "$out" "would leave: mysqld pid 4033" "the dry run does not name what it leaves"
  assert_contains "$out" "would report: /usr/local/bin/python3 other.py" "the dry run does not name a report"
  assert_contains "$(sweep check --dry-run)" "would stop: mysqld pid 4031" "check --dry-run differs"
  assert_nothing_signalled "a dry run"
  assert_equals "$before" "$(cat "$W/home/state/.orphan-sweep")" "a dry run changed the record"
  NOW_OVERRIDE=
  INTERVAL_OVERRIDE=
  pass "a dry run prints its verdicts, ignores the gate, and changes nothing"
}

test_an_unreadable_process_table_stops_nothing_and_says_so_once() {
  local out
  new_world psfail
  orphan_mysqld 4034
  : > "$W/ps.fail"
  out=$(sweep check)
  assert_contains "$out" "process table could not be read" "a blind sweep was silent"
  assert_equals "" "$(sweep check)" "a standing failure was reported twice"
  assert_nothing_signalled "an unreadable table"
  pass "an unreadable process table stops nothing and is reported once"
}

test_invalid_settings_and_actions_refuse() {
  local name value status
  new_world invalid
  while read -r name value; do
    status=0
    env FM_HOME="$W/home" "$name=$value" "$SWEEP" check >/dev/null 2>&1 || status=$?
    expect_code 2 "$status" "$name=$value"
  done <<EOF
FM_ORPHAN_SWEEP_INTERVAL 30
FM_ORPHAN_SWEEP_INTERVAL soon
FM_ORPHAN_SWEEP_MYSQLD_MIN_AGE 0
FM_ORPHAN_SWEEP_TERM_GRACE 0
FM_ORPHAN_SWEEP_TERM_GRACE 61
EOF
  status=0
  FM_HOME="$W/home" "$SWEEP" nonsense >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown action"
  status=0
  FM_HOME="$W/home" "$SWEEP" check --force >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown option"
  assert_contains "$("$SWEEP" --help)" "fm-orphan-sweep.sh arm" "--help did not print usage"
  pass "invalid settings and actions refuse"
}

test_arm_registers_and_disarm_keeps_the_audit() {
  new_world arm
  FM_HOME="$W/home" FM_ORPHAN_SWEEP_INTERVAL=3600 "$SWEEP" arm >/dev/null || fail "arm failed"
  assert_present "$W/home/state/orphan-sweep.check.sh" "arm wrote no shim"
  assert_present "$W/home/state/orphan-sweep.check-trust" "arm wrote no trust binding"
  assert_contains "$(cat "$W/home/state/orphan-sweep.check.sh")" "FM_ORPHAN_SWEEP_INTERVAL=3600" "the interval override did not reach the shim"
  printf 'kept\n' > "$W/home/state/orphan-sweep.log"
  : > "$W/home/state/.orphan-sweep"
  FM_HOME="$W/home" "$SWEEP" disarm >/dev/null || fail "disarm failed"
  assert_absent "$W/home/state/orphan-sweep.check.sh" "disarm left the shim"
  assert_absent "$W/home/state/orphan-sweep.check-trust" "disarm left the trust binding"
  assert_absent "$W/home/state/.orphan-sweep" "disarm left the record"
  assert_present "$W/home/state/orphan-sweep.log" "disarm removed the audit log"
  pass "arm binds the shim and disarm removes it but keeps the audit"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local status=0
  new_world armlink
  printf 'keep\n' > "$W/target"
  ln -s "$W/target" "$W/home/state/orphan-sweep.check.sh"
  FM_HOME="$W/home" "$SWEEP" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm over a symlink"
  assert_equals keep "$(cat "$W/target")" "arm wrote through a symlink"
  pass "arm refuses a symlink at the shim path"
}

test_armed_check_wakes_the_watcher() {
  local status=0
  new_world wake
  orphan_mysqld 4035
  FM_HOME="$W/home" "$SWEEP" arm >/dev/null || fail "could not arm the sweep"
  env FM_HOME="$W/home" NM_HOME="$W/nm" FAKE="$W" PATH="$W/fakebin:$PATH" FM_CHECK_TIMEOUT=30 \
    FM_ORPHAN_SWEEP_TERM_GRACE=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 60 >"$W/out.txt" 2>"$W/err.txt" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$W/out.txt")" "check:" "the armed sweep did not reach the watcher as a check wake"
  assert_contains "$(cat "$W/out.txt")" "orphan sweep: stopped mysqld pid 4035" "the wake did not carry the sweep line"
  pass "the armed sweep reaches the watcher as an ordinary check wake"
}

test_a_finished_runs_database_is_stopped_and_audited
test_a_process_that_ignores_sigterm_gets_sigkill
test_a_bridge_orphan_is_never_signalled
test_a_clean_table_is_silent
test_a_process_with_a_living_parent_is_refused
test_a_young_database_is_refused
test_an_active_run_keeps_its_database
test_an_unanswerable_run_leaves_the_database_and_says_so_once
test_a_live_task_in_this_home_keeps_its_process
test_a_live_task_in_another_home_keeps_its_process
test_an_unreadable_home_registry_leaves_everything_alone
test_missing_liveness_libraries_leave_everything_alone
test_a_connected_database_is_refused
test_an_unreadable_process_is_refused
test_unreadable_connections_are_refused
test_a_table_lost_before_the_signal_sends_nothing
test_unreadable_task_records_are_refused
test_only_the_allowlist_can_be_stopped
test_a_reused_pid_is_never_signalled
test_a_pid_reused_during_the_grace_gets_no_sigkill
test_the_interval_gate_holds_whatever_the_cadence
test_the_default_interval_is_thirty_minutes
test_a_hot_unknown_process_is_reported_once_and_untouched
test_cpu_is_measured_between_sweeps
test_system_and_cool_processes_are_not_reported
test_a_refused_hot_orphan_still_gets_a_look
test_reports_over_the_line_cap_wait_for_a_later_sweep
test_an_entry_longer_than_the_cap_is_reported_once_shortened
test_a_stop_keeps_the_line_and_the_reports_it_leaves_no_room_for_wait
test_owned_files_are_removed_only_when_safe
test_the_incident_command_line_is_matched_and_cleaned_up
test_files_it_cannot_prove_it_owned_stay
test_the_audit_log_is_capped
test_dry_run_changes_nothing_and_ignores_the_gate
test_an_unreadable_process_table_stops_nothing_and_says_so_once
test_invalid_settings_and_actions_refuse
test_arm_registers_and_disarm_keeps_the_audit
test_arm_refuses_a_symlink_at_the_shim_path
test_armed_check_wakes_the_watcher
