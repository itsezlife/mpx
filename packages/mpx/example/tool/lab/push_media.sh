#!/usr/bin/env bash
# Puts the lab's corpus on the phone.
#
#   tool/lab/push_media.sh                         # the public set only
#   tool/lab/push_media.sh <local dir>             # the folder's files and the public set
#   PUBLIC=0 tool/lab/push_media.sh <local dir>    # the folder's files only
#   REPLACE=1 tool/lab/push_media.sh <local dir>   # drops the files on the phone first
#
# Writes <local dir>/manifest.json (corpus.py: ffprobe per file, a kind
# already in it kept, plus the entries of public_corpus.json, which the app
# fetches from their internet URLs), then pushes the folder to
# /sdcard/Android/data/dev.mpx.mpx_example/files/corpus/. A lab build reads
# it at its next start: the home page and the stress feed then show the
# corpus instead of the bundled fixtures. REPLACE=1 deletes that corpus
# folder first (the lab's folder only).
source "$(dirname "$0")/lab.sh"

src=${1:-}
if [[ -z "$src" ]]; then
  src="$EXAMPLE_DIR/perf/lab/corpus/public"
  mkdir -p "$src"
  REPLACE=1
fi
[[ -d "$src" ]] || die "no folder $src"
public=()
[[ "${PUBLIC:-1}" == 1 ]] && public=("$LAB_DIR/public_corpus.json")
"$PY" "$LAB_DIR/corpus.py" manifest "$src" ${public[@]+"${public[@]}"}
if [[ "${REPLACE:-0}" == 1 ]]; then D shell rm -rf "$FILES/corpus"; fi
D shell mkdir -p "$FILES/corpus"
D push "$src/." "$FILES/corpus/" >/dev/null || die "push failed"
echo "corpus on $DEVICE: $FILES/corpus ($(D shell ls "$FILES/corpus" | wc -l | tr -d ' ') files with the manifest)"
