#!/usr/bin/env bash
# Live lab drive: a real fm-watch.sh watching a real tmux pane (private fm-lab
# socket) whose task is held for the captain in a real backlog through the real
# bin/fm-captain-hold.sh. Only the crew-state verdict is stubbed to "working"
# (it stands in for a no-mistakes run-step, which this gate may not start).
# Usage: [LAB_STATUS_LINE=..] [LAB_NOHOLD=1] [LAB_RESURFACE=secs] lab-drive.sh <bin-dir> <label> <duration-secs> [away]
set -u
BIN=$1 LABEL=$2 DUR=$3 AWAY=${4:-}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$BIN/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/stub" "$LAB/xbin"
export TMUX_TMPDIR="$LAB/tmux"
cleanup() { tmux -L fm-lab kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT

cp "$(command -v sleep)" "$LAB/xbin/grok"
tmux -L fm-lab new-session -d -s lab -n fm-wedge -x 120 -y 30 \
  "printf 'Captain-only dialog: approve the production migration? [y/N]\n'; exec '$LAB/xbin/grok' 100000"
sleep 0.5
SOCK=$(tmux -L fm-lab display -p '#{socket_path}')
SPID=$(tmux -L fm-lab display -p '#{pid}')
export TMUX="$SOCK,$SPID,0"
echo "[$LABEL] pane: $(tmux list-panes -t lab:fm-wedge -F '#{pane_current_command}')  capture: $(tmux capture-pane -p -t lab:fm-wedge | head -1)"

printf 'window=lab:fm-wedge\nkind=ship\nharness=grok\nbackend=tmux\n' > "$LAB/state/wedge.meta"
printf '%s\n' "${LAB_STATUS_LINE:-working: answering the dialog}" > "$LAB/state/wedge.status"
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
(cd "$LAB" && tasks-axi add wedge 'stuck at a captain-only dialog' --file data/backlog.md) >/dev/null
[ -n "${LAB_NOHOLD:-}" ] || FM_HOME="$LAB" "$BIN/fm-captain-hold.sh" hold wedge --reason 'awaiting the captain on the dialog' >/dev/null
echo "[$LABEL] captain hold open: $(FM_HOME="$LAB" "$BIN/fm-captain-hold.sh" open wedge --identity 2>&1 && echo yes)"
[ -z "$AWAY" ] || { FM_HOME="$LAB" "$BIN/fm-afk-contract.sh" enter >/dev/null && echo "[$LABEL] away-posture record written"; }

printf '#!/bin/sh\necho "state: working · source: run-step · ci running"\n' > "$LAB/stub/fm-crew-state.sh"
chmod +x "$LAB/stub/fm-crew-state.sh"

start=$(date +%s) wakes=0
while [ $(( $(date +%s) - start )) -lt "$DUR" ]; do
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_CREW_STATE_BIN="$LAB/stub/fm-crew-state.sh" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_STALE_ESCALATE_SECS=3 FM_PAUSE_RESURFACE_SECS=${LAB_RESURFACE:-3600} FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    timeout $(( DUR - ($(date +%s) - start) + 1 )) "$BIN/fm-watch.sh" > "$LAB/out" 2>/dev/null
  rc=$?
  if [ -s "$LAB/out" ]; then
    wakes=$((wakes + 1))
    echo "[$LABEL] t+$(( $(date +%s) - start ))s wake: $(cat "$LAB/out")"
    err="$LAB/drain.err"
    FM_HOME="$LAB" "$BIN/fm-wake-drain.sh" >/dev/null 2>"$err"
    seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
    gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
    [ -z "$seq" ] || FM_HOME="$LAB" "$BIN/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  elif [ "$rc" -ne 124 ]; then
    echo "[$LABEL] watcher exited rc=$rc with no output"; sleep 1
  fi
done
echo "[$LABEL] total wakes in ${DUR}s (escalate threshold 3s): $wakes"
echo "[$LABEL] wedge escalation counter: $(cat "$LAB"/state/.wedge-escalations-* 2>/dev/null || echo none)"
grep -h 'wedge\|captain hold\|absorbed' "$LAB"/state/.triage-log* "$LAB"/state/*triage* 2>/dev/null | tail -5 | sed "s/^/[$LABEL] triage: /"
