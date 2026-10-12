#!/usr/bin/env bash
# Behavior tests for bin/fm-automation-browser-reap.sh.
#
# The leak this pins: headless automation Chromes outliving their task. A
# chrome-devtools-axi bridge is a detached daemon that never exits and is often
# started outside the task worktree, and a puppeteer port-mode Chrome is
# reparented to init when its node driver is killed. Observed 2026-10-12 as
# several such Chromes, 2-4 days old, spinning at 100-200% CPU.
#
# Sweep mode is machine-wide by design, so sweep cases run --dry-run and assert
# only about their own fixture processes. Real stopping is exercised through
# task mode, which only ever reaches bridges carrying this suite's own marker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-automation-browser-reap)
REAPER="$ROOT/bin/fm-automation-browser-reap.sh"

# Fixtures are started inside command substitutions, so their pids go to a
# file the EXIT trap reads rather than to an array the subshell would lose.
TRACKED="$TMP_ROOT/tracked-pids"
: > "$TRACKED"
track() { printf '%s\n' "$1" >> "$TRACKED"; }
reap_test_cleanup() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done < "$TRACKED"
  rm -rf "/tmp/fm-fmabtest-$$-gone" "/tmp/fm-fmabtest-$$-live"
  fm_test_cleanup
}
trap reap_test_cleanup EXIT

alive() { kill -0 "$1" 2>/dev/null; }

wait_gone() { # <pid> <seconds>
  local pid=$1 deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    alive "$pid" || return 0
    sleep 0.1
  done
  ! alive "$pid"
}

# A stand-in browser binary at <path>: a shell script, so its command line is
# "/bin/sh <path> <args>" and keeps the binary basename the matcher reads.
make_binary() { # <path>
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\nsleep 300 &\nwait\n' > "$1"
  chmod +x "$1"
}

CHROME="$TMP_ROOT/Google Chrome.app/Contents/MacOS/Google Chrome"
DIA="$TMP_ROOT/Dia.app/Contents/MacOS/Dia"
make_binary "$CHROME"
make_binary "$DIA"

# Start <cmd...> from a subshell that exits at once, so the process is
# reparented exactly as a browser whose driver died is; echo its pid.
start_orphan() {
  local pidfile pid
  pidfile=$(mktemp "$TMP_ROOT/pid.XXXXXX")
  ( "$@" </dev/null >/dev/null 2>&1 & printf '%s\n' "$!" > "$pidfile" )
  pid=$(cat "$pidfile")
  track "$pid"
  printf '%s\n' "$pid"
}

# Fail unless <pid> reached the reaper's own orphan definition: init, or a
# `systemd --user` subreaper.
require_orphaned() { # <pid> <label>
  local deadline=$(( $(date +%s) + 5 )) parent
  while [ "$(date +%s)" -lt "$deadline" ]; do
    parent=$(ps -p "$1" -o ppid= 2>/dev/null | tr -d '[:space:]')
    [ "$parent" = 1 ] && return 0
    case "$(ps -ww -p "$parent" -o command= 2>/dev/null)" in *"systemd --user"*) return 0 ;; esac
    sleep 0.1
  done
  fail "$2: fixture was adopted by pid $parent ($(ps -ww -p "$parent" -o command= 2>/dev/null)), not init or a systemd --user subreaper"
}

listed() { # <output> <pid>
  case "$1" in *" $2 ("*) return 0 ;; esac
  return 1
}

test_orphan_matcher() {
  local out automation puppeteer captain captain_profile captain_debug dia helper attached
  automation=$(start_orphan "$CHROME" --allow-pre-commit-input --enable-automation --headless=new --remote-debugging-port=0)
  puppeteer=$(start_orphan "$CHROME" --headless=new "--user-data-dir=/tmp/puppeteer_dev_chrome_profile-AbC123")
  captain=$(start_orphan "$CHROME")
  captain_profile=$(start_orphan "$CHROME" --profile-directory=Default "--user-data-dir=$HOME/Library/Application Support/Google/Chrome")
  captain_debug=$(start_orphan "$CHROME" --remote-debugging-port=9222)
  dia=$(start_orphan "$DIA" --enable-automation)
  helper=$(start_orphan "$CHROME" --type=renderer --enable-automation)
  "$CHROME" --enable-automation --headless=new </dev/null >/dev/null 2>&1 &
  attached=$!
  track "$attached"
  for pid in "$automation" "$puppeteer" "$captain" "$captain_profile" "$captain_debug" "$dia" "$helper"; do
    require_orphaned "$pid" orphan-matcher
  done

  out=$(FM_AUTOMATION_BROWSER_MIN_AGE=0 "$REAPER" --dry-run) || fail "orphan-matcher: dry-run sweep failed"
  listed "$out" "$automation" || fail "orphan-matcher: an orphaned --enable-automation Chrome was not selected: $out"
  listed "$out" "$puppeteer" || fail "orphan-matcher: an orphaned Chrome on a puppeteer temp profile was not selected: $out"
  listed "$out" "$captain" && fail "orphan-matcher: a plain Chrome was selected"
  listed "$out" "$captain_profile" && fail "orphan-matcher: the captain's profiled Chrome was selected"
  listed "$out" "$captain_debug" && fail "orphan-matcher: a remote-debugging Chrome with no automation marker was selected"
  listed "$out" "$dia" && fail "orphan-matcher: Dia was selected"
  listed "$out" "$helper" && fail "orphan-matcher: a Chrome helper process was selected as a root"
  listed "$out" "$attached" && fail "orphan-matcher: an automation Chrome with a live parent was selected"
  alive "$automation" || fail "orphan-matcher: --dry-run signalled a candidate"
  pass "sweep selects only orphaned automation Chromes, never the captain's Chrome, Dia, helpers, or a driven browser"

  out=$(FM_AUTOMATION_BROWSER_MIN_AGE=86400 "$REAPER" --dry-run) || fail "orphan-age: dry-run sweep failed"
  listed "$out" "$automation" && fail "orphan-age: an orphan younger than the threshold was selected"
  pass "sweep leaves an orphaned automation Chrome younger than the age threshold alone"
}

BRIDGE_JS=
make_bridge() {
  BRIDGE_JS="$TMP_ROOT/axi/dist/bin/chrome-devtools-axi-bridge.js"
  mkdir -p "$(dirname "$BRIDGE_JS")"
  cat > "$BRIDGE_JS" <<'JS'
const { spawn } = require("node:child_process");
if (process.env.FIXTURE_CHROME) {
  spawn(process.env.FIXTURE_CHROME, ["--enable-automation", "--remote-debugging-pipe"], { detached: true, stdio: "ignore" });
}
setInterval(() => {}, 1000);
JS
}

# Start a bridge stand-in with GOTMPDIR=<marker> and
# CHROME_DEVTOOLS_AXI_SESSION=<session> (empty: unset); echo its pid.
start_bridge() { # <marker> <session> [chrome]
  local pid
  local -a env_args=(-u GOTMPDIR -u CHROME_DEVTOOLS_AXI_SESSION)
  [ -z "$1" ] || env_args+=("GOTMPDIR=$1")
  [ -z "$2" ] || env_args+=("CHROME_DEVTOOLS_AXI_SESSION=$2")
  (cd "$TMP_ROOT" && FIXTURE_CHROME=${3:-} exec env "${env_args[@]}" node "$BRIDGE_JS") </dev/null >/dev/null 2>&1 &
  pid=$!
  track "$pid"
  printf '%s\n' "$pid"
}

child_of() { # <pid> -> first child pid, waiting briefly
  local deadline=$(( $(date +%s) + 5 )) child
  while [ "$(date +%s)" -lt "$deadline" ]; do
    child=$(pgrep -P "$1" 2>/dev/null | head -n 1)
    [ -n "$child" ] && { printf '%s\n' "$child"; return 0; }
    sleep 0.1
  done
  return 1
}

test_bridges() {
  local gone live gone_pid live_pid other unmarked gone_unnamed gone_default out task_tmp task_bridge task_chrome task_sleep bystander task_unnamed task_default
  if ! command -v node >/dev/null 2>&1; then
    pass "bridge cases skipped: node is absent on this host"
    return 0
  fi
  make_bridge
  gone="/tmp/fm-fmabtest-$$-gone"
  live="/tmp/fm-fmabtest-$$-live"
  rm -rf "$gone"
  mkdir -p "$live"
  gone_pid=$(start_bridge "$gone/gotmp" fm-gone)
  live_pid=$(start_bridge "$live/gotmp" fm-live)
  other=$(start_bridge "$TMP_ROOT/not-a-task-root/gotmp" fm-other)
  unmarked=$(start_bridge "" fm-unmarked)
  gone_unnamed=$(start_bridge "$gone/gotmp" "")
  gone_default=$(start_bridge "$gone/gotmp" default)
  sleep 1

  out=$("$REAPER" --dry-run) || fail "bridge-sweep: dry-run sweep failed"
  rmdir "$live"
  listed "$out" "$gone_pid" || fail "bridge-sweep: a bridge whose task temp root is gone was not selected: $out"
  listed "$out" "$live_pid" && fail "bridge-sweep: a bridge of a live task was selected"
  listed "$out" "$other" && fail "bridge-sweep: a bridge without a task temp root marker was selected"
  listed "$out" "$unmarked" && fail "bridge-sweep: a bridge without GOTMPDIR was selected"
  listed "$out" "$gone_unnamed" && fail "bridge-sweep: a bridge without a session name was selected"
  listed "$out" "$gone_default" && fail "bridge-sweep: the shared default-session bridge was selected"
  pass "sweep selects a bridge only when its task's temp root is gone, never the shared default bridge"

  task_tmp="$TMP_ROOT/tasktmp"
  mkdir -p "$task_tmp/gotmp"
  task_bridge=$(start_bridge "$task_tmp/gotmp" fm-tasktmp "$CHROME")
  task_chrome=$(child_of "$task_bridge") || fail "task-mode: fixture bridge did not start its browser"
  task_sleep=$(child_of "$task_chrome") || fail "task-mode: fixture browser did not start"
  bystander=$(start_bridge "$TMP_ROOT/other-task/gotmp" fm-other-task)
  task_unnamed=$(start_bridge "$task_tmp/gotmp" "")
  task_default=$(start_bridge "$task_tmp/gotmp" default)
  sleep 0.5

  out=$("$REAPER" --task-tmp "$task_tmp") || fail "task-mode: reap failed"
  wait_gone "$task_bridge" 5 || fail "task-mode: the task's bridge survived"
  wait_gone "$task_chrome" 5 || fail "task-mode: the browser in its own process group survived its bridge"
  wait_gone "$task_sleep" 5 || fail "task-mode: a browser descendant survived"
  alive "$bystander" || fail "task-mode: another task's bridge was stopped"
  alive "$task_unnamed" || fail "task-mode: a bridge without a session name was stopped"
  alive "$task_default" || fail "task-mode: the shared default-session bridge was stopped"
  assert_contains "$out" "stopped chrome-devtools-axi bridge of task temp root $task_tmp $task_bridge" \
    "task-mode: the reap was not reported"
  pass "task mode stops the task's bridge with its whole browser tree and leaves other and default-session bridges alone"
}

test_orphan_matcher
test_bridges
