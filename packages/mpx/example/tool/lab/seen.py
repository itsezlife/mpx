"""What the eye saw while content scrolled: visible hitches per refresh.

    python3 tool/lab/seen.py <trace.pftrace> <tape.json | -> [--hz 120]

For every display refresh it finds the app frame on screen (the buffer the
compositor latched) and the content position in it (the lab's `LABy <px>`
mark). During steady motion (the neighbouring steps agree in sign and size)
a refresh whose step is outside 0.5-1.5x the neighbours' median is a visible
hitch, labelled by what was late. Refreshes within 60 ms of a tape event
are judged by frame cadence instead (the finger is down, or just lifted). A
hitch is one or more flagged refreshes in a row; the rate is hitches per
second of judged motion.

The pointer windows come from the tape, never from the app's messages. `-`
takes the app's input dispatches instead: a smoke test only. Judges the
whole trace; session.py splits it into segments. Exits non-zero when no
refresh was in motion, since 0 hitches of 0 is no result.
"""

import sys

from labtrace import Capture

args = sys.argv[1:]
hz = None
if "--hz" in args:
    i = args.index("--hz")
    hz = float(args[i + 1])
    del args[i:i + 2]
if len(args) != 2:
    sys.exit(__doc__)
cap = Capture(args[0], args[1], hz)
h = cap.scroll(0, float("inf"))
line, glide, drag = h.line()
print(f"refreshes: {len(cap.refreshes)} at {cap.hz:.0f} Hz; {line}")
for why, k in glide.most_common():
    print(f"  glide {k:4d} {why}")
for why, k in drag.most_common():
    print(f"  drag  {k:4d} {why}")
if h.glide_judged + h.drag_judged == 0:
    sys.exit("no refresh in motion: wrong tape, no position marks, or the trace missed the replay")
