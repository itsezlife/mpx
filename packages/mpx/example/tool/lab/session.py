"""A replayed session split into segments, each judged by what reached the
screen.

    python3 tool/lab/session.py <trace.pftrace> <tape.json | -> [--hz 120]

The app's semantic marks (`LABe`, see the README) cut the trace into
segments; each kind has its own metric and denominator:

- scroll (`scroll start` .. `scroll end`): visible hitches per second of
  motion, gliding and under the finger, by cause (seen.py's rule);
- viewer open (`viewer open-start` .. `viewer morph-end`): from the input
  (the last finger lift before it) to the first viewer frame on screen, to
  the first frame where the morph moved, and to the player's first frame;
  morph hitches: refreshes where the morph's progress (`LABm`) failed to
  advance or jumped, of the refreshes judged. Then the player's way there,
  stage by stage from the same input, out of the player's own marks
  (`mpx.player <stage> <id>`, see player_stages.py);
- viewer close (`viewer close-start` .. `viewer close-end`): input to the
  first moving frame, morph hitches, and the time from the close's end
  until the card's own picture moves again (`card moved`);
- route (a page pushed or popped): the transition's hitches (`LABr`) in
  its first second; for the feeds, the time from the input to the first
  frame with content (`feed first-content`).

Coverage guards the numbers: the app's `coverage` line (stress items that
reached a picture, video frames decoded, per kind) of this run, read from
the lab.txt beside the trace, against the tape's recording (the lab.txt
beside the tape). A run that drew much less than its recording is flagged
COVERAGE DROPPED: its hitches are not comparable.

Prints one summary table, then one line per segment, then the player
stages of every viewer open with their median and max. Exits non-zero when
the trace holds no segment at all.
"""

import collections
import os
import statistics
import sys

from labtrace import Capture, Hitches, clusters
from player_stages import PlayerMarks, STAGES

args = sys.argv[1:]
hz = None
if "--hz" in args:
    i = args.index("--hz")
    hz = float(args[i + 1])
    del args[i:i + 2]
if len(args) != 2:
    sys.exit(__doc__)
cap = Capture(args[0], args[1], hz)
V = cap.vsync_ns


def ms(ns):
    return "-" if ns is None else f"{ns / 1e6:.0f}"


def word(text, i):
    parts = text.split()
    return parts[i] if len(parts) > i else ""


events = cap.events
segments = []  # (kind, start ts, line)
scroll_all = Hitches()
morph = collections.defaultdict(lambda: [0, []])  # kind -> [judged, flags]
lat = collections.defaultdict(list)  # name -> [ns]
counts = collections.Counter()
player_marks = PlayerMarks(cap)
opens = []  # (open ts, tap or None, {stage label: ns from the input}, notes)


def next_event(prefix, after, before=float("inf")):
    for ts, text in events:
        if after <= ts < before and text.startswith(prefix):
            return ts, text
    return None, None


for n, (ts, text) in enumerate(events):
    if text.startswith("scroll start"):
        end, _ = next_event("scroll end", ts)
        end = end if end is not None else ts + 10e9
        h = cap.scroll(ts, end + 2 * V)
        scroll_all.add(h)
        counts["scroll"] += 1
        line, glide, drag = h.line()
        causes = ", ".join(f"{k} {w}" for w, k in (glide + drag).most_common(3))
        segments.append(("scroll", ts, f"scroll {word(text, 2)} {ms(end - ts)} ms: {line}"
                         + (f" [{causes}]" if causes else "")))

    elif text.startswith("viewer open-start"):
        close, _ = next_event("viewer close-start", ts)
        end, _ = next_event("viewer morph-end", ts, close or float("inf"))
        stop = end if end is not None else (close or ts + 2e9)
        tap = cap.last_input_before(ts)
        first = cap.first_shown_after(ts)
        judged, flags, moving = cap.progress("LABm", ts, stop + 3 * V)
        player, _ = next_event("viewer first-player-frame", ts, close or float("inf"))
        counts["viewer open"] += 1
        morph["viewer open"][0] += judged
        morph["viewer open"][1] += flags
        base = tap if tap is not None else ts
        for name, t in (("open: first content", first), ("open: first moving", moving),
                        ("open: player frame", player)):
            if t is not None:
                lat[name].append(t - base)
        stages, notes = player_marks.open_stages(base, close or ts + 10e9)
        opens.append((ts, tap, stages, notes))
        hitches = sum(clusters(flags).values())
        segments.append(("viewer open", ts,
                         f"viewer open {word(text, 2)} {word(text, 3)}: input->content {ms(first and first - base)} ms, "
                         f"->moving {ms(moving and moving - base)} ms, ->player frame {ms(player and player - base)} ms; "
                         f"morph hitches {hitches} of {judged} refreshes"
                         + ("" if tap is not None else " (no input found: from the open mark)")))

    elif text.startswith("viewer close-start"):
        end, _ = next_event("viewer close-end", ts)
        stop = end if end is not None else ts + 2e9
        tap = cap.last_input_before(ts)
        judged, flags, moving = cap.progress("LABm", ts, stop + 3 * V)
        nxt, _ = next_event("viewer open-start", stop)
        card_ts, card = next_event("card ", stop, (nxt or float("inf")) + 1)
        counts["viewer close"] += 1
        morph["viewer close"][0] += judged
        morph["viewer close"][1] += flags
        base = tap if tap is not None else ts
        if moving is not None:
            lat["close: first moving"].append(moving - base)
        card_text = "card -"
        if card and card.startswith("card moved"):
            lat["close: card moves"].append(card_ts - stop)
            card_text = f"card moves {ms(card_ts - stop)} ms after the close"
        elif card:
            card_text = f"card {word(card, 1)}"
        hitches = sum(clusters(flags).values())
        segments.append(("viewer close", ts,
                         f"viewer close {word(text, 2)}: input->moving {ms(moving and moving - base)} ms, "
                         f"morph hitches {hitches} of {judged} refreshes, {card_text}"))

    elif text.startswith("route push") or text.startswith("route pop"):
        name = word(text, 2)
        if name in ("viewer", "home"):
            continue
        tap = cap.last_input_before(ts)
        base = tap if tap is not None else ts
        judged, flags, moving = cap.progress("LABr", ts, ts + 1e9)
        kind = f"route {word(text, 1)}"
        counts[kind] += 1
        morph[kind][0] += judged
        morph[kind][1] += flags
        extra = ""
        if text.startswith("route push"):
            content_ts, content = next_event("feed ", ts + 1, ts + 15e9)
            while content and not (content.startswith("feed first-content") or content.startswith("feed no-content")):
                content_ts, content = next_event("feed ", content_ts + 1, ts + 15e9)
            if content and content.startswith("feed first-content"):
                shown = cap.first_shown_after(content_ts)
                if shown is not None:
                    lat[f"{name} open: first content"].append(shown - base)
                    extra = f", input->first content {ms(shown - base)} ms"
            elif content:
                extra = ", no content in 10 s"
        hitches = sum(clusters(flags).values())
        segments.append((kind, ts, f"{kind} {name}: transition hitches {hitches} of {judged} refreshes{extra}"))

if not segments:
    sys.exit("no segment marks in the trace: is it a lab build, and did the trace cover the run?")

def coverage(lab_txt):
    """The last `coverage` line of a lab.txt as {name: (shown, of) or n}."""
    try:
        lines = [l for l in open(lab_txt) if l.startswith("LAB coverage ")]
    except OSError:
        return None
    if not lines:
        return None
    out = {}
    for part in lines[-1].split()[2:]:
        if "=" not in part:
            continue
        name, value = part.split("=", 1)
        if "/" in value:
            a, b = value.split("/", 1)
            out[name] = (int(a), int(b))
        elif value.isdigit():
            out[name] = int(value)
    return out


def coverage_text(c):
    shown = c.get("content", (0, 0))
    kinds = " ".join(f"{k[8:]} {v[0]}/{v[1]}" for k, v in sorted(c.items())
                     if k.startswith("content.") and isinstance(v, tuple))
    frames = " ".join(f"{k[12:]} {v}" for k, v in sorted(c.items())
                      if k.startswith("videoFrames.") and isinstance(v, int))
    return (f"content {shown[0]}/{shown[1]} ({kinds}), video frames "
            f"{c.get('videoFrames', 0)}" + (f" ({frames})" if frames else ""))


def coverage_dropped(run, rec):
    """Why [run] covers less than its recording [rec], or None."""
    why = []
    for name, value in rec.items():
        mine = run.get(name)
        if isinstance(value, tuple) and value[0] > 0:
            got = mine[0] if isinstance(mine, tuple) else 0
            if got < 0.9 * value[0]:
                why.append(f"{name} {got} < {value[0]}")
        elif isinstance(value, int) and value > 0:
            got = mine if isinstance(mine, int) else 0
            if got < 0.5 * value:
                why.append(f"{name} {got} < {value}")
    return ", ".join(why) or None


run_cov = coverage(os.path.join(os.path.dirname(args[0]) or ".", "lab.txt"))
rec_cov = None if args[1] == "-" else coverage(
    os.path.join(os.path.dirname(args[1]) or ".", "lab.txt"))

span = (cap.refreshes[-1] - cap.refreshes[0]) / 1e9 if cap.refreshes else 0
print(f"run: {len(cap.refreshes)} refreshes at {cap.hz:.0f} Hz over {span:.1f} s, "
      f"{len(segments)} segments, input from {'the tape' if args[1] != '-' else 'the app (smoke)'}")
line, glide, drag = scroll_all.line()
print(f"  {'scroll':13} n={counts['scroll']:<3} {line}")
if run_cov is not None:
    print(f"  {'coverage':13} {coverage_text(run_cov)}")
    if rec_cov is not None:
        print(f"  {'recorded':13} {coverage_text(rec_cov)}")
        dropped = coverage_dropped(run_cov, rec_cov)
        if dropped:
            print(f"  COVERAGE DROPPED vs the recording: {dropped}")
else:
    print(f"  {'coverage':13} - (no coverage line beside the trace)")
for kind in ("viewer open", "viewer close", "route push", "route pop"):
    if not counts[kind]:
        continue
    judged, flags = morph[kind]
    hitches = sum(clusters(flags).values())
    what = "morph" if kind.startswith("viewer") else "transition"
    print(f"  {kind:13} n={counts[kind]:<3} {what} hitches {hitches} of {judged} refreshes judged")
for name, values in sorted(lat.items()):
    print(f"  {name:28} median {ms(statistics.median(values))} ms, max {ms(max(values))} ms, n={len(values)}")
for why, k in (glide + drag).most_common(5):
    print(f"  scroll cause {k:4d} {why}")
print("segments:")
for kind, ts, text in sorted(segments, key=lambda s: s[1]):
    print(f"  {(ts - cap.refreshes[0]) / 1e9 if cap.refreshes else 0:7.2f}s {text}")

if opens:
    print("player stages per viewer open, ms from the input (- not reached in the open):")
    labels = [label for label, *_ in STAGES]
    by_stage = collections.defaultdict(list)
    for ts, tap, stages, notes in opens:
        at = (ts - cap.refreshes[0]) / 1e9 if cap.refreshes else 0
        print(f"  {at:7.2f}s {' '.join(notes)}" + ("" if tap is not None else " (no input found)"))
        print("    " + ", ".join(f"{label} {ms(stages.get(label))}" for label in labels
                                   if label in stages))
        for label, value in stages.items():
            by_stage[label].append(value)
    print("player stages, ms from the input:")
    print(f"  {'stage':24} {'median':>7} {'max':>7} {'n':>4}")
    for label in labels:
        values = by_stage.get(label)
        if values:
            print(f"  {label:24} {ms(statistics.median(values)):>7} {ms(max(values)):>7} {len(values):>4}")
