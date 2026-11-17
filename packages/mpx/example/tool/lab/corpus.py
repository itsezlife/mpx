"""The lab's media corpus on the host.

    python3 tool/lab/corpus.py manifest <dir> [public.json]  # (re)writes <dir>/manifest.json
    python3 tool/lab/corpus.py lottie <out.json>             # a heavy generated Lottie

`manifest` probes every media file of <dir> with ffprobe and writes the
manifest the app reads: file, kind, codec, width, height, fps, bitrate,
duration, size; the entries of [public.json] (tool/lab/public_corpus.json:
media at stable public URLs, with their licences) are added as they are,
and the app fetches those from the internet. A kind already in the
manifest is kept, so a hand edit
(a silent clip played as `video`) survives; a new file gets one from its
type: a video with an audio stream is `video` (the platform player with
sound in the viewer), a silent one `loop` (the frame path), GIF and WebP
`animated`, JSON `lottie`, other images `still`. Prints the table.

`lottie` writes a Lottie of many animated layers, heavy by construction:
generated here, so it carries no third party's licence.
"""

import json
import math
import os
import subprocess
import sys

# Hosts such as Wikimedia refuse requests without a descriptive agent.
USER_AGENT = "mpx-example-lab/1.0 (media performance lab)"
KINDS = ("video", "loop", "animated", "lottie", "still")
SKIP = {"manifest.json", "SOURCES.md"}
IMAGES = {".png", ".jpg", ".jpeg"}
ANIMATED = {".gif", ".webp"}


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_streams",
         "-show_format", path],
        capture_output=True, text=True,
    )
    return json.loads(out.stdout or "{}") if out.returncode == 0 else {}


def describe_url(url, kind):
    """A public entry: ffprobe reads the headers over HTTP."""
    import urllib.parse
    import urllib.request
    name = urllib.parse.unquote(url.rsplit("/", 1)[-1])
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
    size = int(urllib.request.urlopen(request).headers.get("content-length") or 0)
    entry = describe(url, kind, name=name, size=size)
    entry["url"] = url
    return entry


def describe(path, kind=None, name=None, size=None):
    name = name or os.path.basename(path)
    ext = os.path.splitext(name)[1].lower()
    entry = {"file": name, "size": size if size is not None else os.path.getsize(path)}
    if ext == ".json":
        doc = json.load(open(path))
        fr = doc.get("fr") or 0
        entry.update(kind=kind or "lottie", codec="lottie", width=doc.get("w"),
                     height=doc.get("h"), fps=fr,
                     duration=round((doc.get("op", 0) - doc.get("ip", 0)) / fr, 2) if fr else None)
        return entry
    info = probe(path)
    streams = info.get("streams", [])
    video = next((s for s in streams if s.get("codec_type") == "video"), None)
    audio = any(s.get("codec_type") == "audio" for s in streams)
    if video is None:
        return None
    num, _, den = (video.get("avg_frame_rate") or "0/1").partition("/")
    fps = float(num) / float(den) if den and float(den) else None
    duration = info.get("format", {}).get("duration") or video.get("duration")
    bitrate = info.get("format", {}).get("bit_rate")
    if kind is None:
        kind = ("still" if ext in IMAGES else "animated" if ext in ANIMATED
                else "video" if audio else "loop")
    entry.update(
        kind=kind,
        codec=video.get("codec_name"),
        width=video.get("width"),
        height=video.get("height"),
        fps=round(fps, 3) if fps else None,
        bitrate=int(bitrate) if bitrate else None,
        duration=round(float(duration), 2) if duration else None,
    )
    return entry


def manifest(folder, public=None):
    path = os.path.join(folder, "manifest.json")
    known = {}
    if os.path.exists(path):
        known = {e["file"]: e.get("kind") for e in json.load(open(path)).get("entries", [])}
    entries = []
    for name in sorted(os.listdir(folder)):
        full = os.path.join(folder, name)
        if name in SKIP or name.startswith(".") or not os.path.isfile(full):
            continue
        entry = describe(full, known.get(name))
        if entry is None:
            print(f"  skipped {name}: no picture stream", file=sys.stderr)
            continue
        if entry["kind"] not in KINDS:
            sys.exit(f"{name}: kind must be one of {KINDS}")
        entries.append(entry)
    if public:
        local = {e["file"] for e in entries}
        for e in json.load(open(public))["entries"]:
            if e["file"] in local:
                sys.exit(f"{e['file']}: both a local file and a public entry")
            entries.append(e)
    if not entries:
        sys.exit(f"no media in {folder}")
    json.dump({"entries": entries}, open(path, "w"), indent=1)
    for e in entries:
        br = f"{e['bitrate'] // 1000}kbps" if e.get("bitrate") else "?"
        print(f"  {e['file']:40} {e['kind']:8} {e.get('codec') or '?':6} "
              f"{e.get('width')}x{e.get('height')} {e.get('fps')}fps {br} "
              f"{e.get('duration') or '?'}s {e['size']}B {'url' if e.get('url') else 'local'}")
    print(f"{len(entries)} entries -> {path}")


def lottie(out, layers=80, frames=300, size=512):
    """Many shape layers, each a star path with animated position,
    rotation, scale and fill: every frame repaints all of them."""
    def kf(t, s):
        return {"t": t, "s": s, "i": {"x": [0.5], "y": [0.5]}, "o": {"x": [0.5], "y": [0.5]}}

    def star(points, outer, inner):
        verts = []
        for k in range(points * 2):
            r = outer if k % 2 == 0 else inner
            a = math.pi * k / points
            verts.append([r * math.cos(a), r * math.sin(a)])
        zero = [[0, 0]] * len(verts)
        return {"ty": "sh", "ks": {"a": 0, "k": {"c": True, "v": verts, "i": zero, "o": zero}}}

    out_layers = []
    for n in range(layers):
        phase = n / layers
        cx, cy = size * (0.1 + 0.8 * ((n * 37) % 100) / 100), size * (0.1 + 0.8 * ((n * 61) % 100) / 100)
        color = [0.5 + 0.5 * math.sin(6.28 * phase), 0.5 + 0.5 * math.sin(6.28 * phase + 2), 0.5 + 0.5 * math.sin(6.28 * phase + 4), 1]
        out_layers.append({
            "ty": 4, "ind": n + 1, "ip": 0, "op": frames, "st": 0, "sr": 1, "ao": 0, "ddd": 0,
            "nm": f"star{n}",
            "ks": {
                "o": {"a": 0, "k": 80},
                "r": {"a": 1, "k": [kf(0, [0]), kf(frames, [360 * (1 if n % 2 else -1)])]},
                "p": {"a": 1, "k": [kf(0, [cx, cy, 0]), kf(frames / 2, [size - cx, size - cy, 0]), kf(frames, [cx, cy, 0])]},
                "a": {"a": 0, "k": [0, 0, 0]},
                "s": {"a": 1, "k": [kf(0, [60, 60, 100]), kf(frames / 2, [140, 140, 100]), kf(frames, [60, 60, 100])]},
            },
            "shapes": [{
                "ty": "gr", "nm": "g",
                "it": [
                    star(5 + n % 7, 40 + n % 30, 15 + n % 10),
                    {"ty": "fl", "c": {"a": 1, "k": [kf(0, color), kf(frames, color[1:3] + color[:1] + [1])]}, "o": {"a": 0, "k": 100}, "r": 1},
                    {"ty": "st", "c": {"a": 0, "k": [0, 0, 0, 1]}, "o": {"a": 0, "k": 100}, "w": {"a": 0, "k": 2}, "lc": 2, "lj": 2},
                    {"ty": "tr", "p": {"a": 0, "k": [0, 0]}, "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]}, "r": {"a": 0, "k": 0}, "o": {"a": 0, "k": 100}},
                ],
            }],
        })
    doc = {"v": "5.7.0", "fr": 60, "ip": 0, "op": frames, "w": size, "h": size,
           "nm": "lab-heavy", "ddd": 0, "assets": [], "layers": out_layers}
    json.dump(doc, open(out, "w"), separators=(",", ":"))
    print(f"{out}: {layers} layers, {frames} frames at 60 fps, {os.path.getsize(out)}B")


if __name__ == "__main__":
    if len(sys.argv) in (3, 4) and sys.argv[1] == "manifest":
        manifest(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
    elif len(sys.argv) == 3 and sys.argv[1] == "lottie":
        lottie(sys.argv[2])
    else:
        sys.exit(__doc__)
