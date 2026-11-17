import 'package:meta/meta.dart';
import 'package:mpx_core/src/asset/asset_cache_budgets.dart';
import 'package:mpx_core/src/asset/asset_paintable.dart';
import 'package:mpx_core/src/asset/asset_preload.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/asset/asset_spec.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/pipeline/auto_download.dart';

/// What a producer is asked to make: the entry's identity.
@immutable
final class AssetRequest {
  /// Creates a request for [key] decoded as [spec].
  const AssetRequest(this.key, this.spec);

  /// Which content.
  final MediaKey key;

  /// Which pixels.
  final AssetSpec spec;

  @override
  bool operator ==(Object other) =>
      other is AssetRequest && other.key == key && other.spec == spec;

  @override
  int get hashCode => Object.hash(key, spec);

  @override
  String toString() => 'AssetRequest($key, $spec)';
}

/// How soon work for an entry is wanted. Producers that queue work order it by
/// this class, highest first.
enum AssetPriority {
  /// Nothing shows the entry: it is kept attached for later (a page beside
  /// the visible one). Served after everything a surface is waiting for.
  preload,

  /// A surface that shows the entry is waiting for it.
  visible,

  /// A cheap stand-in (a thumbnail) for an entry. Small and what the surface
  /// shows first, so served before the entries' full content; an attached
  /// entry's [AssetDemand] never reports it, a producer assigns it to the
  /// work it knows is a stand-in.
  placeholder,
}

/// What the surfaces attached to an entry want from its producer, read live:
/// the scope updates it as bindings attach, detach and show or hide.
abstract interface class AssetDemand {
  /// [AssetPriority.visible] while any attached binding shows the entry,
  /// [AssetPriority.preload] when all are hidden. Never
  /// [AssetPriority.placeholder].
  AssetPriority get priority;

  /// How far the work needs to go: null for the whole content (any binding
  /// is attached), or the furthest stage the staged preloads of the entry ask
  /// for while only preloads hold it (`AssetCacheScope.preload`).
  ///
  /// A producer stops once the stage is reached and ends the attempt with
  /// `AssetProgress.cancelled`: a preload that got what it asked for did not
  /// fail. It reads the value live, so a binding attaching while the work
  /// runs lets it go on to the end.
  AssetPreloadStage? get preloadStage;

  /// Among work of one [priority], which goes first: lower first. 0 while a
  /// binding is attached; otherwise the smallest distance of the entry's
  /// preloads.
  int get distance;

  /// The auto-download tags of the attached bindings
  /// (`AssetCacheScope.attach`), read live; null for a binding that gave
  /// none. Empty while only preloads hold the entry.
  Set<AutoDownloadContext?> get downloadContexts;

  /// Whether content missing from every cache downloads now, only its head,
  /// or waits for the user, for the content of [descriptor] as the surfaces
  /// attached now show it.
  ///
  /// A user's download of the key answers [AutoDownload.now] and a user's
  /// cancel [AutoDownload.manual], whatever the policy; otherwise it is the
  /// most permissive answer of the scope's `AutoDownloadPolicy` over
  /// [downloadContexts]. Without a [descriptor] (not resolved yet) the policy
  /// cannot weigh the content, and the answer is [AutoDownload.now] unless
  /// the user cancelled. A producer asks only for content its fetcher reports
  /// missing; cached content ignores the policy.
  AutoDownload autoDownload(MediaDescriptor? descriptor);
}

/// Whether a failed attempt is worth repeating when the network comes back.
enum AssetFailureKind {
  /// The attempt may succeed later (offline, timeout, server busy). The scope
  /// repeats it for attached bindings when the host reports connectivity.
  transient,

  /// The attempt will not succeed by itself (undecodable data, missing
  /// content). Only a re-attach or an explicit `AssetBinding.retry` repeats it.
  permanent,
}

/// Where a producer reports what it makes for one entry. The scope hands one
/// to [AssetProducer.produce] per attempt.
///
/// Calls after the attempt ended (a final stage, [fail], [cancelled], or the
/// scope cancelling the task) are ignored, and a paintable passed to [advance]
/// then is disposed at once, so a late result cannot leak or corrupt a newer
/// attempt.
abstract interface class AssetProgress {
  /// Offers a better stage: [paintable] is the picture at [stage] and costs
  /// [bytes] while the entry keeps it. The cache owns [paintable] from this
  /// call on. A stage lower than the entry's current one is dropped (and its
  /// paintable disposed); an equal one replaces the current.
  ///
  /// The attempt ends when [stage] is final for the spec (`full`, or
  /// `firstFrame` for a first-frame-only spec). [tier] picks the budget the
  /// bytes count against.
  void advance(
    AssetStage stage,
    AssetPaintable paintable, {
    required int bytes,
    AssetTier tier = AssetTier.still,
  });

  /// Reports the content's descriptor once the producer knows it (the host
  /// gave it, or a resolver answered), for the surfaces that read its facts
  /// (`AssetBinding.descriptor`: a duration, a byte size). Never called for
  /// content no descriptor is known for. The entry keeps it beyond the
  /// attempt; a report equal to the last one changes nothing.
  void describe(MediaDescriptor descriptor);

  /// Reports that the content is missing and its download is about to
  /// start: no byte has arrived yet (`AssetTransfer.waiting`). Called from
  /// the start of the attempt for content known to be missing, before its
  /// thumbnail, so a surface shows the download from its first frame.
  void waiting();

  /// Reports the bytes of the content's download: [received] so far, of
  /// [total] (null when the source did not say), for the surfaces that show
  /// a download (`AssetBinding.transfer`).
  ///
  /// Only a producer that is transferring the content calls it: from the
  /// start of the transfer (0, or what had already arrived), then as bytes
  /// arrive. Content served from a cache (memory or disk) is never reported,
  /// so a surface shows no download for it. The bindings hear byte reports
  /// at most once per frame.
  void transfer(int received, int? total);

  /// Reports that the content is missing and does not download by itself:
  /// the auto-download policy or a user's cancel said so
  /// (`AssetTransfer.awaitingUser`). The attempt goes on with the
  /// stand-ins (preview, thumbnail) and may end as [cancelled].
  void awaitingUser();

  /// Ends the attempt without a result. The entry keeps its stage: a failure
  /// is never drawn as a picture. A download under way turns into
  /// `AssetTransfer.failed`, which a status control shows as download (the
  /// retry). [error] and [stackTrace] are kept for diagnostics
  /// (`AssetBinding.lastError`); [kind] tells whether connectivity helps.
  void fail(
    Object error, [
    StackTrace? stackTrace,
    AssetFailureKind kind = AssetFailureKind.transient,
  ]);

  /// Ends the attempt because it was cancelled, which is not a failure: no
  /// error is recorded.
  void cancelled();
}

/// A running attempt, as the scope sees it.
abstract interface class AssetTask {
  /// Stops the attempt if it is still running and releases what it holds
  /// (network request, decode job). The scope calls it when the last binding
  /// of the entry leaves; it never reports through [AssetProgress] afterwards.
  void cancel();
}

/// Makes the paintables of the entries a scope does not make itself.
///
/// The seam between the cache core and whatever fetches, decodes and renders;
/// `AssetPipeline` is the implementation that fetches and decodes through the
/// host's `ContentFetcher` and `Decoder`s. The scope owns
/// everything else about an entry: one attempt at a time per entry, stage
/// bookkeeping, budgets, pinning, retry, cancellation when the last binding
/// leaves.
///
/// [produce] runs on the UI isolate and must return promptly; real work
/// happens elsewhere and reports through [progress], on the UI isolate too,
/// synchronously from [produce] if the result is already at hand. It never
/// throws for a failed attempt: it calls [AssetProgress.fail].
abstract interface class AssetProducer {
  /// Starts making [request], reporting to [progress]. [demand] stays valid
  /// for the whole attempt and says how urgent the work is.
  AssetTask produce(
    AssetRequest request,
    AssetProgress progress,
    AssetDemand demand,
  );

  /// While [held], starts no new work whose demand is
  /// [AssetPriority.preload] (it waits, in order); work already started
  /// runs on, and visible work starts as usual. The scope holds preloads
  /// while a background hold is on (`AssetCacheScope.holdBackground`): a
  /// transition over the others runs without new decodes for what nobody
  /// shows yet.
  void holdPreloads({required bool held});

  /// Takes what the host already knows about content before a surface
  /// attaches it (`AssetCacheScope.know`), so the content's attempt needs no
  /// lookup and its surfaces read its facts from the first frame. A producer
  /// with no use for descriptors ignores it.
  void know(MediaDescriptor descriptor);
}
