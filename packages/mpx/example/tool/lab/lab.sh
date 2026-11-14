#!/usr/bin/env bash
# Shared by the lab scripts; sourced, never run.
#
# DEVICE picks the adb device (the only attached one by default). Sessions
# land in perf/lab/<session>/ (gitignored). The app must be a profile build
# with --dart-define=MPX_LAB=true (build.sh), or no LAB line ever comes.
#
# Start switches, applied by app_start before the first frame:
#   LAB_COLD=1        wipe the media caches (bytes, Lottie frames) at start
#   LAB_OPEN=stress   start on the stress feed instead of the home page
#   LAB_SET="items=30 kinds=loop,clip distinct=false textures=false"
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$LAB_DIR/../.." && pwd)"
PKG=dev.mpx.mpx_example
FILES="/sdcard/Android/data/$PKG/files"
DEVICE="${DEVICE:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
[[ -n "$DEVICE" ]] || { echo "no adb device attached" >&2; exit 1; }
DEVICE_TRACE=/data/misc/perfetto-traces/lab.pftrace
PY="${PY:-python3}"

D() { adb -s "$DEVICE" "$@"; }

die() { echo "lab: $*" >&2; exit 1; }

# session_dir <name>: creates and prints perf/lab/<name>.
session_dir() {
  local dir="$EXAMPLE_DIR/perf/lab/${1:?session name}"
  mkdir -p "$dir"
  echo "$dir"
}

# lab_set <key> [value] [name]: one lab switch or command over broadcast.
lab_set() {
  local args=(--es key "$1")
  [[ -n "${2:-}" ]] && args+=(--es value "$2")
  [[ -n "${3:-}" ]] && args+=(--es name "$3")
  D shell am broadcast -a lab.SET "${args[@]}" >/dev/null
}

# app_start: a fresh process (force-stop, then start) with the start
# switches, waiting for its `LAB ready` line. Clears logcat first, so every
# wait_log after it reads this process only.
app_start() {
  local extras=()
  [[ "${LAB_COLD:-0}" == 1 ]] && extras+=(--es lab_cold true)
  [[ -n "${LAB_OPEN:-}" ]] && extras+=(--es lab_open "$LAB_OPEN")
  local kv
  for kv in ${LAB_SET:-}; do extras+=(--es "lab_${kv%%=*}" "${kv#*=}"); done
  D shell am force-stop "$PKG"
  sleep 1
  D logcat -c
  # The engine and the Dart marks reach the system trace only with
  # trace-systrace, which inflates busy frames: confirm a slow one from its
  # `LAB slow` line.
  D shell am start -W -n "$PKG/.MainActivity" --ez trace-systrace true \
    ${extras[@]+"${extras[@]}"} >/dev/null ||
    die "could not start $PKG: is it installed (build.sh)?"
  wait_log "LAB ready" 30
  if [[ "${LAB_OPEN:-}" == stress ]]; then wait_log "event feed open" 10; fi
  grep -m1 "LAB ready" <(D logcat -d -s flutter) | sed 's/.*LAB/  LAB/'
}

# trace_start <dir>: a background system trace (trace.pbtx, at most 5.5 min,
# written to the file as it runs).
trace_start() {
  D shell perfetto --background --txt -c - -o "$DEVICE_TRACE" \
    <"$LAB_DIR/trace.pbtx" | tr -d '\r' >"$1/perfetto.pid"
  [[ -s "$1/perfetto.pid" ]] || die "perfetto did not start"
  sleep 2
}

# trace_stop <dir>: stops the trace and pulls it to <dir>/trace.pftrace.
trace_stop() {
  D shell kill "$(cat "$1/perfetto.pid")" || true
  sleep 3
  D pull "$DEVICE_TRACE" "$1/trace.pftrace" >/dev/null || die "no trace to pull"
  D shell rm -f "$DEVICE_TRACE"
}

# logcat_start <dir>: streams the app's log to <dir>/logcat.txt, so nothing
# is lost to the logcat ring in a long session.
logcat_start() {
  D logcat -v monotonic -s flutter >"$1/logcat.txt" 2>/dev/null &
  echo $! >"$1/logcat.hostpid"
}

# logcat_stop <dir>: ends the stream logcat_start began.
logcat_stop() {
  [[ -f "$1/logcat.hostpid" ]] || return 0
  kill "$(cat "$1/logcat.hostpid")" 2>/dev/null || true
  rm -f "$1/logcat.hostpid"
}

# lab_log <dir>: the app's LAB lines, to <dir>/lab.txt: from the stream when
# logcat_start ran, else what the logcat ring still holds.
lab_log() {
  if [[ -s "$1/logcat.txt" ]]; then
    grep LAB "$1/logcat.txt" | sed 's/.*LAB/LAB/' >"$1/lab.txt" || true
  else
    D logcat -d -s flutter | grep LAB | sed 's/.*LAB/LAB/' >"$1/lab.txt" || true
  fi
}

# record_start <dir>: one screen recording of at most 170 s.
record_start() {
  D shell rm -f /sdcard/lab-record.mp4
  D shell screenrecord --time-limit 170 /sdcard/lab-record.mp4 &
  echo $! >"$1/record.hostpid"
}

# record_stop <dir>: ends the recording and pulls it to <dir>/screen.mp4.
record_stop() {
  [[ -f "$1/record.hostpid" ]] || return 0
  D shell pkill -INT screenrecord 2>/dev/null || true
  sleep 2
  kill "$(cat "$1/record.hostpid")" 2>/dev/null || true
  rm -f "$1/record.hostpid"
  D pull /sdcard/lab-record.mp4 "$1/screen.mp4" >/dev/null || true
  D shell rm -f /sdcard/lab-record.mp4
}

# wait_log <pattern> <seconds>: waits for a LAB line; fails when it never
# comes, so a run that did not start reads as an error, not as no data.
wait_log() {
  local pattern=$1 left=$2
  until D logcat -d -s flutter | grep -q "$pattern"; do
    if ! D shell pidof "$PKG" >/dev/null; then
      die "the app is not running while waiting for '$pattern'"
    fi
    ((left -= 1)) || true
    if ((left <= 0)); then
      die "no '$pattern' from the app: is it an MPX_LAB=true profile build?"
    fi
    sleep 1
  done
}

# corpus_log <dir>: the corpus the app started with (its `LAB corpus`
# lines), to <dir>/corpus.txt. Call right after app_start.
corpus_log() {
  D logcat -d -s flutter | grep 'LAB corpus' |
    sed 's/.*LAB corpus /corpus /; s/ @[0-9.]*$//' >"$1/corpus.txt" || true
  [[ -s "$1/corpus.txt" ]] || die "no LAB corpus lines: an older lab build?"
}

# corpus_check <run dir> <tape dir>: prints the run's corpus and flags a
# corpus other than the one the tape was recorded on.
corpus_check() {
  sed 's/^/  /' "$1/corpus.txt"
  if [[ -f "$2/corpus.txt" ]] &&
    ! cmp -s <(head -1 "$1/corpus.txt" | sed 's/ loopback=[^ ]*//') \
      <(head -1 "$2/corpus.txt" | sed 's/ loopback=[^ ]*//'); then
    echo "  CORPUS DIFFERS from the tape's recording: $(head -1 "$2/corpus.txt")"
  fi
}

# battery_temp: the battery temperature in °C.
battery_temp() {
  D shell dumpsys battery | awk '/temperature/ { printf "%.1f\n", $2 / 10; exit }'
}

# analyse <dir> <tape.json>: the per-segment report, when the Python has
# the perfetto package.
analyse() {
  if "$PY" -c 'import perfetto' 2>/dev/null; then
    {
      cat "$1/corpus.txt" 2>/dev/null
      { grep "^LAB net" "$1/lab.txt" 2>/dev/null || true; } | sed "s/^LAB //; s/ @[0-9.]*$//"
      "$PY" "$LAB_DIR/session.py" "$1/trace.pftrace" "$2"
    } |
      tee "$1/report.txt"
  else
    echo "  (no perfetto for $PY: pip install perfetto, or PY=<venv>/bin/python)"
  fi
}
