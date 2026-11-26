# ADR 0008: Publishing on pub.dev

Every mpx package publishes on pub.dev under the `mpx_` prefix, except the bytes
cache, `http_bytes_cache`, and the umbrella `mpx`. Native binaries
are built in CI, attached to the monorepo's GitHub Releases with their LGPL
disclosure, and downloaded by the build hooks against a pinned URL and sha256,
with building from source as the fallback. Test helpers stay in each package's
`testing.dart`. Plugins are single packages. melos runs versioning and
publishing over the pub workspace.

**Status**: Accepted (decided with the maintainer 2026-11-10: prefix, binaries,
test helpers; the rest follows the publishing research; amended by ADR 0012
on 2026-11-26: `mpx_transfer`)
**Relates to**: 0001, 0003, 0007, 0009, 0012

## Context

`lottie_native` and `player` are taken on pub.dev, and pub blocks names equal
after removing underscores, adding or dropping an `s`, or homoglyph swaps. Build
hooks are stable since Dart 3.10 / Flutter 3.38, and downloading prebuilt
binaries with a pinned sha256 is the documented path (`sqlite3` does it from
GitHub Releases). Our hooks pin `hooks` / `code_assets` ^1.0.0 while the latest
is 2.2.0; a host using `sqlite3` 3.9 cannot resolve both. `video_native` has no
prebuilt path at all. pub.dev caps archives at 100 MiB compressed, allows only
hosted and SDK dependencies, and forbids unpublishing after 48 hours.

## Decision

| Area | Decision |
| --- | --- |
| Prefix | `mpx_` on every package; umbrella name `mpx`. Free under pub's similarity rules (checked 2026-11-10; the eight final names `mpx`, `mpx_core`, `mpx_lottie`, `mpx_video_decoder`, `mpx_player`, `mpx_ui`, `mpx_capture` re-checked 2026-11-13; `mpx_transfer` is re-checked under the similarity rules before its first publish, with the rest) |
| Bytes cache name | `http_bytes_cache`, no prefix: it caches any HTTP bytes and is useful on its own. Free including similarity variants (checked 2026-11-10) |
| Umbrella | `mpx` publishes as the composition root (ADR 0001), with no re-exports |
| Hooks | Bump `hooks` / `code_assets` to 2.x before the first release |
| Binaries | CI builds every target and attaches it to the monorepo's GitHub Releases |
| Disclosure | Beside each FFmpeg binary: exact source tarball, `changes.diff`, configure lines per target, build scripts, toolchain versions, LGPL text, hashes |
| Download | Packages pin exact URLs + sha256; the hook downloads into the shared output directory and verifies |
| Fallback | Building from source stays available through a user-define |
| Licences | Each package has its own LICENSE and NOTICE: FFmpeg LGPL 2.1 shared libraries, libvpx BSD-3 + WebM patent grant, tlottie MIT plus the Rust crate's dependencies. Hosts inherit the notice duties |
| Test helpers | `testing.dart` stays inside each package; `flutter_test` remains a regular dependency (pub accepts it) |
| Plugins | Single packages: `mpx_core`, `mpx_player`, `mpx_library`, `mpx_capture`, `mpx_transfer`, `mpx`; Swift Package Manager support |
| Natives | Built by hooks inside the package that uses them: `mpx_lottie`, `mpx_video_decoder`; no native-only packages |
| Versioning | melos over the pub workspace; `melos version` bumps dependents |
| Order | Publish in dependency order with hosted constraints, no path dependencies: `http_bytes_cache`, `mpx_core`, `mpx_lottie` and `mpx_video_decoder`, `mpx_player`, `mpx_ui`, `mpx_capture`, `mpx_transfer`, `mpx`. `mpx_transfer` depends on nothing else in the set, so any place after `http_bytes_cache` and `mpx_core` holds |
| First release | Each package's first version by hand, then GitHub Actions OIDC publishing with one tag pattern per package |
| LGPL in App Store apps | Waits on the maintainer's legal review before the native video packages publish |

## Why

- A prefix solves the two taken names at once and claims a family with no
  neighbours on pub.dev.
- Release-hosted prebuilts with hashes are the documented hook path and keep
  packages under the size limit; the disclosure next to each binary is what
  LGPL 2.1 §4 and §6 and FFmpeg's checklist ask for.
- `testing.dart` inside the package keeps fakes next to the seams they fake, as
  today; a separate `*_testing` package per package doubles the publish list.
- Federation pays off only when outside parties add platforms.

## Rejected

| Alternative | Why not |
| --- | --- |
| Unprefixed names | Two are taken; the rest are generic and can be taken before first publish |
| Other free prefixes (`medley_`, `aperture_`, `ezm_`, `reel_`) | Maintainer chose `mpx_` |
| Binaries inside the package archive | Size limit, and one archive per target |
| Separate `*_testing` packages | More packages to version and publish |
| Federated plugins | Two to four packages each, no benefit with one maintainer |
| Publishing placeholders to reserve names | Against pub.dev policy |

## Consequences

- `mpx_core` takes over `frame_texture`'s Android package id (renamed) and adds `Package.swift`.
- `http_bytes_cache` sits outside the `mpx_` family on pub.dev and is
  discoverable on its own.
- External consumers inherit `flutter_test` through `testing.dart`.
- FFI packages cap near 150 pub points (no Wasm), like `sqlite3`.
- The README of every native video package must spell out the host's LGPL
  duties (about-box line, EULA terms, the right to replace the library).
- `mpx_transfer` publishes as a plugin with no prebuilt binaries; its README
  lists the Android permissions and the Play Console declaration a host
  needs for `system` durability (ADR 0012).

## Settled in implementation (2026-11-22)

- **Release.** One GitHub Release per build, tagged `natives-<sha7>`
  (`sha7` is the commit the binaries were built from), and published as a
  full release:
  - Files are flat: `libmpx_lottie-<key>.<ext>`, and
    `mpx_video-<key>-<library>` for each library the loader asks for.
  - The video decoder ships per-file assets, not archives, so the hook needs
    no archive reader.
  - The LGPL disclosure (sources, configure lines, recipe, toolchains,
    licence texts, `SHA256SUMS`) sits beside the files.
  - Manifests are `native/prebuilts.json`, pinned by size, SHA-256 and the
    hash of the sources the files were built from.
  - First releases: `natives-1886963` (both packages) and `natives-eb3357f`
    (mpx_lottie with Apple header room).
- **Order and user defines.**
  - mpx_video_decoder: the app's `ffmpeg_build` first (a dev override, named
    in the app's pubspec, because the hook runner passes no variable of
    ours), then the prebuilt, then a recipe build in the package.
  - mpx_lottie: `build_from_source` forces cargo; otherwise prebuilt, then
    cargo.
- **Downloads.** Into the hook's shared output directory. A download ends
  on a stall, not on its length. Video files are tried three times, because
  a hook that gives up is cached until `flutter clean`.
- **Targets built on a Mac:**
  - macOS arm64 and x86_64;
  - iOS arm64, plus the arm64 simulator (and the x86_64 simulator for
    lottie);
  - Android arm64-v8a, armeabi-v7a and x86_64.

  The video x86_64 builds are plain C. Linux and Windows (lottie) and the
  video iOS x86_64 simulator are left to `.github/workflows/natives.yml`.

## Open in implementation

- Hooks 2.x for `http_bytes_cache`: its hook builds the native reader from
  source (no prebuilts, ADR 0002) on `code_assets` 1.2 / `hooks` 2.0 until
  the pinned Flutter SDK allows the `meta` that `code_assets` 2.x needs.
- `melos version` mode (independent vs fixed); the research notes independent
  as the default.
- Whether pana sees `mpx_lottie`'s web path as Wasm-ready.
- SLSA attestations for the binaries (`sqlite3` does it; not decided).
- App Store LGPL §6(b): legal review.
- Re-check name availability right before the first publish.

## Provenance

Planning tickets `14` (with the `http_bytes_cache` addendum), `15`, `20`
(umbrella), `21` (device signals), `27` (eight packages); research `15-pub-facts`
(pub-dev source, dart.dev hooks docs, `sqlite3` hook, FFmpeg legal page and
LGPL text, libvpx and tlottie licences, melos docs).

## Related

ADR 0001 (names), 0007 (FFmpeg stays decode-only), 0009 (hooks bump before the
move), 0012 (transfers and publish jobs).
