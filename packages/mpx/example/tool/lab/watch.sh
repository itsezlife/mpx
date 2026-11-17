#!/usr/bin/env bash
# Records the user's own session as a replayable tape.
#
#   tool/lab/watch.sh start <session>   # then the user acts
#   tool/lab/watch.sh stop <session>
#
# Start restarts the app (a fresh process on the home page, or on the stress
# feed with LAB_OPEN=stress, under the start switches of lab.sh), so a
# replay starts from the same state. It captures a system trace (at most
# 5.5 min), the raw touches (getevent), the in-app tape and the LAB log.
# RECORD=1 also records the screen for at most 170 s. Stop prints a sanity
# line. The in-app back arrow and the system Back both land on the tape.
source "$(dirname "$0")/lab.sh"

cmd=${1:?start|stop}
name=${2:?session name}
dir=$(session_dir "$name")

case $cmd in
  start)
    app_start
    corpus_log "$dir"
    sleep "${SETTLE:-3}"
    logcat_start "$dir"
    trace_start "$dir"
    if [[ "${RECORD:-0}" == 1 ]]; then record_start "$dir"; fi
    D shell getevent -lt >"$dir/getevent.txt" 2>/dev/null &
    echo $! >"$dir/getevent.hostpid"
    lab_set record true "$name"
    wait_log "tape record start $name" 10
    date +%s >"$dir/started"
    echo "watching $name: act now, then run: $0 stop $name"
    ;;
  stop)
    lab_set record false "$name"
    wait_log "tape saved $name" 10
    trace_stop "$dir"
    record_stop "$dir"
    kill "$(cat "$dir/getevent.hostpid")" 2>/dev/null || true
    logcat_stop "$dir"
    lab_log "$dir"
    D pull "$FILES/$name.json" "$dir/tape.json" >/dev/null ||
      die "no tape on the device"
    touches=$(grep -c ABS_MT_POSITION_Y "$dir/getevent.txt" || true)
    echo "$name: $(($(date +%s) - $(cat "$dir/started")))s," \
      "touches=$touches, tape=$(wc -c <"$dir/tape.json" | tr -d ' ')B," \
      "trace=$(wc -c <"$dir/trace.pftrace" | tr -d ' ')B"
    grep 'tape saved' "$dir/lab.txt"
    ;;
  *)
    die "usage: $0 start|stop <session>"
    ;;
esac
