import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:mpx_core/src/asset/asset_producer.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/pipeline/cancellation_token.dart';

/// Which bytes of a piece of content a fetch is for.
enum FetchPart {
  /// The stand-in named by `MediaDescriptor.thumbnail`: small, shown while
  /// the content loads. Only requested for a descriptor that has one.
  thumbnail,

  /// The content itself.
  content,
}

/// Where a [ContentFetcher] reports the bytes of a transfer: [received] so
/// far, of [total], or null when the source does not say how many will come.
typedef FetchProgress = void Function(int received, int? total);

void _ignoreProgress(int received, int? total) {}

/// What a [ContentFetcher] is asked for.
@immutable
final class FetchRequest {
  /// Creates a request for [part] of [descriptor].
  const FetchRequest({
    required this.descriptor,
    required this.part,
    required this.priority,
    required this.cancellation,
    this.onProgress = _ignoreProgress,
    this.prefix,
  });

  /// What is known about the content. For [FetchPart.thumbnail] its
  /// `thumbnail` is set.
  final MediaDescriptor descriptor;

  /// Which bytes.
  final FetchPart part;

  /// How urgent the fetch is, for a fetcher that queues its own network
  /// work. It does not change while the fetch runs.
  final AssetPriority priority;

  /// Cancelled when nobody wants the result any more.
  final CancellationToken cancellation;

  /// Told the bytes received while the fetcher transfers the part; see the
  /// contract of [ContentFetcher]. Ignores every call by default.
  final FetchProgress onProgress;

  /// Only the first [prefix] of the content is wanted, for a staged preload
  /// (`AssetPreloadStage.seconds`); null for the whole part. A fetcher that
  /// can resolve a duration to bytes (through the container's index) fetches
  /// that much; one that cannot fetches the whole. The pipeline does not
  /// decode what a prefix fetch returns.
  final Duration? prefix;
}

/// Gives fetched content back to its fetcher: nothing reads it any more.
typedef FetchRelease = void Function();

/// What a fetch produced.
///
/// The bytes in memory, a file the host's disk tier holds, or a ranged
/// resource read natively as it downloads; a decoder takes whichever suits
/// its codec. A file and a ranged resource are read where they are, so
/// their bytes need never pass through the UI isolate.
///
/// Content that holds something on the fetcher's side (a file the disk tier
/// keeps from eviction, a published resource) is released once, by whoever
/// has it last: the decoder that was handed it, once it no longer reads it
/// (at once for a decoder that reads the whole file up front, when its clip
/// closes for one that keeps reading), or the pipeline, for content no
/// decode takes (a cancelled attempt, a prefix fetch). [release] is called
/// exactly once.
@immutable
sealed class FetchedContent {
  const FetchedContent();

  /// Content held in memory.
  const factory FetchedContent.bytes(Uint8List bytes) = FetchedBytes;

  /// Content in a file at [path]; [onRelease] runs when it is released.
  const factory FetchedContent.file(String path, {FetchRelease? onRelease}) =
      FetchedFile;

  /// The ranged resource [key] of the native reader at [readerApi];
  /// [onRelease] runs when it is released.
  const factory FetchedContent.ranged({
    required int readerApi,
    required String key,
    Stream<void>? landed,
    FetchRelease? onPause,
    FetchRelease? onRelease,
  }) = FetchedRanged;

  /// Gives the content back: its consumer no longer reads it. Called once.
  void release();
}

/// [FetchedContent] held in memory.
final class FetchedBytes extends FetchedContent {
  /// Creates content from [bytes], which the fetcher no longer changes.
  const FetchedBytes(this.bytes);

  /// The encoded data.
  final Uint8List bytes;

  /// Bytes hold nothing on the fetcher's side.
  @override
  void release() {}
}

/// [FetchedContent] in a file.
///
/// The file belongs to the host's disk tier: the pipeline and the decoders
/// read it and never delete or move it.
final class FetchedFile extends FetchedContent {
  /// Creates content read from [path]; [onRelease] runs when it is released
  /// (a fetcher gives its file lease back there).
  const FetchedFile(this.path, {FetchRelease? onRelease})
    : _onRelease = onRelease;

  /// Where the encoded data is.
  final String path;

  final FetchRelease? _onRelease;

  @override
  void release() => _onRelease?.call();
}

/// [FetchedContent] read natively, at offsets, as it downloads.
///
/// A native reader serves the resource [key]: it says which bytes are there
/// without waiting, and asks the fetcher's side for the ones that are not.
/// [readerApi] is the address of the reader's function table (the bytes
/// cache's native reader, `hbc_api` version 3 or later), which a decoder's
/// native code calls; Dart never reads the bytes. A decoder that finds its
/// bytes missing tries again when [landed] says more arrived. The resource
/// stays readable until [release].
///
/// Only a decoder whose codec reads through such a reader takes it; a
/// fetcher hands it out only for the kinds the host says decode that way.
final class FetchedRanged extends FetchedContent {
  /// Creates content read through the reader at [readerApi] as [key];
  /// [onRelease] runs when it is released.
  const FetchedRanged({
    required this.readerApi,
    required this.key,
    this.landed,
    FetchRelease? onPause,
    FetchRelease? onRelease,
  }) : _onPause = onPause,
       _onRelease = onRelease;

  /// Address of the native reader's function table.
  final int readerApi;

  /// The resource the reader opens.
  final String key;

  /// An event each time bytes of the resource landed, or null when the
  /// fetcher's side tells nothing (a decoder then tries again on a timer).
  final Stream<void>? landed;

  final FetchRelease? _onPause;
  final FetchRelease? _onRelease;

  /// Its reader stopped reading for now (the surface left the screen): the
  /// fetcher's side stops fetching ahead of it, keeping what landed. Reads
  /// ask again as usual when it goes on. Any number of times, until
  /// [release].
  void pause() => _onPause?.call();

  @override
  void release() => _onRelease?.call();
}

/// Why a fetch failed, as the pipeline needs to know it.
///
/// The [kind] tells whether the host's connectivity-restored signal can help.
/// The pipeline never shows a failure: the entry keeps its stage and the
/// attempt is repeated on a re-attach, on `AssetBinding.retry`, and, for a
/// [AssetFailureKind.transient] one, when connectivity returns.
final class FetchFailure implements Exception {
  /// Creates a failure of class [kind] explained by [message].
  const FetchFailure(this.kind, this.message, [this.cause]);

  /// Offline, timed out or a server that is busy: worth repeating later.
  const FetchFailure.transient(String message, [Object? cause])
    : this(AssetFailureKind.transient, message, cause);

  /// Missing or forbidden content: repeating it unchanged will not help.
  const FetchFailure.permanent(String message, [Object? cause])
    : this(AssetFailureKind.permanent, message, cause);

  /// Whether connectivity can fix it.
  final AssetFailureKind kind;

  /// What went wrong, for logs.
  final String message;

  /// The underlying error, if any.
  final Object? cause;

  @override
  String toString() => 'FetchFailure(${kind.name}): $message';
}

/// Gets the encoded bytes of content, from wherever the host keeps them.
///
/// The host implements it, because only the host knows the network, the way
/// file references expire and are refreshed, and the disk tier below it. The
/// pipeline asks for every part it needs and never caches bytes itself.
///
/// ## Contract
///
/// - [fetch] runs on the UI isolate and returns at once; the work may happen
///   anywhere. The future completes on the UI isolate.
/// - It completes with the content, or fails with a [FetchFailure]. Any other
///   error is treated as a transient failure.
/// - Content that does not exist is a permanent [FetchFailure]; no network,
///   a timeout or a busy server is a transient one.
/// - A fetch for a [FetchPart.thumbnail] returns the stand-in, for a
///   [FetchPart.content] the content, even when the same bytes would do.
/// - When `FetchRequest.cancellation` is cancelled the fetcher stops its work
///   as soon as it can and settles the future: with whatever it already has,
///   or with a failure. It never leaves the future pending.
/// - A fetch that transfers the bytes (a download) reports them through
///   `FetchRequest.onProgress`: once when the transfer starts, with what has
///   arrived (0 for a fresh one) and the total the source announced, then as
///   bytes arrive. A part served from a cache the host keeps (memory or the
///   disk tier) is not a transfer and is never reported, so the surfaces show
///   no download for it. A transfer that several requests share reports to
///   each of them. Reports are on the UI isolate, before the future settles;
///   one transfer answered at once (a replayed recording) may report once,
///   with everything.
/// - It may run many fetches at once; the pipeline's caps bound how many it is
///   given.
/// - [needsDownload] answers at once, from what the host knows without
///   waiting.
abstract interface class ContentFetcher {
  /// Gets [FetchRequest.part] of [FetchRequest.descriptor].
  Future<FetchedContent> fetch(FetchRequest request);

  /// Whether the content of [key] is known to be missing: in no cache the
  /// host keeps (memory or the disk tier), so fetching its
  /// [FetchPart.content] downloads it, or a download of it is under way.
  ///
  /// The pipeline asks when an attempt starts, before it resolves the key or
  /// fetches anything, so a surface draws the download from its first frame,
  /// over the placeholder and the thumbnail that arrives first, also for a file
  /// that does not exist yet (instead of
  /// from the first byte of the content, after the thumbnail). Content held
  /// locally is never announced, so a cached file shows no download.
  ///
  /// It runs on the UI isolate for every attempt and must not wait: an index
  /// the host keeps, or a stat of the disk tier's file. A fetcher that cannot
  /// tell answers false; the surfaces then show the download from the
  /// transfer's first report (`FetchRequest.onProgress`).
  bool needsDownload(MediaKey key);
}
