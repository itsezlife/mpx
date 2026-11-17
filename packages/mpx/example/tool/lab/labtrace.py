"""What reached the screen in a lab trace; shared by seen.py and session.py.

`Capture(trace, tape)` reads one system trace of the lab build:

- `shown`: for every display refresh, the app frame on screen (the buffer
  the compositor latched) with its timings and the lab's marks at its
  render: the content position (`LABy`), the viewer's morph progress
  (`LABm`) and the route transition (`LABr`);
- `events`: the app's semantic marks (`LABe <what> f=<frame>`);
- `pointer`: the tape's input on the trace clock (from the replay's
  `LABtape0` mark), the windows where a finger was down or just lifted.
  Without a tape (`-`) the app's `deliverInputEvent` slices stand in: a
  smoke test only, since the app's own messages never count as touches
  then but synthetic input has no real timing either.

Every count comes with its denominator; a 0 of 0 is no result.

Needs `pip install perfetto`.
"""

import bisect
import collections
import json
import statistics

from perfetto.trace_processor import TraceProcessor

APP = "dev.mpx.mpx_example"
POINTER_WINDOW_NS = 60e6
UP = 6  # PointerChange.up


class Capture:
    def __init__(self, trace_path, tape_path, hz=None):
        self.tp = TraceProcessor(trace=trace_path)
        q = self.q
        procs = q(f"select upid from process where name like '{APP}%' order by upid desc limit 1")
        if not procs:
            raise SystemExit(f"no {APP} process in the trace")
        upid = self.upid = procs[0].upid
        self.main = q(f"select utid from thread where upid={upid} and tid=(select pid from process where upid={upid})")[0].utid
        raster = q(f"select utid from thread where upid={upid} and name like '%raster%' limit 1")
        if not raster:
            raise SystemExit("no raster thread: was the app traced (atrace_apps)?")
        self.raster = raster[0].utid

        self.refreshes = [r.ts for r in q(
            "select ts from actual_frame_timeline_slice where upid=(select upid from "
            "process where name='/system/bin/surfaceflinger') order by ts"
        )]
        gaps = [b - a for a, b in zip(self.refreshes, self.refreshes[1:]) if b - a < 50e6]
        self.vsync_ns = 1e9 / hz if hz else (min(statistics.median(gaps), 1e9 / 30) if gaps else 1e9 / 120)
        self.hz = 1e9 / self.vsync_ns

        self.marks = {name: self._marks(name) for name in ("LABy", "LABm", "LABr")}
        self.events = [
            (r.ts, r.name[len("LABe "):])
            for r in q("select ts, name from slice where name like 'LABe %' order by ts")
        ]
        self.frames = self._frames()
        latches = [f["latch"] for f in self.frames]
        self.shown = []
        for t in self.refreshes:
            i = bisect.bisect_right(latches, t) - 1
            self.shown.append((t, self.frames[i] if i >= 0 else None))
        self.shown_ts = [t for t, _ in self.shown]
        self.pointer, self.ups, self.backs = self._pointer(tape_path)
        self.main_top = q(
            f"select s.ts, s.dur, s.name from slice s join thread_track tt on s.track_id=tt.id "
            f"where tt.utid={self.main} and s.depth=0 order by s.ts"
        )
        self.main_top_ts = [r.ts for r in self.main_top]

    def q(self, sql):
        return list(self.tp.query(sql))

    def _marks(self, name):
        rows = self.q(f"select ts, name from slice where name like '{name} %' order by ts")
        return [(r.ts, float(r.name[len(name) + 1:])) for r in rows]

    def _slices(self, utid, name, outermost=True):
        """(start, end) of the `name` slices on a thread; with outermost, a
        slice inside another of the same name is dropped."""
        rows = self.q(
            f"select s.ts, s.dur from slice s join thread_track tt on s.track_id=tt.id "
            f"where tt.utid={utid} and s.name='{name}' order by s.ts"
        )
        spans = []
        for r in rows:
            if outermost and spans and r.ts < spans[-1][1]:
                continue
            spans.append((r.ts, r.ts + r.dur))
        return spans

    @staticmethod
    def _busy(spans, a, b):
        i = max(0, bisect.bisect_left(spans, (a, a)) - 1)
        total = 0
        while i < len(spans) and spans[i][0] < b:
            total += max(0, min(b, spans[i][1]) - max(a, spans[i][0]))
            i += 1
        return total / 1e6

    def _frames(self):
        """Each presented app frame: when it was latched, its render time,
        its timings in ms (UI, raster wait and the snapshots in it, draw,
        queue to latch) and the marks at its render."""
        ui = self._slices(self.main, "VsyncProcessCallback")
        if not ui:
            raise SystemExit("no VsyncProcessCallback slices: the app's engine was not traced")
        ui_starts = [a for a, _ in ui]
        renders = [a for a, _ in self._slices(self.main, "Animator::Render", outermost=False)]
        draws = self._slices(self.raster, "GPURasterizer::Draw")
        snapshots = self._slices(self.raster, "SnapshotDisplayList (impeller)")
        queued = [a for a, _ in self._slices(self.raster, "queueBuffer")]
        tracks = self.q(
            f"select id from counter_track where name like 'BufferTX - %SurfaceView[{APP}%' limit 1"
        )
        if not tracks:
            raise SystemExit("no BufferTX counter for the app's surface: was gfx traced?")
        counter = [(r.ts, r.value) for r in self.q(
            f"select ts, value from counter where track_id={tracks[0].id} order by ts")]
        # A buffer is latched when the count of queued buffers drops.
        latches = [t for (t, v), (_, prev) in zip(counter[1:], counter[:-1]) if v < prev]
        frames = []
        li = ri = 0
        for d0, d1 in draws:
            while ri + 1 < len(renders) and renders[ri + 1] < d0 and renders[ri] < d0 - 100e6:
                ri += 1  # a tree never drawn (resynchronise)
            if ri >= len(renders) or renders[ri] > d0:
                continue
            r = renders[ri]
            ri += 1
            k = bisect.bisect_left(queued, d0)
            if k >= len(queued) or queued[k] > d1 + 5e6:
                continue
            while li < len(latches) and latches[li] < queued[k]:
                li += 1
            if li >= len(latches):
                break
            j = bisect.bisect_right(ui_starts, r) - 1
            frames.append(dict(
                latch=latches[li], render=r, vsync=ui[j][0],
                ui=(ui[j][1] - ui[j][0]) / 1e6,
                wait=(d0 - r) / 1e6,
                snap=self._busy(snapshots, r, d0),
                draw=(d1 - d0) / 1e6,
                queue=(latches[li] - queued[k]) / 1e6,
                **{name: self._mark_at(name, r) for name in self.marks},
            ))
            li += 1
        return frames

    def _mark_at(self, name, t):
        """The latest `name` mark at or before t, as (ts, value), or None."""
        marks = self.marks[name]
        i = bisect.bisect_right(marks, (t, float("inf"))) - 1
        return marks[i] if i >= 0 else None

    def _pointer(self, tape_path):
        if tape_path == "-":
            rows = self.q(
                f"select s.ts from slice s join thread_track tt on s.track_id=tt.id join thread "
                f"using(utid) where thread.upid={self.upid} and s.name like 'deliverInputEvent%' "
                f"order by s.ts"
            )
            times = [r.ts for r in rows]
            return times, [], []
        tape = json.load(open(tape_path))
        rows = tape["rows"]
        pointer_rows = [r for r in rows if isinstance(r, list)]
        if not rows:
            return [], [], []
        zero = self.q("select ts from slice where name='LABtape0' order by ts desc limit 1")
        if not zero:
            raise SystemExit("no LABtape0 mark: the trace missed the replay's start")
        t0 = min(r[0] if isinstance(r, list) else r["t"] for r in rows)
        offset = zero[0].ts - t0 * 1000
        pointer = sorted(offset + r[0] * 1000 for r in pointer_rows)
        ups = sorted(offset + r[0] * 1000 for r in pointer_rows if r[1] == UP)
        backs = sorted(offset + r["t"] * 1000 for r in rows if isinstance(r, dict))
        return pointer, ups, backs

    def pointer_near(self, t):
        lo = bisect.bisect_left(self.pointer, t - POINTER_WINDOW_NS)
        return bisect.bisect_left(self.pointer, t + POINTER_WINDOW_NS) > lo

    def last_input_before(self, t, within=2e9):
        """The last finger lift or Back before t (within 2 s), or None."""
        best = None
        for times in (self.ups, self.backs, self.pointer if not self.ups else []):
            i = bisect.bisect_right(times, t) - 1
            if i >= 0 and t - times[i] <= within and (best is None or times[i] > best):
                best = times[i]
        return best

    def refresh_range(self, a, b):
        """Indices of the refreshes in [a, b]."""
        return range(bisect.bisect_left(self.shown_ts, a), bisect.bisect_right(self.shown_ts, b))

    # --- Causes ---------------------------------------------------------------

    def busiest_between(self, a, b):
        i = max(0, bisect.bisect_left(self.main_top_ts, a) - 1)
        best = ("idle", 0)
        while i < len(self.main_top) and self.main_top[i].ts < b:
            r = self.main_top[i]
            d = (min(b, r.ts + r.dur) - max(a, r.ts)) / 1e6
            if d > best[1] and r.name != "VsyncProcessCallback":
                best = (r.name, d)
            i += 1
        return best

    def frame_cause(self, prev, cur):
        """Why `cur` (the frame after `prev`) reached the screen late or stale."""
        v = self.vsync_ns
        if cur["vsync"] - prev["vsync"] > 1.5 * v:
            name, _ = self.busiest_between(prev["vsync"] + v, cur["vsync"])
            return f"UI started a vsync late (main thread: {name})"
        budget = v / 1e6
        return (
            "UI long" if cur["ui"] > 0.8 * budget
            else "raster behind, snapshots" if cur["wait"] > 3 and cur["snap"] > cur["wait"] / 2
            else "raster behind" if cur["wait"] > 3
            else "raster long" if cur["draw"] > 0.6 * budget
            else "latched late" if cur["queue"] > v * 1.3 / 1e6
            else "on time"
        )

    # --- Metrics --------------------------------------------------------------

    def scroll(self, a, b, mark="LABy"):
        """Visible hitches while the content moves in [a, b]: gliding (no
        finger near) by the content step against its neighbours' median,
        under the finger by frame cadence. Returns a Hitches."""
        out = Hitches()
        shown = self.shown
        v = self.vsync_ns
        lo, hi = self.refresh_range(a, b).start, self.refresh_range(a, b).stop

        def y(f):
            m = f[mark] if f else None
            return m[1] if m and m[0] >= a else None

        for i in range(max(4, lo), min(len(shown) - 4, hi)):
            seq = [shown[k][1] for k in range(i - 4, i + 5)]
            ys = [y(s) for s in seq]
            if any(x is None for x in ys):
                continue
            if shown[i + 4][0] - shown[i - 4][0] > 8.6 * v:
                continue  # the display paused
            if self.pointer_near(shown[i][0]):
                continue
            steps = [ys[k] - ys[k - 1] for k in range(1, 9)]
            around = steps[:3] + steps[4:7]
            typical = statistics.median(around)
            if abs(typical) < 1.0 or any(x * typical < 0 for x in around):
                continue  # not in steady motion
            out.glide_judged += 1
            ratio = steps[3] / typical
            if 0.5 <= ratio <= 1.5:
                continue
            cur, prev = seq[4], seq[3]
            if cur is prev:
                why = f"repeat ({self.frame_cause(prev, seq[5])})"
            else:
                late = cur if cur["vsync"] - prev["vsync"] >= prev["vsync"] - seq[2]["vsync"] else prev
                before = prev if late is cur else seq[2]
                moved = "barely moved" if ratio < 0.5 else "jumped ahead"
                why = f"{moved} ({self.frame_cause(before, late)})"
            out.glide_flags.append((i, why))

        for i in range(max(2, lo), min(len(shown) - 2, hi)):
            t, cur = shown[i]
            prev = shown[i - 1][1]
            if y(cur) is None or y(prev) is None or not self.pointer_near(t):
                continue
            ends = [y(shown[k][1]) for k in (i - 2, i + 2)]
            if None in ends or abs(ends[1] - ends[0]) < 1.0 or t - shown[i - 1][0] > 1.5 * v:
                continue  # not moving, or the display paused
            out.drag_judged += 1
            if cur is prev:
                nxt = shown[i + 1][1]
                if nxt is not None and nxt is not cur:
                    out.drag_flags.append((i, f"repeat ({self.frame_cause(cur, nxt)})"))
            elif cur["vsync"] - prev["vsync"] > 1.5 * v:
                k = bisect.bisect_right(self.pointer, prev["vsync"])
                if k < len(self.pointer) and self.pointer[k] < cur["vsync"] - v:
                    out.drag_flags.append((i, self.frame_cause(prev, cur)))
        out.hz = self.hz
        return out

    def progress(self, mark, a, b):
        """Hitches of an animation's progress mark in [a, b]: a refresh whose
        step is outside 0.5-1.5x the median of the two steps either side
        (a repeat is a step of 0). Returns (judged, flags, first moving
        refresh time or None)."""
        idx = list(self.refresh_range(a, b))
        vals = []
        for i in idx:
            f = self.shown[i][1]
            m = f[mark] if f else None
            vals.append(m[1] if m and m[0] >= a else None)
        known = [(i, val) for i, val in zip(idx, vals) if val is not None]
        first_moving = next(
            (self.shown[i][0] for i, val in known if val != known[0][1]), None)
        judged, flags = 0, []
        for k in range(3, len(known) - 2):
            steps = [known[j][1] - known[j - 1][1] for j in range(k - 2, k + 3)]
            around = steps[:2] + steps[3:]
            typical = statistics.median(around)
            if abs(typical) < 1e-3:
                continue
            judged += 1
            ratio = steps[2] / typical
            if 0.5 <= ratio <= 1.5:
                continue
            i = known[k][0]
            cur, prev = self.shown[i][1], self.shown[i - 1][1]
            nxt = self.shown[i + 1][1] if i + 1 < len(self.shown) else None
            if cur is prev and nxt is not None:
                flags.append((i, f"repeat ({self.frame_cause(prev, nxt)})"))
            else:
                flags.append((i, f"{'barely moved' if ratio < 0.5 else 'jumped ahead'} ({self.frame_cause(prev, cur)})"))
        return judged, flags, first_moving

    def first_shown_after(self, t):
        """When the first frame rendered at or after t reached the screen."""
        for ts, f in self.shown[bisect.bisect_left(self.shown_ts, t):]:
            if f and f["render"] >= t:
                return ts
        return None


def clusters(flagged):
    """Flagged refreshes at most one apart are one hitch, named by its first."""
    events, last = collections.Counter(), None
    for i, why in flagged:
        if last is None or i - last > 2:
            events[why] += 1
        last = i
    return events


class Hitches:
    def __init__(self):
        self.glide_judged = 0
        self.drag_judged = 0
        self.glide_flags = []
        self.drag_flags = []
        self.hz = 120

    def add(self, other):
        self.glide_judged += other.glide_judged
        self.drag_judged += other.drag_judged
        self.glide_flags += other.glide_flags
        self.drag_flags += other.drag_flags
        self.hz = other.hz

    def line(self):
        glide, drag = clusters(self.glide_flags), clusters(self.drag_flags)
        n, m = sum(glide.values()), sum(drag.values())
        gs, ds = self.glide_judged / self.hz, self.drag_judged / self.hz
        return (
            f"gliding {gs:.1f} s ({self.glide_judged} refreshes): {n} hitches = {n / max(gs, 1e-9):.2f}/s; "
            f"under the finger {ds:.1f} s: {m} = {m / max(ds, 1e-9):.2f}/s; "
            f"all {(n + m) / max(gs + ds, 1e-9):.2f}/s of motion"
        ), glide, drag
