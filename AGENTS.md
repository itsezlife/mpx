# AGENTS.md

Orientation for agents in **mpx**, a portable media monorepo for Flutter: a
bytes cache, a media core, decoders, a player, optional UI and capture, and a
composition root. Read this first; the decisions live behind the pointers.

## Commands

Run the gates per package, from the package directory. They are the only
checks (CI runs the same, `.github/workflows/check.yml`):

```shell
flutter test --concurrency 40   # `dart test` for pure-Dart packages (http_bytes_cache)
dart analyze --fatal-infos
find lib test -name "*.dart" ! -name "*.*.dart" -print0 \
  | xargs -0 dart format --set-exit-if-changed --line-length 80 -o none
```

The repo is one **pub workspace**: one `pubspec.lock` at the root, resolved
with `flutter pub get` there. A new package is appended to the root
`workspace:` list (literal paths). melos (config in the root pubspec) is for
versioning and publishing only.

Each package has one test entrypoint, `test/unit_test.dart`. It imports every
`*_test.dart` and calls each `main` inside a group of its own, in one process.
A new test file is added there; a test restores any global state it changes.

## Packages

| Package | Role | ADR |
| --- | --- | --- |
| `packages/http_bytes_cache` | HTTP bytes cache: resolve ladder, middlewares, disk store, ranged resources; a hook-built C native reader | [0002](docs/adr/0002-bytes-cache.md) |
| `packages/mpx_core` | Plugin: media identity, asset cache and pipeline, clock, budgets, texture hosts, image decoder | [0003](docs/adr/0003-media-core-and-decoders.md) |
| `packages/mpx_lottie` | Vector animation decoder + native library (build hook) | [0003](docs/adr/0003-media-core-and-decoders.md) |
| `packages/mpx_video_decoder` | Software video decoder for silent loops + native library | [0003](docs/adr/0003-media-core-and-decoders.md) |
| `packages/mpx_svg` | SVG decoder: sanitizer and limits for untrusted SVG, compile off the UI isolate, raster at the spec | [0003](docs/adr/0003-media-core-and-decoders.md) |
| `packages/mpx_player` | Plugin: player pool, leases, audio owner, feed modes | [0004](docs/adr/0004-player.md), [0005](docs/adr/0005-feed.md) |
| `packages/mpx_ui` | Optional: fullscreen viewer, feed widgets | [0006](docs/adr/0006-viewer.md) |
| `packages/mpx_library` | Optional plugin: device media library, file intake, library keys and fetcher | [0011](docs/adr/0011-library-and-picking.md) |
| `packages/mpx_capture` | Optional plugin: compression, still preparation, camera session, round video | [0007](docs/adr/0007-capture.md), [0011](docs/adr/0011-library-and-picking.md) |
| `packages/mpx` | Plugin: composition root, fetch adapter, device signals | [0001](docs/adr/0001-package-topology.md) |

Dependency direction (arrows point at the dependency; ADR 0001):

```
mpx_lottie, mpx_video_decoder, mpx_svg -> mpx_core
mpx_player                    -> mpx_core, http_bytes_cache
mpx_library                   -> mpx_core
mpx_ui                        -> mpx_player, mpx_core, mpx_library
mpx_capture, mpx              -> mpx_core, http_bytes_cache
```

## Rules held by convention

There are no workspace lints; review holds these:

- Edges exactly as above. `mpx_core` and `http_bytes_cache` never depend on
  each other; `mpx` never depends on the decoders (`mpx_svg` included), the player, the UI,
  the library or capture.
- No package re-exports another package's API, `mpx` included.
- Fakes and contract suites only from each package's `lib/testing.dart`; every
  new seam gets a fake, and a contract suite when it has more than one
  implementer.
- Media is keyed by `MediaKey`, never by URL.
- Text in `mpx_ui` sits under a text root: every route, overlay and popup it
  pushes, and its own surfaces, start from `MpxTextRoot` (the pusher's
  `DefaultTextStyle`, or the theme's body style when that is a fallback);
  token styles merge over it (`DefaultTextStyle.merge`), never replace it.
  Surface tests run under `unthemedHost` and call `expectThemedText`.
- Native names start with `mpx_` / `dev.mpx.` / `MPX_` plus the owning
  component; the bytes cache's native reader uses `http_bytes_cache_*` /
  `hbc_*` (ADR 0009).
- Public API has dartdoc in glossary terms and roles. No product screens and
  no reference-client names, file names or line numbers in code, tests,
  READMEs or CHANGELOGs (ADRs may cite them).
- pubspec `description`: one plain sentence, 60 to 180 characters. README:
  what it is, install, a minimal usage example, features, doc links.
  CHANGELOG: short user-facing entries per version.

## Docs

| What | Where |
| --- | --- |
| The whole system on one page, build order | [docs/spec.md](docs/spec.md) |
| Decisions (topology, bytes cache, core, player, feed, viewer, capture, publishing, migration, loading stages, library and picking) | [docs/adr/](docs/adr/) |

Read the ADR for the package you touch before changing its shape. A decision
that changes an ADR updates that ADR in the same change.

## Git

`main` is the integration branch. Commit with clear messages; the maintainer
pushes.
