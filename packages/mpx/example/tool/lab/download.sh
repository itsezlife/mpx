#!/usr/bin/env bash
# Download throughput through the stack, from a cold cache.
#
#   tool/lab/download.sh <session>                 # every public entry
#   DOWNLOAD=trailer_1080p.mov tool/lab/download.sh <session>
#
# Cold-starts the app on an empty home page (no tile shares the link), then
# downloads each entry whole through the stack's bytes cache, one file at a
# time and then all at once, and prints the `LAB dl` lines: per file bytes,
# span and kbps, and a total per pass. Compare with curl on the same URLs
# from the same network. The run's request log follows (`LAB net`).
source "$(dirname "$0")/lab.sh"

dir=$(session_dir "${1:?session name}")
LAB_COLD=1
LAB_OPEN=download

app_start
corpus_log "$dir"
logcat_start "$dir"
lab_set download "${DOWNLOAD:-public}"
wait_log "LAB dl done" "${DOWNLOAD_TIMEOUT:-900}"
lab_set net
sleep 2
logcat_stop "$dir"
lab_log "$dir"
sed "s/^LAB //; s/ @[0-9.]*$//" "$dir/lab.txt" | grep -E "^(dl|net) " |
  tee "$dir/download.txt"
