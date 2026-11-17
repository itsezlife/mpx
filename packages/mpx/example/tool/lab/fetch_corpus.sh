#!/usr/bin/env bash
# Builds the lab's public media corpus in perf/lab/corpus/ (gitignored).
#
#   tool/lab/fetch_corpus.sh          # download (once), verify, transcode
#   tool/lab/push_media.sh perf/lab/corpus/out
#
# Sources are Blender open movies from the official mirror
# (download.blender.org), CC-BY: Big Buck Bunny 2160p60 (the 4K and 1080p
# clips, the stills) and the Sintel trailer 1080p (the loops and the
# animated images). Every download is checked against corpus.sha256 next
# to this script; a source with no pin there is pinned on its first
# download (append the printed line to the file and commit it). The Lottie
# is generated (corpus.py lottie). SOURCES.md records the sources, the
# licences and every output.
#
# Needs ffmpeg with libx264, libx265, libvpx-vp9 and libsvtav1, gif2webp
# (libwebp) and unzip. Outputs are re-made only when missing; FORCE=1
# re-makes them.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
EXAMPLE_DIR="$(cd "$LAB_DIR/../.." && pwd)"
ROOT="$EXAMPLE_DIR/perf/lab/corpus"
SRC="$ROOT/src"
OUT="$ROOT/out"
PINS="$LAB_DIR/corpus.sha256"
PY="${PY:-python3}"
mkdir -p "$SRC" "$OUT"

die() { echo "fetch_corpus: $*" >&2; exit 1; }
for tool in ffmpeg ffprobe gif2webp unzip shasum curl; do
  command -v "$tool" >/dev/null || die "needs $tool"
done
for enc in libx264 libx265 libvpx-vp9 libsvtav1; do
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " $enc " || die "ffmpeg lacks $enc"
done

# fetch <url> <file>: downloads once, then checks the pin.
fetch() {
  local url=$1 file=$2
  if [[ ! -f "$SRC/$file" ]]; then
    echo "downloading $url"
    # Resumes a partial download; retries through dropped connections.
    curl -fL -sS --retry 10 --retry-all-errors --retry-delay 5 -C - \
      -o "$SRC/$file.part" "$url" || die "download failed: $url"
    mv "$SRC/$file.part" "$SRC/$file"
  fi
  local sum
  sum=$(shasum -a 256 "$SRC/$file" | awk '{ print $1 }')
  local pin
  pin=$(awk -v f="$file" '$2 == f { print $1 }' "$PINS" 2>/dev/null || true)
  if [[ -z "$pin" ]]; then
    echo "PIN (append to tool/lab/corpus.sha256): $sum  $file"
  elif [[ "$pin" != "$sum" ]]; then
    die "$file: sha256 $sum, pinned $pin"
  else
    echo "verified $file"
  fi
}

fetch https://download.blender.org/demo/movies/BBB/bbb_sunflower_2160p_60fps_normal.mp4.zip \
  bbb_sunflower_2160p_60fps_normal.mp4.zip
fetch https://download.blender.org/durian/trailer/sintel_trailer-1080p.mp4 \
  sintel_trailer-1080p.mp4
if [[ ! -f "$SRC/bbb_sunflower_2160p_60fps_normal.mp4" ]]; then
  unzip -o -q "$SRC/bbb_sunflower_2160p_60fps_normal.mp4.zip" -d "$SRC"
fi
BBB="$SRC/bbb_sunflower_2160p_60fps_normal.mp4"
SINTEL="$SRC/sintel_trailer-1080p.mp4"
[[ -f "$BBB" ]] || die "no $BBB after unzip"

# make <out> <ffmpeg args...>: one output, skipped when it exists.
make() {
  local out=$1
  shift
  if [[ -f "$OUT/$out" && "${FORCE:-0}" != 1 ]]; then return 0; fi
  echo "making $out"
  ffmpeg -hide_banner -loglevel error -y "$@" "$OUT/$out.tmp.${out##*.}" ||
    die "ffmpeg failed on $out"
  mv "$OUT/$out.tmp.${out##*.}" "$OUT/$out"
}

AAC=(-c:a aac -b:a 128k -ac 2)
OPUS=(-c:a libopus -b:a 128k -ac 2)
H264=(-c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart)
HEVC=(-c:v libx265 -preset fast -crf 22 -pix_fmt yuv420p -tag:v hvc1 -movflags +faststart -x265-params log-level=error)
VP9=(-c:v libvpx-vp9 -b:v 0 -crf 32 -row-mt 1 -deadline good -cpu-used 4 -pix_fmt yuv420p)
AV1=(-c:v libsvtav1 -preset 8 -crf 32 -pix_fmt yuv420p -movflags +faststart)

# Clips with sound, 20 s of Big Buck Bunny from 1:00: the player with
# sound in the viewer, the software decoder muted in lists.
CLIP=(-ss 60 -t 20 -i "$BBB")
make bbb_2160p60_h264.mp4 "${CLIP[@]}" "${H264[@]}" -r 60 "${AAC[@]}"
make bbb_2160p60_hevc.mp4 "${CLIP[@]}" "${HEVC[@]}" -r 60 "${AAC[@]}"
make bbb_2160p30_vp9.webm "${CLIP[@]}" "${VP9[@]}" -r 30 "${OPUS[@]}"
make bbb_2160p30_av1.mp4 "${CLIP[@]}" "${AV1[@]}" -r 30 "${AAC[@]}"
make bbb_1080p60_h264.mp4 "${CLIP[@]}" -vf scale=-2:1080 "${H264[@]}" -r 60 "${AAC[@]}"
make bbb_1080p60_hevc.mp4 "${CLIP[@]}" -vf scale=-2:1080 "${HEVC[@]}" -r 60 "${AAC[@]}"
make bbb_1080p30_vp9.webm "${CLIP[@]}" -vf scale=-2:1080 "${VP9[@]}" -r 30 "${OPUS[@]}"
make bbb_1080p30_av1.mp4 "${CLIP[@]}" -vf scale=-2:1080 "${AV1[@]}" -r 30 "${AAC[@]}"
make sintel_1080p24_h264.mp4 -ss 3 -t 40 -i "$SINTEL" "${H264[@]}" "${AAC[@]}"

# Silent loops, the GIF stand-ins: 3-8 s, 480p and 720p, H.264 and VP9.
make loop_sintel_480p_h264.mp4 -ss 10 -t 4 -i "$SINTEL" -vf scale=-2:480 "${H264[@]}" -an
make loop_sintel_720p_h264.mp4 -ss 20 -t 6 -i "$SINTEL" -vf scale=-2:720 "${H264[@]}" -an
make loop_sintel_480p_vp9.webm -ss 30 -t 5 -i "$SINTEL" -vf scale=-2:480 "${VP9[@]}" -an
make loop_sintel_720p_vp9.webm -ss 40 -t 8 -i "$SINTEL" -vf scale=-2:720 "${VP9[@]}" -an
make loop_bbb_720p30_h264.mp4 -ss 120 -t 3 -i "$BBB" -vf scale=-2:720 "${H264[@]}" -r 30 -an
make loop_bbb_480p30_vp9.webm -ss 150 -t 6 -i "$BBB" -vf scale=-2:480 "${VP9[@]}" -r 30 -an

# Animated images at 512 px with many frames: a GIF, and WebPs from GIFs.
GIF_VF="fps=15,scale=512:-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
make anim_sintel_512.gif -ss 12 -t 6 -i "$SINTEL" -vf "$GIF_VF"
make anim_bbb_512.gif -ss 200 -t 8 -i "$BBB" -vf "${GIF_VF/fps=15/fps=20}"
for gif in anim_sintel_512 anim_bbb_512; do
  if [[ ! -f "$OUT/$gif.webp" || "${FORCE:-0}" == 1 ]]; then
    echo "making $gif.webp"
    gif2webp -quiet -lossy -q 70 -mt "$OUT/$gif.gif" -o "$OUT/$gif.webp" || die "gif2webp failed"
  fi
done

# Stills: 4K frames.
make still_bbb_2160p.jpg -ss 95 -i "$BBB" -frames:v 1 -q:v 3
make still_bbb_2160p.png -ss 300 -i "$BBB" -frames:v 1

# A generated heavy Lottie.
if [[ ! -f "$OUT/lottie_heavy.json" || "${FORCE:-0}" == 1 ]]; then
  "$PY" "$LAB_DIR/corpus.py" lottie "$OUT/lottie_heavy.json"
fi

"$PY" "$LAB_DIR/corpus.py" manifest "$OUT"

{
  echo "# Lab corpus sources"
  echo
  echo "Made by \`tool/lab/fetch_corpus.sh\` on $(date -u +%Y-%m-%d)."
  echo
  echo "| Source | Licence | Attribution | sha256 |"
  echo "| --- | --- | --- | --- |"
  echo "| [Big Buck Bunny](https://peach.blender.org/) 2160p 60 fps, download.blender.org/demo/movies/BBB/ | CC-BY 3.0 | (c) copyright 2008, Blender Foundation / www.bigbuckbunny.org | $(shasum -a 256 "$SRC/bbb_sunflower_2160p_60fps_normal.mp4.zip" | cut -c1-16)... |"
  echo "| [Sintel](https://durian.blender.org/) trailer 1080p, download.blender.org/durian/trailer/ | CC-BY 3.0 | (c) copyright Blender Foundation / durian.blender.org | $(shasum -a 256 "$SRC/sintel_trailer-1080p.mp4" | cut -c1-16)... |"
  echo "| lottie_heavy.json | generated (corpus.py), no third-party content | - | - |"
  echo
  echo "Every clip, loop, animated image and still below is cut and"
  echo "re-encoded from those sources; the licences carry over."
  echo
  echo '```'
  "$PY" -c 'import json,sys
for e in json.load(open(sys.argv[1]))["entries"]:
    print(e["file"], e["kind"], e.get("codec"), "%sx%s" % (e.get("width"), e.get("height")),
          e.get("fps"), e.get("bitrate"), e.get("duration"), e["size"])' "$OUT/manifest.json"
  echo '```'
} >"$OUT/SOURCES.md"
cp "$OUT/SOURCES.md" "$ROOT/SOURCES.md"
echo "corpus ready: $OUT ($(du -sh "$OUT" | cut -f1)); push with tool/lab/push_media.sh $OUT"
