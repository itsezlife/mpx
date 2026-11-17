"""The player's way to its first frame in a lab trace, out of its marks.

Every mark is a slice named `mpx.player <stage> <id> [detail]`: zero
length for a point, or the span of the work for a section. Three ids
follow one player:

- `k…` the media key: `lease` (detail cold / warm / shown: whether the
  pool had an engine for it and whether it had shown a frame) and
  `texture` (a view built the player's texture in place of its stand-in);
- `e…` the Dart engine: `engine` (detail: its key), `prepare`,
  `published` (its bytes published to the native reader), `create-sent`,
  `created` (detail: the platform player), `phase` (detail: the phase it
  entered), `first-frame-received`;
- `p…` the platform player (Android sections): `create`, `exo-build`,
  `set-surface`, `prepare`, `source-open` (one per data source open;
  detail `at=<byte>`), `source-first-read` (the first read after an open,
  which ends when bytes came), `part-open` (HLS: Dart answering a part),
  `video-decoder` / `audio-decoder` (detail `init=<ms>ms at=<elapsed
  realtime ms>`), `ready`, `first-frame` (the first frame rendered into
  the texture).

`PlayerMarks.open_stages(input, end)` follows the first lease after the
input: its engine (made in the open, or the one the key already had) and
that engine's platform player, and returns each stage's time from the
input. A stage before the input (a warm player) is left out.
"""

import bisect
import collections

# (label, stage, id kind, which time of the slice, detail filter)
STAGES = [
    ("lease", "lease", "k", "start", None),
    ("engine prepare", "prepare", "e", "start", None),
    ("published", "published", "e", "start", None),
    ("create sent", "create-sent", "e", "start", None),
    ("native create", "create", "p", "start", None),
    ("exo built", "exo-build", "p", "end", None),
    ("surface set", "set-surface", "p", "end", None),
    ("exo prepare", "prepare", "p", "end", None),
    ("native created", "create", "p", "end", None),
    ("created (dart)", "created", "e", "start", None),
    ("source open", "source-open", "p", "start", None),
    ("source opened", "source-open", "p", "end", None),
    ("first bytes", "source-first-read", "p", "end", None),
    ("audio decoder", "audio-decoder", "p", "at", None),
    ("video decoder", "video-decoder", "p", "at", None),
    ("ready (native)", "ready", "p", "start", None),
    ("ready (dart)", "phase", "e", "start", "ready"),
    ("first frame (native)", "first-frame", "p", "start", None),
    ("first frame (dart)", "first-frame-received", "e", "start", None),
    ("texture built", "texture", "k", "start", None),
    ("texture on screen", "texture", "k", "shown", None),
    ("audio decoder init", "audio-decoder", "p", "init", None),
    ("video decoder init", "video-decoder", "p", "init", None),
    ("source opens", "source-open", "p", "count", None),
]

Mark = collections.namedtuple("Mark", "ts dur stage id detail")


class PlayerMarks:
    def __init__(self, cap):
        self.cap = cap
        self.marks = []
        for r in cap.q("select ts, dur, name from slice where name like 'mpx.player %' order by ts"):
            parts = r.name.split(" ", 3)
            if len(parts) < 3:
                continue
            self.marks.append(Mark(r.ts, max(r.dur or 0, 0), parts[1], parts[2],
                                   parts[3] if len(parts) > 3 else ""))
        self.ts = [m.ts for m in self.marks]
        self.by_id = collections.defaultdict(list)
        for m in self.marks:
            self.by_id[m.id].append(m)

    def _first(self, stage, id, a, b, detail=None):
        for m in self.by_id.get(id, ()):
            if a <= m.ts < b and m.stage == stage and (detail is None or m.detail.startswith(detail)):
                return m
        return None

    def open_stages(self, base, end):
        """({label: ns from base}, [notes]) for the player the first lease
        in [base, end) took."""
        lease = None
        for m in self.marks[bisect.bisect_left(self.ts, base):]:
            if m.ts >= end:
                break
            if m.stage == "lease":
                lease = m
                break
        if lease is None:
            return {}, ["no lease"]
        k = lease.id
        engine = None
        for m in self.marks:
            if m.stage == "engine" and m.detail == k and m.ts < end:
                engine = m  # the latest one before the end
        e = engine.id if engine else None
        created = self._first("created", e, 0, end) if e else None
        p = created.detail if created else None
        ids = {"k": k, "e": e, "p": p}
        out = {}
        native = []
        for label, stage, kind, which, detail in STAGES:
            id = ids[kind]
            if id is None:
                continue
            if which == "count":
                n = sum(1 for m in self.by_id.get(id, ()) if base <= m.ts < end and m.stage == stage)
                if n:
                    out[label] = n * 1e6  # printed as a count
                continue
            m = self._first(stage, id, base, end, detail)
            if m is None:
                continue
            if which == "start":
                t = m.ts
            elif which == "end":
                t = m.ts + m.dur
            elif which == "shown":
                t = self.cap.first_shown_after(m.ts)
            else:
                fields = dict(f.split("=", 1) for f in m.detail.split() if "=" in f)
                if which == "init":
                    out[label] = float(fields.get("init", "0ms")[:-2]) * 1e6
                    native.append(f"{stage} {m.detail.split()[-1]}")
                    continue
                # The decoder's own time, reported later on the main thread;
                # elapsed realtime is the trace's boot clock in ms.
                t = m.ts
                at = fields.get("at")
                if at and at.endswith("ms") and abs(float(at[:-2]) * 1e6 - m.ts) < 3e9:
                    t = float(at[:-2]) * 1e6
            if t is not None and t >= base:
                out[label] = t - base
        notes = [f"lease {k} {lease.detail}", f"engine {e or '-'}", f"player {p or '-'}"] + native
        return out, notes
