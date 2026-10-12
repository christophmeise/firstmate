#!/usr/bin/env bash
# Stop automation browsers a task left running after its controller went away.
#
# Usage: fm-automation-browser-reap.sh [--dry-run] [--task-tmp <dir>]
#   --task-tmp <dir>  task mode: stop the chrome-devtools-axi bridges launched
#                     by the task whose per-task temp root is <dir>, with their
#                     whole process trees. bin/fm-teardown.sh and
#                     bin/fm-control.sh exit/relaunch call this.
#   (no --task-tmp)   sweep mode: stop bridges whose task is gone and orphaned
#                     automation Chromes. bin/fm-watch.sh runs this periodically.
#   --dry-run         report what would be stopped and signal nothing.
#
# Two launch paths leak a headless Chrome past its task, and neither is reached
# by teardown's cwd-rooted reap:
#   1. chrome-devtools-axi starts a detached bridge daemon (its own session and
#      process group, ppid 1) that never exits on its own and holds
#      chrome-devtools-mcp and its Chrome for as long as it lives. Workers often
#      run it from a harness scratchpad outside the task worktree, so its cwd
#      attributes it to nothing. It does inherit the worker's environment,
#      including the GOTMPDIR=<task-tmp>/gotmp marker bin/fm-spawn.sh exports
#      into every task pane, and that marker survives reparenting.
#   2. puppeteer's default launch (remote-debugging port, not pipe) starts
#      Chrome detached in its own process group. When the node process driving
#      it dies without closing it - a test runner killed with SIGKILL, a timed
#      out script - Chrome is reparented to init and keeps running, unreachable,
#      because nothing it can see tells it its controller is gone. A pipe-mode
#      Chrome (chrome-devtools-mcp's default) exits when its pipe closes, so it
#      only leaks through path 1.
#
# Task mode stops every bridge whose environment carries GOTMPDIR=<dir>/gotmp.
# Sweep mode stops:
#   - a bridge whose GOTMPDIR names a /tmp/fm-<id>/gotmp task temp root that no
#     longer exists. Teardown removes that root, so its absence proves the task
#     is gone in whichever home owned it. A bridge without that marker - the
#     captain's own, or firstmate's - is never a candidate.
#   - an orphaned automation Chrome: the top-level browser process of a Chrome
#     or Chromium binary (never a --type= helper), reparented to init, running
#     at least FM_AUTOMATION_BROWSER_MIN_AGE seconds (default 7200), and
#     carrying an automation marker: --enable-automation, or a
#     puppeteer/playwright temporary --user-data-dir. The captain's own Chrome
#     carries neither marker and Dia is not a Chrome binary, so neither can
#     match. A live task's active browser always has its live controller as
#     parent; an orphan has none and no controller can reattach to it, so it
#     is abandoned even while the task that launched it is still running.
# Each candidate is stopped with every descendant from one process snapshot:
# TERM first, KILL only for a survivor whose start time still matches, so a
# recycled pid is never signalled. Only this user's processes are inspected,
# and this process and its ancestors are never candidates.
#
# Prints one line per stopped or surviving candidate and nothing when there is
# nothing to do. Exits 0 unless the process scan itself could not run.
set -u

DRY_RUN=0
TASK_TMP=
MIN_AGE=${FM_AUTOMATION_BROWSER_MIN_AGE:-7200}
case "$MIN_AGE" in ''|*[!0-9]*) MIN_AGE=7200 ;; esac
PROC_ROOT=${FM_PROC_ROOT_OVERRIDE:-/proc}
SCAN=

ab_die() { printf 'fm-automation-browser-reap: %s\n' "$1" >&2; exit 2; }

ab_usage() {
  cat <<'TXT'
Usage: fm-automation-browser-reap.sh [--dry-run] [--task-tmp <dir>]

With --task-tmp, stop the chrome-devtools-axi bridges (and their browsers) of
the task whose per-task temp root is <dir>. Without it, stop bridges whose task
temp root is gone and orphaned automation Chromes older than
FM_AUTOMATION_BROWSER_MIN_AGE seconds (default 7200). Never touches a browser
without an automation marker. --dry-run reports and signals nothing. Read this
script's header for the full rule.
TXT
}

# [[dd-]hh:]mm:ss -> seconds.
ab_etime_seconds() { # <etime>
  local etime=$1 days=0 rest h=0 m s
  case "$etime" in *-*) days=${etime%%-*}; etime=${etime#*-} ;; esac
  rest=$etime
  case "$rest" in
    *:*:*) h=${rest%%:*}; rest=${rest#*:} ;;
  esac
  m=${rest%%:*}
  s=${rest#*:}
  case "$days$h$m$s" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' $(( 10#$days * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

ab_is_bridge() { # <command>
  case "$1" in
    *"/chrome-devtools-axi-bridge.js"|*"/chrome-devtools-axi-bridge.ts") return 0 ;;
  esac
  return 1
}

# The top-level browser process of a Chrome or Chromium binary that carries an
# automation marker. Helpers (--type=...) are covered as descendants instead.
ab_is_automation_chrome() { # <command>
  local command=$1 exe args udd
  exe=${command%% --*}
  case "${exe##*/}" in
    "Google Chrome"|"Google Chrome for Testing"|"Google Chrome Beta"|"Google Chrome Dev"|"Google Chrome Canary"|Chromium|chromium|chromium-browser|chrome|google-chrome|google-chrome-stable|chrome-headless-shell) ;;
    *) return 1 ;;
  esac
  args=" ${command#"$exe"} "
  case "$args" in *" --type="*) return 1 ;; esac
  case "$args" in *" --enable-automation "*) return 0 ;; esac
  udd=${args#*" --user-data-dir="}
  [ "$udd" != "$args" ] || return 1
  udd=${udd%% --*}
  udd=${udd%% }
  case "${udd##*/}" in
    puppeteer_dev_chrome_profile-*|puppeteer_dev_profile-*|playwright_chromiumdev_profile-*) return 0 ;;
  esac
  return 1
}

# The value of GOTMPDIR in <pid>'s environment, when readable.
ab_process_gotmpdir() { # <pid>
  local pid=$1 env token
  local -a tokens=()
  if [ -r "$PROC_ROOT/$pid/environ" ]; then
    tr '\0' '\n' < "$PROC_ROOT/$pid/environ" 2>/dev/null | sed -n 's/^GOTMPDIR=//p' | head -n 1
    return 0
  fi
  env=$(ps -E -ww -o command= -p "$pid" 2>/dev/null) || return 1
  read -r -a tokens <<< "$env"
  [ "${#tokens[@]}" -gt 0 ] || return 0
  for token in "${tokens[@]}"; do
    case "$token" in GOTMPDIR=*) printf '%s\n' "${token#GOTMPDIR=}"; return 0 ;; esac
  done
  return 0
}

ab_process_start() { # <pid>
  LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null
}

ab_is_self_or_ancestor() { # <pid>
  local pid=$1 walk=$$ i=0
  while [ "$walk" -gt 1 ] && [ "$i" -lt 64 ]; do
    [ "$walk" != "$pid" ] || return 0
    walk=$(ps -p "$walk" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 1
    case "$walk" in ''|*[!0-9]*) return 1 ;; esac
    i=$((i + 1))
  done
  return 1
}

# Orphaned: reparented to init, or to a `systemd --user` subreaper that adopts
# a Linux session's orphans in its place.
ab_is_orphan() { # <ppid>
  [ "$1" = 1 ] && return 0
  printf '%s\n' "$SCAN" | awk -v pid="$1" '$1 == pid { found = 1; if ($0 ~ /systemd --user/) user = 1 } END { exit !(found && user) }'
}

# <root> and every descendant in the snapshot, root first.
ab_tree() { # <root>
  printf '%s\n' "$SCAN" | awk -v root="$1" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { kids[$2] = kids[$2] " " $1 }
    END {
      n = 1; q[1] = root; seen[root] = 1; i = 1
      while (i <= n) {
        p = q[i++]; print p
        m = split(kids[p], c, " ")
        for (j = 1; j <= m; j++) if (!(c[j] in seen)) { seen[c[j]] = 1; q[++n] = c[j] }
      }
    }'
}

# TERM the whole tree, then KILL any survivor whose start time is unchanged.
ab_stop_tree() { # <root>
  local pid i alive
  local -a pids=() starts=()
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    pids+=("$pid")
    starts+=("$(ab_process_start "$pid")")
  done < <(ab_tree "$1")
  for i in "${!pids[@]}"; do
    [ -n "${starts[$i]}" ] && kill -TERM "${pids[$i]}" 2>/dev/null || true
  done
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    alive=0
    for i in "${!pids[@]}"; do
      if [ -n "${starts[$i]}" ] && [ "$(ab_process_start "${pids[$i]}")" = "${starts[$i]}" ]; then
        alive=1
        break
      fi
    done
    [ "$alive" -eq 1 ] || return 0
    sleep 0.1
  done
  for i in "${!pids[@]}"; do
    if [ -n "${starts[$i]}" ] && [ "$(ab_process_start "${pids[$i]}")" = "${starts[$i]}" ]; then
      kill -KILL "${pids[$i]}" 2>/dev/null || true
    fi
  done
  sleep 0.2
  for i in "${!pids[@]}"; do
    if [ -n "${starts[$i]}" ] && [ "$(ab_process_start "${pids[$i]}")" = "${starts[$i]}" ]; then
      return 1
    fi
  done
  return 0
}

ab_act() { # <pid> <description>
  local count
  count=$(ab_tree "$1" | wc -l | tr -d '[:space:]')
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would stop %s %s (%s process(es))\n' "$2" "$1" "$count"
  elif ab_stop_tree "$1"; then
    printf 'stopped %s %s (%s process(es))\n' "$2" "$1" "$count"
  else
    printf 'warning: %s %s survived stopping\n' "$2" "$1" >&2
  fi
}

ab_run() {
  local uid pid ppid etime command age gotmp root i
  local -a cand_pids=() cand_descs=()
  uid=$(id -u 2>/dev/null || true)
  case "$uid" in ''|*[!0-9]*) ab_die "cannot resolve the current uid" ;; esac
  SCAN=$(ps -ww -u "$uid" -o pid=,ppid=,etime=,command= 2>/dev/null) ||
    ab_die "cannot scan this account's processes"
  while read -r pid ppid etime command; do
    case "$pid$ppid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" != "$$" ] || continue
    if ab_is_bridge "$command"; then
      gotmp=$(ab_process_gotmpdir "$pid") || continue
      if [ -n "$TASK_TMP" ]; then
        [ "$gotmp" = "$TASK_TMP/gotmp" ] || continue
        cand_descs+=("chrome-devtools-axi bridge of task temp root $TASK_TMP")
      else
        case "$gotmp" in /tmp/fm-*/gotmp) ;; *) continue ;; esac
        root=${gotmp%/gotmp}
        case "$root" in */*/*/*) continue ;; esac
        [ ! -e "$root" ] || continue
        cand_descs+=("chrome-devtools-axi bridge of removed task temp root $root")
      fi
      cand_pids+=("$pid")
    elif [ -z "$TASK_TMP" ] && ab_is_automation_chrome "$command"; then
      ab_is_orphan "$ppid" || continue
      age=$(ab_etime_seconds "$etime") || continue
      [ "$age" -ge "$MIN_AGE" ] || continue
      cand_pids+=("$pid")
      cand_descs+=("orphaned automation Chrome aged ${age}s")
    fi
  done <<EOF
$SCAN
EOF
  [ "${#cand_pids[@]}" -gt 0 ] || return 0
  for i in "${!cand_pids[@]}"; do
    ab_is_self_or_ancestor "${cand_pids[$i]}" && continue
    ab_act "${cand_pids[$i]}" "${cand_descs[$i]}"
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --task-tmp)
      [ "$#" -ge 2 ] && [ -n "$2" ] || ab_die "--task-tmp needs a directory"
      TASK_TMP=${2%/}
      shift
      ;;
    -h|--help) ab_usage; exit 0 ;;
    *) ab_die "unexpected argument: $1" ;;
  esac
  shift
done

ab_run
