#!/usr/bin/env bash
# Replays a recorded tape from a fresh process under a system trace.
#
#   tool/lab/replay.sh <tape> <session>
#
# <tape> is a session recorded by watch.sh (perf/lab/<tape>/tape.json); it is
# pushed to the app first. The app restarts at the route the tape starts at,
# under the start switches of lab.sh (LAB_COLD=1 for a cold start), waits
# SETTLE seconds (3) for its media, then replays. The app refuses a tape
# recorded in another window or from another route, and the script fails.
# Prints the app's frame summary and, with perfetto in $PY, the per-segment
# report (session.py).
source "$(dirname "$0")/lab.sh"

tape=${1:?tape name}
dir=$(session_dir "${2:?session name}")
src="$EXAMPLE_DIR/perf/lab/$tape/tape.json"
[[ -f "$src" ]] || die "no tape at $src"
start=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["start"])' "$src")
D push "$src" "$FILES/$tape.json" >/dev/null || die "could not push the tape"

echo "battery $(battery_temp) °C"
if [[ "$start" == stress ]]; then LAB_OPEN=stress; else LAB_OPEN=; fi
app_start
corpus_log "$dir"
corpus_check "$dir" "$EXAMPLE_DIR/perf/lab/$tape"
sleep "${SETTLE:-3}"
logcat_start "$dir"
trace_start "$dir"
lab_set replay "" "$tape"
wait_log "tape replay \(start\|refused\) $tape" 15
if D logcat -d -s flutter | grep -q "tape replay refused $tape"; then
  trace_stop "$dir"
  logcat_stop "$dir"
  D logcat -d -s flutter | grep -m1 "tape replay refused" | sed 's/.*LAB/LAB/' >&2
  die "the app refused the tape"
fi
wait_log "tape replay done $tape" 600
sleep 2
trace_stop "$dir"
logcat_stop "$dir"
lab_log "$dir"
grep -E 'summary|tape replay done|LAB net requests' "$dir/lab.txt" | sed 's/^/  /'
echo "  trace=$(wc -c <"$dir/trace.pftrace" | tr -d ' ')B," \
  "events=$(grep -c 'LAB event' "$dir/lab.txt" || true)," \
  "slow frames=$(grep -c 'LAB slow' "$dir/lab.txt" || true)"
analyse "$dir" "$src"
