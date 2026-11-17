# Performance lab

Device scripts that judge the example by what reaches the screen of an
Android phone: a recorded session (the home grid, the viewer, the stress
feed) replayed from a fixed start, under a system trace, split into
segments, each with its own metric and denominator.

The app side is `lib/lab/`, compiled in only with
`--dart-define=MPX_LAB=true` (every call site sits behind the constant
`kMpxLab`, so a regular build carries none of it; the Android activity
registers its `lab.SET` receiver only when a lab build asks).

| Piece | Where |
| --- | --- |
| Switches and commands over `adb shell am broadcast -a lab.SET`, start switches as `am start` extras | `lib/lab/lab.dart` |
| Frame log in logcat: `LAB slow` (a frame over budget, with `span`, the vsync-to-raster-end time), `LAB burst`, `LAB summary` after a replay | `lib/lab/lab.dart` |
| Marks in the trace: `LABy <px>` scroll position, `LABm <0..1>` viewer morph, `LABr <0..1>` route transition, `LABe <what> f=<frame>` events | `lib/lab/lab.dart`, `lib/lab/lab_viewer.dart` |
| Pointer tape: record, replay on the frame clock, window and start-route check, system Back | `lib/lab/pointer_tape.dart` |
| Stress feed: `FeedListView` over the corpus, as the example's feed list | `lib/lab/stress_feed.dart` |
| Corpus and its loopback HTTP origin | `lib/lab/corpus.dart` |
| Network numbers: every request the stack sends, timed | `lib/lab/lab_net.dart` |

## Setup

```shell
cd packages/mpx/example
python3 -m venv .venv && .venv/bin/pip install perfetto   # the analysis
export PY=$PWD/.venv/bin/python
tool/lab/build.sh                 # profile APK with MPX_LAB, `adb install -r`
tool/lab/push_media.sh            # the public set, fetched from the internet
tool/lab/fetch_corpus.sh          # optional: 4K / HEVC / AV1 / VP9 transcodes
tool/lab/push_media.sh perf/lab/corpus/out   # those, plus the public set
```

`build.sh` never uninstalls: the phone keeps the app's data. Sessions,
builds' logs and the corpus land in `perf/lab/` (gitignored). `DEVICE`
picks the adb device; the only attached one by default.

## A typical round

```shell
tool/lab/watch.sh start s1        # fresh app on the home page; the user acts
tool/lab/watch.sh stop s1         # tape, trace, LAB log in perf/lab/s1/
RUNS=2 tool/lab/ab.sh base s1                          # arm A
RUNS=2 LAB_SET="textures=false" tool/lab/ab.sh tex s1  # arm B
RUNS=2 tool/lab/ab.sh base s1                          # A again, then B
```

Each replay restarts the app (a fresh process at the route the tape
starts on), prints the corpus, waits `SETTLE` seconds (3) for its media,
replays, and prints the app's frame summary and the segment report
(`session.py`). It fails when the build, the start, or the replay does
not happen: the app refuses a tape recorded in another window size,
inset or start route. Alternate the arms; a run more than 2 °C over its
arm's first is marked `HOT`.

What the tape holds: every pointer sample (taps, drags, flings, the
viewer's controls) and the system Back. Use either the in-app back arrow
or Back; both replay. A tape of the stress feed alone starts with
`LAB_OPEN=stress tool/lab/watch.sh start f1`.

| Script | Does |
| --- | --- |
| `build.sh [defines]` | profile build with `MPX_LAB`, installed over the app |
| `watch.sh start\|stop <s>` | records a session from a fresh start; `RECORD=1` adds a screen recording |
| `replay.sh <tape> <s>` | one replay of a tape from a fresh start, with its report |
| `ab.sh <label> <tape>` | `RUNS` replays (2) of one arm; `BUILD=1` builds first |
| `scenario.sh feed\|swipe <s>` | the stress feed's cold or warm open; a synthetic fling (smoke test only) |
| `session.py <trace> <tape>` | the per-segment report, with the player stages of each viewer open and page |
| `seen.py <trace> <tape>` | scroll hitches over the whole trace |
| `push_media.sh <dir>` | a folder as the device corpus (writes its manifest first) |
| `fetch_corpus.sh` | the public corpus, verified against `corpus.sha256` |

## Start switches and run-time switches

Start switches apply before the first frame, so both arms of an A/B share
one build:

| Variable | Does |
| --- | --- |
| `LAB_COLD=1` | deletes the media caches (bytes cache, Lottie frames) at start: a cold run |
| `LAB_OPEN=stress` | starts on the stress feed |
| `LAB_SET="k=v ..."` | any switch below, e.g. `items=80 kinds=video,loop distinct=false` |

| Key | Default | Switches |
| --- | --- | --- |
| `items` | 50 | stress feed items, read as it opens |
| `kinds` | all | `video,loop,animated,lottie,still`: the corpus kinds the feed cycles through |
| `distinct` | true | a key per item (its own bytes, decode and playback); false, one key per file, all items of a file share one playback |
| `textures` | true | playing Lottie and video may take platform textures |
| `video_cap` | scheduler's | clips the video scheduler advances per tick |
| `resampling` | false | pointer resampling |
| `origin` | `net` | start only: `net` fetches public entries from the internet and the folder's own files from the loopback origin; `local` serves every entry that has a file in the folder from the loopback origin |
| `throttle_kbps` | 0 | the loopback origin's bandwidth; 0 is unlimited |
| `latency_ms` | 0 | the loopback origin's delay before each first byte |
| `corpus` | on | start only: `off` ignores the device corpus |

At run time: `adb shell am broadcast -a lab.SET --es key items --es value 80`.
Commands: `open` (the stress feed), `home`, `jump --es value <index>`,
`state` (logs the switches), `net` (logs the network numbers), `record --es value true|false --es name <tape>`,
`replay --es name <tape>`.

## The corpus

A lab build reads `/sdcard/Android/data/dev.mpx.mpx_example/files/corpus/`:
`manifest.json` (`{"entries": [{"file", "kind", "url", "codec", "width",
"height", "fps", "bitrate", "duration", "size"}]}`) and the files it
names. With one, the home grid and the stress feed show the corpus;
without, the bundled fixtures.

Media goes through the stack as in production: the fetcher, the bytes
cache, ranged reads for the player. An entry with a `url` is fetched from
the internet; a file of the folder (camera clips, the transcodes) from a
loopback HTTP origin over the folder. `LAB_SET="origin=local"` serves
every entry that has a local copy from the loopback origin, with the
`throttle_kbps` and `latency_ms` switches: for when an A/B difference sits
inside the noise floor and network variance has to go.

Every run reports its network beside the frame metrics (`LAB net` lines,
at the head of the report): requests, failures, bytes, time to first byte
and download time (p50 / max), and per file its host, requests (ranged
ones apart), bytes and timings. A corpus entry with no request was served
from the cache or never shown; a `LAB_COLD=1` run starts with the caches
empty.

`tool/lab/public_corpus.json` lists the public set: media at stable direct
URLs with their licences (the Sintel and Big Buck Bunny trailers from
download.blender.org, CC BY 3.0, Blender Foundation; a rotating-earth GIF
from Wikimedia Commons, CC BY-SA 3.0, Marvel). It is H.264 and GIF only:
no stable public URL serves short HEVC, AV1, VP9 or 4K cuts, so those come
from `fetch_corpus.sh` as local files.

| Kind | Plays |
| --- | --- |
| `video` | a clip with sound: muted on the software decoder in lists, the platform player with sound in the viewer |
| `loop` | a silent clip (a GIF stand-in): the software decoder everywhere |
| `animated` | WebP or GIF |
| `lottie` | Lottie JSON |
| `still` | an image |

`push_media.sh` writes the manifest with ffprobe and adds the public set
(`PUBLIC=0` leaves it out); a file with an audio
stream is a `video`, a silent one a `loop`; edit `kind` in the manifest
and push again to change one. The app logs the corpus (`LAB corpus` lines,
with a fingerprint) at every start; each run's report begins with it, and
a replay on a corpus other than the tape's is flagged `CORPUS DIFFERS`.
Stress keys are named after their files: a file replaced under the same
name needs a `LAB_COLD=1` run.

The software decoder of this build decodes H.264, VP9 and GIF: HEVC and
AV1 clips play in the viewer on the platform player, and stay on their
placeholder in lists.

`fetch_corpus.sh` builds a reproducible local set from Blender open
movies (CC BY; see `perf/lab/corpus/SOURCES.md`), each download checked
against `corpus.sha256`: 2160p and 1080p clips with sound in H.264, HEVC,
VP9 and AV1 at 30 and 60 fps, silent 480p/720p loops in H.264 and VP9,
512 px animated GIFs and WebPs, 4K stills, and a generated heavy Lottie.
Camera clips of your own go in the same way: copy them into a folder and
`push_media.sh` it.

## Segments and metrics

`session.py` cuts the trace at the app's `LABe` marks and prints one
summary, then a line per segment, every count with its denominator:

| Segment | From the marks | Metric |
| --- | --- | --- |
| scroll | `scroll start` .. `scroll end` | visible hitches per second of motion, gliding and under the finger, by cause: a refresh whose content step (`LABy`) is outside 0.5–1.5× its neighbours' median |
| viewer open | `viewer open-start` .. `viewer morph-end` | input (last finger lift) to the first viewer frame on screen, to the first frame the morph moved, to the player's first frame (of the item opened, before any page change), also as shown; morph hitches of the refreshes judged (`LABm`) |
| viewer page | `viewer page i=<n>`, a video paged to | the page becoming current to its player's first frame on screen |
| viewer close | `viewer close-start` .. `viewer close-end` | input to the first moving frame; morph hitches; time until the card's own picture moves again (`card moved`) |
| route | `route push\|pop <page>` | transition hitches in the first second (`LABr`); for the feeds, input to the first frame with content (`feed first-content`) |

The pointer windows come from the tape, never from the app's messages.
`-` instead of a tape takes the app's input dispatches: a smoke test only.

## Player stages

Every viewer open also gets the player's way to its first frame, stage by
stage from the same input, and so does every video paged to inside the
viewer, from the page becoming current (`viewer page`; the open's own
numbers stop at the first page change); then a table of each stage's
median and max over the run, for opens and pages apart. They come from the player's own marks, `mpx.player <stage>
<id>`, always on in profile builds: the pool's lease, the Dart engine
(prepare, bytes published, create sent and answered, phase changes, first
frame received), the platform player's sections (ExoPlayer built, surface
set, prepare, each data source open and its first read, decoders set up
with their set-up time, ready, first frame rendered) and the view building
the texture, with the refresh it reached the screen on. `player_stages.py`
lists the marks and how one open's are followed across the key, engine and
platform player ids. A stage before the input (a player already warm) is
left out of that open.

## Coverage

A run that draws less is cheaper, so its hitches drop for the wrong
reason. Every recording and every replay of the stress feed ends with a
`LAB coverage` line: the stress items that reached a picture and the video
frames the software decoder decoded, per corpus kind. `session.py` prints
the replay's next to the recording's and flags `COVERAGE DROPPED` when the
replay reached under 90 % of the recording's items of a kind, or under half
its video frames; `replay.sh` also counts `mpx_video:` lines, the reasons
clips failed to decode. A flagged run is not an A/B result.

## Video stages in the log

The software video decoder logs each clip's stages as `mpx_video:` lines
(`adb logcat -s flutter | grep mpx_video`):

| Line | Means |
| --- | --- |
| `<key> decode VideoSource.…` | the content reached the decoder (fetch done) |
| `<key> stalled before the open` / `… the first frame` | its bytes are on their way |
| `<key> opened VideoInfo(…) at WxH as clip <id>` | open done |
| `<key> first frame` | first frame decoded |
| `<key> still uploaded` | first frame on screen next frame: the time to first frame |
| `<key> (content) did not decode: <reason>` | why it stays on its placeholder |
| `clip <id> … decoded N, shown M in 2000 ms, …` | every two seconds while it plays |

Time to first frame of a clip is the logcat time of its `still uploaded`
line minus the time its tile came on screen (or the app start for tiles
on the first screen); `decode` to `still uploaded` is the decoder's share.

## Before trusting a number

- The input of a viewer or route segment is the last finger lift or Back
  up to one refresh after its mark: a replayed row can land a fraction of
  a millisecond after the action it fires. Reports made before this rule
  took the previous input instead, and showed opens and closes hundreds
  of ms too long.

- The engine's marks reach the trace only with `trace-systrace`, which
  the scripts set and which inflates frames with many events. Confirm a
  slow frame from its `LAB slow` line.
- `FrameTiming` build and raster miss work off the frame (snapshots,
  uploads); judge `span` too.
- Synthetic input (`scenario.sh swipe`, `adb input`) proves the pipeline,
  never a verdict: record a real session.
- The Dart CPU profiler needs the app started by `flutter run --profile`;
  the scripts start it with `am start`.
- `flutter test integration_test` and `flutter drive` reinstall the app
  and wipe its data, the corpus with it; the lab never uses them.
