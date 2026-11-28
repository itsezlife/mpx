# ADR 0013: Diagnostics events

Every code path in mpx's optional packages reports what it does as a
structured event: a level, a category, an operation from a closed set,
correlation ids and a few numeric or short fields. One process-wide policy
in `mpx_core`, `MpxDiagnostics.current`, set once by the host, is silent by
default, logs to the developer
console when asked, or hands every event to the host. The bytes cache keeps
its own `BytesDiagnostics`; the composition root bridges it into the same
stream. Native code crosses the plugin channel into the same events and also
writes to the platform's log. Events carry ids, sizes and codes, never user
content. An error path without an event is a defect.

**Status**: Accepted (decided with the maintainer 2026-11-26)
**Relates to**: 0001, 0002, 0008, 0010, 0011, 0012

## Context

A transfer that resumes after a kill, a part retried five times, an envelope
the system ended while the app was in the background, a reuse hit that
skipped an upload: these are invisible from the screen and hard to rebuild
afterwards. The bytes cache already reports its own warnings and errors
through `BytesDiagnostics` (`silent`, `developer`, `onEvent`), but it is a
standalone package that `mpx_core` must not depend on, and its events are
free text. The transfer engine, preparation and the bindings report nothing.
Device checks of background behaviour need evidence from the minutes before
a kill, when the developer console is not attached.

## Decision

### Events and policy

| Piece | Where | Shape |
| --- | --- | --- |
| `MpxDiagnostics` | `mpx_core` | Sealed policy, process-wide as `MpxDiagnostics.current` (as `BytesDiagnostics.current`): the host sets it once at start, and a test that changes it restores it. Policies: `silent` (the default; one level check per call site), `developer` (`dart:developer` `log`, name `mpx`), `onEvent(callback)` (the host routes events, for example a crash reporter that keeps `warning` and `error` in release builds) |
| `MpxEvent` | `mpx_core` | `time`; `level` (`trace`, `debug`, `info`, `warning`, `error`); `op`, a `DiagnosticOp` whose category is the event's; correlation ids `jobId`, `itemId`, `mediaKey`, `tag`; `fields` (numbers, bools and short strings); `error`; `stackTrace` |
| `DiagnosticOp` | `mpx_core` | The op contract only: an interface with a `category` and a `name`. Each package keeps its own closed op enum implementing it |
| `RecordingDiagnostics` | `mpx_core` `testing.dart` | A fake that records events, with matchers by category, op, level and id |

Categories and the package whose op enum holds them: `journal`,
`scheduler`, `transport`, `envelope`, `reuse` and `publish` in
`mpx_transfer`; `preparation` in `mpx_capture`; `save` in `mpx_library`
(the media saver, ADR 0011); `binding` in `mpx_core`; `cache` in `mpx`. `mpx_core` declares no other package's ops, so a package
adds an op without touching the core. ADR 0012's paths each have
their operations (a part sent, acknowledged, retried or given up; a journal
flush or compaction; an envelope started, refused, degraded, ended by the
system or withdrawn; a reuse hit or invalidation; a publish attempt and its
outcome; a preparation started or finished; a binding's tracked download and
its mapped state). The full table of operations, levels, fields and ids is
kept in the transfers specification beside ADR 0012.

Levels: `trace` for per-part and per-batch detail, `debug` for stage changes,
`info` for milestones, `warning` for a degrade or a retry, `error` for a
failure that reaches a state.

`mpx_transfer`, `mpx_capture`, `mpx` and the bindings of `mpx_core` emit
through `MpxDiagnostics.current`; none takes a policy through a constructor.
Nothing is emitted until the host sets a policy; routing is the host's.

### The bytes cache

`mpx_core` and `http_bytes_cache` stay independent (ADR 0001). The `mpx`
stack sets `BytesDiagnostics.current` to an `onEvent` that forwards each
bytes event into `MpxDiagnostics.current` as category `cache`, with its
operation as a field, its level and stack trace. Its free-text message is dropped, since it can carry keys
and URLs.

### Native events

Events from the native envelope (the Android job service and foreground
service, the iOS background and continued-processing tasks) cross the plugin
channel into `MpxEvent` with category `envelope`. They are also written to
logcat under the tag `mpx_transfer` and to `os_log` under subsystem
`dev.mpx.transfer`, category `envelope`. While Dart is not running the native
side writes them to a ring file (default 2 MiB); at the next start the plugin emits
each record with its original time and a `native` field, then a merge event.

### Inspection

`transfers.debugSnapshot()` returns a value for a debug panel: active jobs
with state, stage, lane, durability and bytes; each publish job's items;
lanes and connections against the caps; the journal's store, size and last
write; the envelope's kind, state and jobs; reuse-table entries, hits and
misses; registered publishers and jobs waiting for a publisher or an owner;
connectivity; `systemActive`; counters since start (parts in flight, part
retries, restarts from zero, envelopes ended by the system).

### Traces

A compile-time define `mpx.trace` turns on `Timeline` sections named
`mpx.<category>.<op>` for a part send, a journal flush and compaction, a
preparation, a reuse lookup and a publish attempt. The default build compiles
them out.

### No user content

Fields carry ids, sizes, counts, durations and codes. No payload bytes, no
file names or paths (an extension and a size instead), URLs as scheme and
host only, no headers, no idempotency keys or resume tokens (a short hash
when two must be compared). Ids and tags are carried as the host gave them;
a host keeps its tags to ids.

### Rules for every package

- Every code path emits its category's events; an error without an event is
  a defect.
- Every seam's tests check its events through `RecordingDiagnostics`.
- A device check attaches an exported log; a scenario without a log is not
  checked.

## Why

- Background transfers fail where no debugger is attached; only events kept
  on the device explain what happened before a kill.
- Correlation ids let one job, item or key be followed through journal,
  scheduler, transport, envelope and publish without reading free text.
- The bytes cache's policy shape is already known to hosts; a second shape
  would mean two ways to route logs.
- A closed set of operations per category keeps events filterable and lets
  tests name exactly what a path must report.
- Native logs under their own tag survive when Dart is gone, and the ring file
  brings them back into the same stream.
- `silent` by default costs one check, so the events can stay in release
  code.
- Logs travel to other people: user content in them would leak messages,
  file names and signed URLs.

## Rejected

| Alternative | Why not |
| --- | --- |
| Free-text log lines | Cannot be filtered by job or item, and tests cannot assert on them reliably |
| `mpx_core -> http_bytes_cache` to share one diagnostics type | ADR 0001 keeps the two independent; a bridge in the composition root does the job |
| A policy passed through every constructor | Every seam and widget would grow a parameter, and a forgotten one goes silent; the bytes cache's process-wide policy already works |
| Every op enum in `mpx_core` | The core would change for every new path in an optional package |
| A logging package dependency | A host's own routing would sit behind a second abstraction; the callback is enough |
| Logging on by default | Costs every host a stream it may not want |
| Counting native events only on the native side | Two logs that disagree in time and ids; the bridge and the ring file keep one stream |
| Forwarding the bytes cache's message text | It can carry keys and URLs with tokens |

## Consequences

- `mpx_core` gains `MpxDiagnostics` with `current`, `MpxEvent`,
  `DiagnosticOp`, its own `binding` ops, the `mpx.trace` helper and
  `RecordingDiagnostics`. Each other package declares its own op enum.
- `mpx`'s stack bridges the bytes cache into `MpxDiagnostics.current`.
- Tests that change `MpxDiagnostics.current` or `BytesDiagnostics.current`
  restore it.
- `mpx_transfer`, `mpx_capture` and the bindings emit their events;
  `mpx_transfer` adds `transfers.debugSnapshot()` and the native ring logs
  (ADR 0012).
- The mpx example keeps an on-device log journal: a ring buffer on disk
  (default 20 MiB, flushed at once on `warning` and `error`), a Logs screen
  filtered by category, level and correlation id, and export through the
  share sheet; a debug panel shows the snapshot and offers actions to kill
  the process, cut the network and simulate a system interruption.

## Provenance

Decided with the maintainer 2026-11-26: structured events with correlation
ids on the bytes cache's policy pattern, the contract in `mpx_core` with the
cache bridged in the composition root, native events bridged and kept in the
platform log and a ring file, the debug snapshot, compile-time traces, no
user content, and diagnostics as a rule for every package and device check;
then, the same day, the process-wide `current` policy, the op contract in
the core with each package's own op enum, and the ring file's 2 MiB default.

## Related

ADR 0001 (no edge between `mpx_core` and `http_bytes_cache`), 0002
(`BytesDiagnostics`), 0012 (transfers, envelope, publish jobs).
