#!/usr/bin/env bash
# Traces a scenario that needs no tape, from a fresh process.
#
#   tool/lab/scenario.sh feed <session>        # deep start into the stress feed
#   tool/lab/scenario.sh swipe <session> [n]   # smoke test: n synthetic flings
#
# `feed` traces the start and the stress feed's open (LAB_COLD=1 for a cold
# one). `swipe` opens the stress feed and flings it with `adb input swipe`:
# synthetic input, for proving the pipeline only, never for a verdict. Both
# end with the per-segment report when perfetto is in $PY.
source "$(dirname "$0")/lab.sh"

cmd=${1:?feed|swipe}
dir=$(session_dir "${2:?session name}")
LAB_OPEN=stress

case $cmd in
  feed)
    D shell am force-stop "$PKG"
    trace_start "$dir"
    app_start
    corpus_log "$dir"
    wait_log "event feed \(first-content\|no-content\)" 15
    sleep 3
    ;;
  swipe)
    app_start
    corpus_log "$dir"
    sleep "${SETTLE:-3}"
    trace_start "$dir"
    read -r w h < <(D shell wm size | awk -F'[ x]' '/Physical/ { print $3, $4 }')
    for i in $(seq 1 "${3:-6}"); do
      if ((i % 2)); then
        D shell input swipe $((w / 2)) $((h * 3 / 4)) $((w / 2)) $((h / 4)) 120
      else
        D shell input swipe $((w / 2)) $((h / 4)) $((w / 2)) $((h * 3 / 4)) 120
      fi
      sleep 2
    done
    sleep 2
    ;;
  *)
    die "usage: $0 feed|swipe <session> [n]"
    ;;
esac
trace_stop "$dir"
lab_log "$dir"
echo "$cmd: trace=$(wc -c <"$dir/trace.pftrace" | tr -d ' ')B," \
  "events=$(grep -c 'LAB event' "$dir/lab.txt" || true)," \
  "slow frames=$(grep -c 'LAB slow' "$dir/lab.txt" || true)," \
  "bursts=$(grep -c 'LAB burst' "$dir/lab.txt" || true)"
analyse "$dir" -
