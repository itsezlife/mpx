import 'dart:collection';
import 'dart:ui' show Canvas, Color, Image, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:mpx_core/src/asset/asset_binding.dart';
import 'package:mpx_core/src/asset/asset_binding_base.dart';
import 'package:mpx_core/src/asset/asset_cache_budgets.dart';
import 'package:mpx_core/src/asset/asset_paintable.dart';
import 'package:mpx_core/src/asset/asset_playback.dart';
import 'package:mpx_core/src/asset/asset_preload.dart';
import 'package:mpx_core/src/asset/asset_producer.dart';
import 'package:mpx_core/src/asset/asset_profile.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/asset/asset_spec.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';
import 'package:mpx_core/src/asset/clear_placeholder.dart';
import 'package:mpx_core/src/asset/outline_paintable.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/pipeline/auto_download.dart';
import 'package:mpx_core/src/playback/playback_clock.dart';
import 'package:mpx_core/src/playback/playback_policy.dart';
import 'package:mpx_core/src/texture/frame_texture_pool.dart';

/// The asset cache of one host: entries keyed by content and [AssetSpec],
/// bindings that pin them, a byte-budgeted LRU for the ones nobody holds, and
/// the playback clock their animations advance by.
///
/// Created by the host and handed to the surfaces that attach; there is no
/// static instance. It owns what it made (entries, the default clock, the
/// default placeholder) and nothing it was handed (a producer, a clock, the texture pool, the memory-pressure signal): [dispose] leaves
/// those alone.
///
/// ## Entries
///
/// [attach] finds or creates the entry for `(key, spec)` and returns a
/// binding. The first binding starts an attempt through the [producer]; more
/// bindings share it (one attempt per entry, however many surfaces ask), and
/// when the last binding leaves a running attempt is cancelled. An entry that
/// reached a stage worth keeping stays for the next attach (pager keep-alive)
/// until the budget or [clearAll] drops it; one that has produced nothing
/// beyond a placeholder is dropped at once.
///
/// The same content at another spec is another entry, but not another
/// picture to wait for: while an entry is below its first frame, a binding
/// shows the best stage a **sibling** (an entry of the same key and decode
/// mode at another size) has reached, placed by the binding's own profile,
/// instead of a placeholder (see [AssetBinding.paintable]). It borrows that
/// sibling, which pins it like a binding would, until its own entry catches
/// up or it detaches. A sibling that plays lends its first-frame still
/// ([AssetPaintable.firstFrame]), never its live frame, and one with no still
/// lends nothing: the binding's own entry starts from frame 0, and a frame
/// from the middle of the sibling's loop would jump back when it arrives. A
/// clip picked from a grid cell is drawn in a list item at once, at the
/// cell's pixels, until the item's own decode arrives.
///
/// An entry with a live binding is pinned: neither the budget, [clearAll] nor
/// the memory-pressure signal evicts it, so eviction can never invalidate a
/// binding. A binding gives back exactly what it took, once, and never looks
/// its entry up again, so nothing done to the cache while it is live changes
/// another binding's counts.
///
/// ## Background hold
///
/// [holdBackground] holds every binding of the scope but those of a
/// foreground profile (`AssetProfile.foreground`): each keeps the frame it
/// shows, as if its surface held it (`AssetBinding.held`), and goes on from
/// that frame when the last hold is released. The clock keeps running, so the
/// foreground surface (a content preview) plays while the grid, the list and
/// a sheet under it stand still; a pause layer of the clock would stop it
/// too. As a preview opens, every image below the preview's layer stops its
/// animation, and as it closes they start again where they were.
///
/// ## Staged preloads
///
/// [preload] asks for an entry nobody shows yet, only as far as a stage
/// ([AssetPreloadStage]: the descriptor, a prefix of the bytes, the first
/// frame), with a distance that orders it among other preloads. A preload pins
/// its entry like a hidden binding; the producer reads the stage live
/// (`AssetDemand.preloadStage`) and stops there, unless a binding attaches
/// meanwhile and wants the rest. While a layer of [preloadPausingLayers] is
/// set on the clock (low power, a fast scroll, a metered network, thermal
/// stress), new preload attempts wait; they start when the last such layer
/// clears. Running work is not stopped. Hidden bindings are not preloads and
/// are never held back.
///
/// ## Downloads
///
/// A content has one transfer, whatever the spec (`AssetBinding.transfer`):
/// every surface of the content shows it, an entry that waits shows the
/// download another spec runs, and once one spec has the content, the others
/// still waiting for it start again and read the local bytes. One transfer
/// runs per content: a spec attached while another downloads waits for it.
/// The scope keeps one record per content with the user's intent, the most
/// of its bytes any report gave, the bytes readers outside the cache hold
/// ([openOutsideReader]) and the transfer derived from them.
///
/// Content missing from every cache downloads when the [autoDownload] policy
/// says so for the tags of the bindings attached to it ([attach]'s
/// `downloadContext`; the most permissive answer wins, kept until the
/// policy, the tags or the descriptor change), or while a surface requests
/// it (`AssetBinding.requestsDownload`); otherwise it shows its stand-ins and
/// waits for `AssetBinding.download`. A user's download is whole and goes on
/// with no surface attached until the content is whole, cancelled or failed.
/// A user's cancel (`AssetBinding.cancelDownload`) wins over every request
/// and the policy, and is remembered per key for the scope's life, so
/// content scrolled back into view is not fetched again until the user asks;
/// a user's download is remembered the same way. When the policy changes, or
/// a binding whose tag allows it attaches, waiting content that may download
/// now starts, in one spec.
///
/// ## Textures
///
/// A platform with a texture host registers its [FrameTexturePool] as
/// [textures]; decoders whose assets play take textures from it, and fall back
/// to their dynamic page slots without one. The memory-pressure
/// signal releases its idle textures along with the unpinned entries.
///
/// ## Threading
///
/// Single-threaded: every call, every producer report, every listener and all
/// painting happen on the UI isolate. Producers may decode on other isolates
/// or threads but report here from the UI isolate.
final class AssetCacheScope {
  /// Creates a scope.
  ///
  /// [producer] makes the entries; without one they stay at
  /// [AssetStage.none]. [clock] is the playback clock (created, and disposed
  /// with the scope, if omitted). [memoryPressure] is a signal that empties the unpinned
  /// entries when it fires. [placeholder] is what a binding paints before its
  /// entry has produced any stage (nothing by default, `ClearPlaceholder`).
  /// [textures] is the pool of the platform's
  /// texture host, or null where there is none.
  AssetCacheScope({
    AssetProducer? producer,
    AssetCacheBudgets budgets = AssetCacheBudgets.defaults,
    PlaybackClock? clock,
    Listenable? memoryPressure,
    AssetPaintable? placeholder,
    this.textures,
    this.preloadPausingLayers = standardPreloadPausingLayers,
    this.autoDownload = AutoDownloadPolicy.always,
  }) : _producer = producer,
       _budgets = budgets,
       _clock = clock ?? PlaybackClock(),
       _ownsClock = clock == null,
       _memoryPressure = memoryPressure,
       placeholder = placeholder ?? const ClearPlaceholder() {
    memoryPressure?.addListener(_onMemoryPressure);
    _clock.addLayerListener(_onLayers);
    _preloadsPaused = _layersPausePreloads();
    autoDownload.changes.addListener(_onAutoDownloadChanged);
  }

  /// Which missing content downloads by itself; [AutoDownloadPolicy.always]
  /// unless the host says otherwise. See "Downloads" above.
  final AutoDownloadPolicy autoDownload;

  // The download state of each content (one record per key, whatever the
  // spec): its entries, the user's intent, its bytes and its transfer.
  final Map<MediaKey, _Content> _contents = {};

  _Content _contentOf(MediaKey key) {
    final content = _contents.putIfAbsent(key, () => _Content(this, key));
    _idle.remove(content);
    return content;
  }

  // Records nobody holds that still carry a bytes mark, least recently left
  // first: a surface that comes back to a partial download draws it where it
  // was, for the last [_idleMarks] contents left.
  final LinkedHashSet<_Content> _idle = LinkedHashSet.identity();
  static const int _idleMarks = 256;

  void _onAutoDownloadChanged() {
    if (_disposed) return;
    for (final content in List<_Content>.of(_contents.values)) {
      content.policyChanged();
      _startOneDownload(content);
    }
  }

  // Starts the download of [content] in one of its entries that waits for
  // the user although the scope would download it now: one transfer per
  // content, however many specs wait.
  void _startOneDownload(_Content content) {
    if (_disposed || content.downloading) return;
    for (final entry in content.entries) {
      if (_mayDownloadNow(entry)) {
        _restart(entry);
        return;
      }
    }
  }

  // Whether [entry] waits for the user although the scope would download it
  // now: the policy, the tags attached or a request changed since its
  // attempt decided.
  bool _mayDownloadNow(_Entry entry) =>
      entry.reported is AssetTransfer$AwaitingUser &&
      entry.bindings.isNotEmpty &&
      !entry.isFinal &&
      entry.content.answer(entry, entry.descriptor) == AutoDownload.now;

  // Ends the running attempt of [entry], if any, and starts another.
  void _restart(_Entry entry) {
    entry.attempt?.cancel();
    _start(entry);
  }

  void _download(_Entry entry) {
    final content = entry.content..userIntent = _UserIntent.requested;
    final failed = content.clearStreamFailure();
    content.refresh();
    // The download under way, of any spec, already does what was asked.
    if (content.downloading) return;
    // The spec that fetches: this one, else another still missing the
    // content, else (the rest of a streamed content failed) this one again.
    final target = [
      entry,
      ...content.entries,
    ].where((candidate) => !candidate.isFinal).firstOrNull;
    if (target == null) {
      if (failed) _restart(entry);
      return;
    }
    // A running attempt that is not holding the content back (it reads it
    // from a cache) already does what was asked.
    if (target.attempt != null &&
        target.reported is! AssetTransfer$AwaitingUser &&
        target.reported is! AssetTransfer$Failed) {
      return;
    }
    _restart(target);
  }

  void _cancelDownload(_Entry entry) {
    final content = entry.content;
    if (!content.transfer.isActive) return;
    content.userIntent = _UserIntent.cancelled;
    _stopDownloads(content);
  }

  // A binding of [entry] began or stopped requesting the content while it
  // shows it (AssetBinding.requestsDownload). Content awaiting the user that
  // may download now starts; a download nothing wants any more (no other
  // request, no user's download, a manual policy) stops where it is, its
  // bytes kept, and the content awaits the user.
  void _requestChanged(_Entry entry) {
    if (_disposed) return;
    final content = entry.content..refresh();
    if (!content.downloading && _mayDownloadNow(entry)) {
      _restart(entry);
      return;
    }
    if (content.downloading && !content.wanted) _stopDownloads(content);
  }

  // Stops every download of [content]; the next attempt of a spec still
  // shown fetches only the stand-ins and says the content awaits the user,
  // and one that cannot tell leaves the scope to say it. A download that
  // went on with no surface ends with its entry.
  void _stopDownloads(_Content content) {
    for (final entry in List<_Entry>.of(content.entries)) {
      if (entry.keptForDownload) {
        entry
          ..keptForDownload = false
          ..reported = AssetTransfer.none;
        entry.attempt?.cancel();
        // Its paintable may still pull the rest of a streamed content.
        _evict(entry);
        continue;
      }
      if (!entry.reported.isActive) continue;
      final total = entry.reported.total;
      entry.attempt?.cancel();
      if (entry.bindings.isNotEmpty && !entry.isFinal) _start(entry);
      if (entry.reported == AssetTransfer.none) {
        entry.reported = AssetTransfer.awaitingUser(total);
      }
    }
    content.refresh();
  }

  /// Opens the account of a reader outside the cache (a platform player
  /// streaming the content) of [key]'s content: it tells the bytes it holds
  /// as they land ([AssetOutsideReader.report]) and is closed when the
  /// reader lets the content go ([AssetOutsideReader.close]).
  ///
  /// While no spec of the content downloads it, its surfaces show the most
  /// any open reader holds as the download if anyone wants the content (the
  /// user, a surface that requests it, or the policy), and as bytes received
  /// over the download control otherwise. All of it completes the content:
  /// the specs still waiting for it start again and read the local bytes.
  /// Readers count: one closing leaves the others. After [dispose] the
  /// account ignores every call.
  AssetOutsideReader openOutsideReader(MediaKey key) =>
      AssetOutsideReader._(this, key);

  void _outsideBytes(AssetOutsideReader reader, int received, int? total) {
    if (_disposed) return;
    final content = _contentOf(reader._key)..read(reader, received, total);
    if (content.isWhole) _contentLocal(content);
  }

  void _outsideClosed(AssetOutsideReader reader) {
    if (_disposed) return;
    final content = _contents[reader._key];
    if (content == null) return;
    content.stopReading(reader);
    _dropIfIdle(content);
  }

  // The content's bytes are local now: a spec still waiting for them, or
  // whose download stopped short, starts again and reads them; one nobody
  // binds drops its transfer, and an entry kept for a user's download goes
  // to the budget.
  void _contentLocal(_Content content) {
    content.local();
    for (final entry in List<_Entry>.of(content.entries)) {
      if (entry.keptForDownload) {
        entry.keptForDownload = false;
        if (entry.attempt == null) _release(entry);
      }
      if (entry.isFinal || entry.reported == AssetTransfer.none) continue;
      if (entry.bindings.isNotEmpty || entry.preloads.isNotEmpty) {
        _restart(entry);
      } else {
        entry.reported = AssetTransfer.none;
      }
    }
    content.refresh();
    _trim();
  }

  // A content nobody holds any more (no entry, no reader) drops its state
  // but the user's intent and its bytes mark; the marks of only the last
  // [_idleMarks] such contents are kept, and a record with neither goes.
  void _dropIfIdle(_Content content) {
    if (!content.isIdle) return;
    content.idle();
    if (content.hasMark) {
      _idle
        ..remove(content)
        ..add(content);
    } else {
      _forget(content);
    }
    while (_idle.length > _idleMarks) {
      final oldest = _idle.first;
      _idle.remove(oldest);
      oldest.forgetMark();
      _forget(oldest);
    }
  }

  void _forget(_Content content) {
    _idle.remove(content);
    if (content.userIntent == _UserIntent.none && !content.hasMark) {
      _contents.remove(content.key);
    }
  }

  /// The layers that hold back staged preloads unless a host says otherwise:
  /// low power, a fast scroll, a metered network and thermal stress.
  static const Set<PlaybackPauseLayer> standardPreloadPausingLayers = {
    PlaybackPauseLayer.lowPower,
    PlaybackPauseLayer.fastScroll,
    PlaybackPauseLayer.meteredNetwork,
    PlaybackPauseLayer.thermalStress,
  };

  /// The clock layers that hold back new staged preload attempts while set.
  final Set<PlaybackPauseLayer> preloadPausingLayers;

  bool _preloadsPaused = false;

  /// Whether staged preloads wait now: a layer of [preloadPausingLayers] is
  /// set on the clock.
  bool get preloadsPaused => _preloadsPaused;

  bool _layersPausePreloads() =>
      _clock.pausedLayers.any(preloadPausingLayers.contains);

  void _onLayers() {
    if (_disposed) return;
    final paused = _layersPausePreloads();
    if (paused == _preloadsPaused) return;
    _preloadsPaused = paused;
    if (paused) return;
    for (final entry in List<_Entry>.of(_entries.values)) {
      if (entry.preloads.isNotEmpty &&
          entry.attempt == null &&
          !entry.isFinal) {
        _start(entry);
      }
    }
  }

  final AssetProducer? _producer;
  final PlaybackClock _clock;
  final bool _ownsClock;
  final Listenable? _memoryPressure;
  AssetCacheBudgets _budgets;
  bool _disposed = false;

  /// What a binding paints before its entry has produced any stage.
  final AssetPaintable placeholder;

  final Map<(MediaKey, AssetSpec), _Entry> _entries = {};
  // Entries nobody is bound to, per tier, least recently used first.
  final Map<AssetTier, LinkedHashSet<_Entry>> _unpinned = {
    for (final tier in AssetTier.values) tier: LinkedHashSet<_Entry>.identity(),
  };
  final Map<AssetTier, int> _bytes = {
    for (final tier in AssetTier.values) tier: 0,
  };
  // The background holds on, each with the content it leaves playing.
  final List<Set<MediaKey>> _backgroundHolds = [];

  // Whether a background hold holds the content [key]: one is on that does
  // not leave it playing.
  bool _backgroundHeldFor(MediaKey key) =>
      _backgroundHolds.any((except) => !except.contains(key));

  /// The textures playing assets may take instead of a page slot, or null
  /// where the platform has no texture host.
  final FrameTexturePool? textures;

  // The idle textures go with the unpinned entries; what is on screen stays.
  void _onMemoryPressure() {
    clearAll();
    if (!_disposed) textures?.releaseIdle();
  }

  /// The clock every animated binding of this scope advances by. Hosts set
  /// its pause layers.
  PlaybackClock get clock => _clock;

  /// The byte budgets of the unattached entries.
  AssetCacheBudgets get budgets => _budgets;
  set budgets(AssetCacheBudgets value) {
    _budgets = value;
    _trim();
  }

  /// Holds every binding of the scope but the foreground ones and those of
  /// the content in [except] until the hold is released; see "Background
  /// hold" above. Holds count, so two surfaces over the others keep the hold
  /// until both are gone; a binding plays only while no hold holds it. A
  /// binding attached while a hold is on starts held.
  ///
  /// While a hold is on the producer starts no preload work
  /// (`AssetProducer.holdPreloads`): a surface that holds the others for a
  /// transition gets the frames of its transition, not a queue of work for
  /// what nobody shows yet.
  ///
  /// Throws a [StateError] after [dispose], as [attach] does.
  AssetBackgroundHold holdBackground({Set<MediaKey> except = const {}}) {
    if (_disposed) {
      throw StateError('AssetCacheScope.holdBackground called after dispose.');
    }
    final hold = Set<MediaKey>.of(except);
    _backgroundHolds.add(hold);
    _refreshBackgroundHeld();
    if (_backgroundHolds.length == 1) _producer?.holdPreloads(held: true);
    return AssetBackgroundHold._(() {
      if (_disposed) return;
      _backgroundHolds.remove(hold);
      _refreshBackgroundHeld();
      if (_backgroundHolds.isEmpty) _producer?.holdPreloads(held: false);
    });
  }

  /// Whether a background hold is on.
  bool get isBackgroundHeld => _backgroundHolds.isNotEmpty;

  /// Holds every binding of the entry for [key] at [spec], as if each
  /// surface held it (`AssetBinding.held`), until the hold is released: the
  /// playback stops on its frame, keeps it on screen and costs no decoding,
  /// then goes on from that frame. For a surface that plays the same content
  /// another way meanwhile (a player with sound over a muted loop). Holds
  /// count; a binding attached to the entry while one is on starts held.
  /// Without such an entry there is no playback to hold, and the hold is
  /// released already.
  ///
  /// [picture], the frame the playback showed as it was held (read off a
  /// surface), is what every surface of the entry draws while the hold is on
  /// ([AssetPaintable.holdPicture]), so the frame held is exactly that one;
  /// the scope owns it from now on. A hold that is not the first disposes
  /// its picture: the first one's stays.
  ///
  /// Throws a [StateError] after [dispose], as [attach] does.
  AssetPlaybackHold holdPlayback(
    MediaKey key,
    AssetSpec spec, {
    Image? picture,
  }) {
    if (_disposed) {
      picture?.dispose();
      throw StateError('AssetCacheScope.holdPlayback called after dispose.');
    }
    final entry = _entries[(key, spec)];
    if (entry == null) {
      picture?.dispose();
      return AssetPlaybackHold._(null);
    }
    if (entry.playbackHolds++ == 0) {
      entry.setHeld(held: true);
      final paintable = entry.paintable;
      if (paintable == null) {
        picture?.dispose();
      } else {
        paintable.holdPicture(picture);
      }
    } else {
      picture?.dispose();
    }
    return AssetPlaybackHold._(() {
      if (_disposed) return;
      if (--entry.playbackHolds == 0) {
        entry.paintable?.holdPicture(null);
        entry.setHeld(held: false);
      }
    });
  }

  void _refreshBackgroundHeld() {
    for (final entry in List<_Entry>.of(_entries.values)) {
      final held = _backgroundHeldFor(entry.key);
      for (final binding in List<_EntryBinding>.of(entry.bindings)) {
        binding.backgroundHeld = held;
      }
    }
  }

  /// Whether any binding is attached to the entry for [key] at [spec].
  bool isAttached(MediaKey key, AssetSpec spec) =>
      _entries[(key, spec)]?.bindings.isNotEmpty ?? false;

  /// Whether the cache holds an entry for [key] at [spec], attached or not.
  bool contains(MediaKey key, AssetSpec spec) =>
      _entries.containsKey((key, spec));

  /// The size of the picture an entry of [key] draws
  /// ([AssetPaintable.pictureSize]), whatever its spec, or null when none
  /// can say: the content's proportion, for a surface that has to place it
  /// before it knows its size.
  Size? pictureSizeOf(MediaKey key) {
    for (final entry in _contents[key]?.entries ?? const <_Entry>{}) {
      if (entry.paintable?.pictureSize case final size?) return size;
    }
    return null;
  }

  /// How far into its pass the playback of the entry for [key] at [spec] is,
  /// or null when there is no such entry or it does not play
  /// ([AssetPaintable.playbackPosition]).
  Duration? playbackPosition(MediaKey key, AssetSpec spec) =>
      _entries[(key, spec)]?.paintable?.playbackPosition;

  /// Moves the playback of the entry for [key] at [spec] to [position] into
  /// its pass ([AssetPaintable.seekPlayback]), handing it [picture], which
  /// the scope owns from now on; without such an entry it only disposes
  /// [picture].
  void seekPlayback(
    MediaKey key,
    AssetSpec spec,
    Duration position, {
    Image? picture,
  }) {
    final paintable = _entries[(key, spec)]?.paintable;
    if (paintable == null) {
      picture?.dispose();
      return;
    }
    paintable.seekPlayback(position, picture: picture);
  }

  /// Hands [descriptor] to the producer before a surface attaches its
  /// content, so the attempt needs no lookup and the bindings read the
  /// content's facts from the attach frame (`AssetProducer.know`). Does
  /// nothing after [dispose].
  void know(MediaDescriptor descriptor) {
    if (_disposed) return;
    _producer?.know(descriptor);
  }

  /// Bytes the entries of [tier] count, attached or not.
  int bytesIn(AssetTier tier) => _bytes[tier]!;

  /// How many entries the cache holds.
  int get entryCount => _entries.length;

  /// Attaches [key] decoded as [spec], to be used as [profile] says.
  ///
  /// Throws a [StateError] after [dispose]: a surface that outlives its scope
  /// is a lifecycle bug to see, not to absorb.
  ///
  /// [downloadContext] is the surface's tag for the [autoDownload] policy
  /// (where it shows the content). It never changes which entry the binding
  /// gets; a binding whose tag lets waiting content download starts it.
  AssetBinding attach(
    MediaKey key,
    AssetSpec spec,
    AssetProfile profile, {
    AutoDownloadContext? downloadContext,
  }) {
    if (_disposed) {
      throw StateError('AssetCacheScope.attach called after dispose.');
    }
    final entry = _entryFor(key, spec);
    final binding = _EntryBinding(
      scope: this,
      entry: entry,
      profile: profile,
      downloadContext: downloadContext,
    )..entryHeld = entry.playbackHolds > 0;
    _unpinned[entry.tier]!.remove(entry);
    entry.bindings.add(binding);
    entry.demand.refresh(entry);
    entry.content.contextsChanged();
    entry.syncShown();
    if (entry.attempt == null && !entry.isFinal) {
      _start(entry);
    } else {
      // A binding whose tag allows it starts content that waits.
      if (!entry.content.downloading && _mayDownloadNow(entry)) {
        _restart(entry);
      }
    }
    // After the start: a memory hit answered inside it needs no sibling.
    binding
      ..reborrow()
      ..syncPlayback();
    return binding;
  }

  // The sibling of [entry] with the best stage beyond [above], the larger
  // decode on a tie, or null. A template decode is alpha only, so only an
  // entry of the same decode mode draws the same picture.
  _Entry? _siblingOf(_Entry entry, AssetStage above) {
    _Entry? best;
    for (final sibling in entry.content.entries) {
      if (identical(sibling, entry) ||
          sibling.lent == null ||
          sibling.spec.decodeMode != entry.spec.decodeMode ||
          sibling.lentStage.index <= above.index) {
        continue;
      }
      if (best == null ||
          sibling.lentStage.index > best.lentStage.index ||
          (sibling.lentStage == best.lentStage &&
              _area(sibling) > _area(best))) {
        best = sibling;
      }
    }
    return best;
  }

  static int _area(_Entry entry) =>
      entry.spec.pixelWidth * entry.spec.pixelHeight;

  // A borrowed sibling is pinned like a bound entry: what a binding shows is
  // never evicted under it.
  void _borrow(_Entry sibling) {
    sibling.borrowers++;
    _unpinned[sibling.tier]!.remove(sibling);
  }

  void _giveBack(_Entry sibling) {
    sibling.borrowers--;
    _release(sibling);
    _trim();
  }

  // An entry nobody binds or borrows any more: what has a stage worth keeping
  // waits in the budget, the rest goes at once.
  void _release(_Entry entry) {
    if (entry.isPinned) return;
    if (entry.stage.index <= AssetStage.placeholder.index) {
      _evict(entry);
    } else {
      _unpinned[entry.tier]!.add(entry);
    }
  }

  /// Preloads [key] decoded as [spec] as far as [stage], before any surface
  /// shows it. [distance] orders it among preloads: 0 for the next item,
  /// larger further away. Preloading an entry a binding holds changes nothing
  /// about its work. See "Staged preloads" above.
  ///
  /// Throws a [StateError] after [dispose], as [attach] does.
  AssetPreload preload(
    MediaKey key,
    AssetSpec spec, {
    required AssetPreloadStage stage,
    int distance = 0,
  }) {
    if (_disposed) {
      throw StateError('AssetCacheScope.preload called after dispose.');
    }
    final entry = _entryFor(key, spec);
    final preload = _Preload(this, entry, stage, distance);
    _unpinned[entry.tier]!.remove(entry);
    entry.preloads.add(preload);
    entry.demand.refresh(entry);
    if (entry.attempt == null && !entry.isFinal) _start(entry);
    return preload;
  }

  _Entry _entryFor(MediaKey key, AssetSpec spec) =>
      _entries.putIfAbsent((key, spec), () {
        final content = _contentOf(key);
        final created = _Entry(this, content, spec);
        content.entries.add(created);
        return created;
      });

  void _preloadCancelled(_Preload preload) {
    final entry = preload.entry;
    entry.preloads.remove(preload);
    entry.demand.refresh(entry);
    _lastClaimGone(entry);
  }

  // Cancels the work of an entry nobody binds or preloads any more and puts it
  // in the budget, or drops it.
  void _lastClaimGone(_Entry entry) {
    if (entry.bindings.isNotEmpty || entry.preloads.isNotEmpty) return;
    final content = entry.content;
    // A user's download goes on with no surface (a viewer closed with no
    // tile of the content left): until the content is whole, the user
    // cancels, or it fails. That covers content final for the spec whose
    // paintable still pulls the rest.
    if (!_disposed &&
        content.userIntent == _UserIntent.requested &&
        (entry.reported.isActive || content.streams(entry))) {
      entry.keptForDownload = true;
      entry.demand.refresh(entry);
      return;
    }
    final downloading = entry.reported.isActive;
    entry.attempt?.cancel();
    // Nobody draws it any more; a re-attach starts an attempt that tells.
    entry.reported = AssetTransfer.none;
    _release(entry);
    content.refresh();
    // A download the policy wants outlives the surface that ran it: another
    // spec of the content still shown takes it on from the bytes stored. One
    // only that surface requested stops here, and its siblings show the
    // bytes it left.
    if (downloading) _startOneDownload(content);
    _trim();
  }

  // An entry kept for a user's download whose attempt ended: nobody else
  // claims it, so it goes to the budget or is dropped.
  void _keptAttemptEnded(_Entry entry) {
    if (!entry.keptForDownload || entry.content.streams(entry)) return;
    entry.keptForDownload = false;
    entry.reported = AssetTransfer.none;
    _release(entry);
    entry.content.refresh();
    _trim();
  }

  /// Drops every entry nobody is bound to, disposing their paintables. Pinned
  /// entries stay: eviction never touches a live binding. This is also what
  /// the memory-pressure signal does. Baked atlas pages are not the cache's
  /// to drop; their source applies its own retention and pressure rules.
  void clearAll() {
    if (_disposed) return;
    for (final tier in AssetTier.values) {
      List<_Entry>.of(_unpinned[tier]!).forEach(_evict);
    }
  }

  /// The host's signal that the network is back: attempts that failed
  /// transiently are repeated for entries that are still attached. Permanent
  /// failures wait for a re-attach or [AssetBinding.retry]; entries nobody is
  /// bound to are left alone.
  void connectivityRestored() {
    if (_disposed) return;
    for (final entry in List<_Entry>.of(_entries.values)) {
      if ((entry.bindings.isNotEmpty || entry.preloads.isNotEmpty) &&
          entry.attempt == null &&
          !entry.isFinal &&
          entry.failureKind == AssetFailureKind.transient &&
          entry.content.userIntent != _UserIntent.cancelled &&
          entry.reported is! AssetTransfer$AwaitingUser) {
        _start(entry);
      }
    }
  }

  /// Cancels every attempt, disposes every entry and stops listening to the
  /// memory-pressure signal.
  /// Bindings still around go silent. Idempotent. Disposes the clock only if
  /// the scope made it.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _memoryPressure?.removeListener(_onMemoryPressure);
    _clock.removeLayerListener(_onLayers);
    autoDownload.changes.removeListener(_onAutoDownloadChanged);
    for (final entry in List<_Entry>.of(_entries.values)) {
      entry.attempt?.cancel();
      entry.preloads.toList().forEach((preload) => preload.cancelled = true);
      entry.preloads.clear();
      for (final binding in List<_EntryBinding>.of(entry.bindings)) {
        binding.detach();
      }
      _evict(entry);
    }
    if (_ownsClock) _clock.dispose();
  }

  // --- Attempts -------------------------------------------------------------

  void _start(_Entry entry) {
    final producer = _producer;
    if (producer == null) return;
    // Only preloads want it, and the device or the network asks to wait.
    if (entry.bindings.isEmpty && _preloadsPaused) return;
    final attempt = _Attempt(this, entry);
    entry.attempt = attempt;
    // The last attempt's transfer is no fact about this one: the producer
    // announces it again if the content is still missing, and a binding still
    // drawing the old one hears when it does not.
    entry.reported = AssetTransfer.none;
    try {
      final task = producer.produce(
        AssetRequest(entry.key, entry.spec),
        attempt,
        entry.demand,
      );
      // The attempt may already have ended inside produce (a memory hit).
      if (!attempt.ended) attempt.task = task;
    } on Object catch (error, stackTrace) {
      // The contract says produce reports failures; one that throws is a
      // bug, recorded for diagnostics and not retried by connectivity.
      attempt.fail(error, stackTrace, AssetFailureKind.permanent);
    }
    entry.content.refresh();
  }

  void _advance(
    _Entry entry,
    AssetStage stage,
    AssetPaintable paintable,
    int bytes,
    AssetTier tier,
  ) {
    assert(stage != AssetStage.none, 'advance needs a stage to draw');
    if (stage.index < entry.stage.index) {
      paintable.dispose();
      return;
    }
    final previous = entry.paintable;
    // A stand-in (a preview, a thumbnail) replaced by a higher stage is kept
    // for the bindings that were showing it: they draw the new stage over it
    // (a bitmap stand-in stays opaque beneath) and release it once that
    // stage is opaque. Each rise keeps the stand-in it replaced, so a
    // preview gives way to the thumbnail and the thumbnail to the content.
    // Without a waiting binding there is nobody to keep it for; one that
    // shows a sibling's content was not showing the stand-in and has nothing
    // to fade over.
    final waiting = [
      for (final binding in entry.bindings)
        if (binding._borrowed == null) binding,
    ];
    final keep =
        previous != null &&
        entry.stage != AssetStage.none &&
        entry.stage.index <= AssetStage.placeholder.index &&
        stage.index > entry.stage.index &&
        waiting.isNotEmpty;
    if (keep) {
      // A binding that held the stand-in before holds this one only if it
      // still waits: the counts start over with the new stand-in.
      for (final binding in entry.bindings) {
        binding._holdsStandIn = false;
      }
      entry
        ..disposeStandIn()
        ..standIn = previous
        ..standInStage = entry.stage;
      for (final binding in waiting) {
        binding._holdsStandIn = true;
        entry.standInHolders++;
      }
    } else if (previous != null && !identical(previous, paintable)) {
      previous.dispose();
    }
    if (previous != null)
      _bytes[entry.tier] = _bytes[entry.tier]! - entry.bytes;
    entry
      ..stage = stage
      ..paintable = paintable
      ..bytes = bytes
      ..tier = tier
      ..lastError = null
      ..failureKind = null;
    _bytes[tier] = _bytes[tier]! + bytes;
    if (entry.isFinal) _finish(entry);
    for (final binding in List<_EntryBinding>.of(entry.bindings)) {
      binding.entryChanged();
    }
    // A sibling waiting below its first frame may draw this stage now (or a
    // better one of the entry it borrows from).
    for (final sibling in List<_Entry>.of(entry.content.entries)) {
      if (identical(sibling, entry)) continue;
      for (final binding in List<_EntryBinding>.of(sibling.bindings)) {
        binding.siblingChanged(entry);
      }
    }
    _trim();
  }

  // The entry reached its final stage: no attempt runs any more, and its
  // content is no longer missing.
  void _finish(_Entry entry) {
    final content = entry.content;
    // Content streamed as it plays can be final for a spec (its first frame)
    // with only part of its bytes here: the attempt goes on reporting the
    // bytes its paintable pulls (AssetProgress.transfer), and the other
    // specs wait for the rest.
    final streaming = entry.reported.isActive && !content.isWhole;
    if (entry.attempt case final attempt?) {
      attempt
        ..ended = true
        ..finished = true;
      if (streaming) content.streamFrom(entry, attempt);
    }
    entry.attempt = null;
    entry.reported = AssetTransfer.none;
    // The content's bytes are local now (a stand-in a spec stops at says
    // nothing about them). A spec still waiting for them, or whose download
    // stopped short, starts again and reads them; without it, a tile whose
    // viewer downloaded the content would show its old download for good.
    if (streaming || entry.stage.index < AssetStage.firstFrame.index) {
      content.refresh();
      _keptAttemptEnded(entry);
      return;
    }
    _contentLocal(content);
  }

  // A finished attempt of [entry] reported the bytes its paintable pulled
  // since (content streamed as it plays).
  void _streamed(_Entry entry, int received, int? total) {
    final content = entry.content;
    content.read(entry, received, total);
    if (content.isWhole) _contentLocal(content);
  }

  // The rest of [entry]'s streamed content failed to arrive.
  void _streamFailed(_Entry entry, AssetFailureKind kind) {
    final content = entry.content;
    content
      ..stopReading(entry)
      ..streamFailed(kind);
    _keptAttemptEnded(entry);
  }

  // The producer can make nothing better than the entry's stage for its spec
  // (AssetProgress.bestReached): that stage is final.
  void _bestReached(_Entry entry) {
    if (entry.stage == AssetStage.none) {
      entry.attempt?._end();
      return;
    }
    entry.bestReached = true;
    _finish(entry);
    for (final binding in List<_EntryBinding>.of(entry.bindings)) {
      binding.entryChanged();
    }
  }

  // --- Budget ---------------------------------------------------------------

  void _trim() {
    for (final tier in AssetTier.values) {
      final unpinned = _unpinned[tier]!;
      final budget = _budgets.of(tier);
      while (_bytes[tier]! > budget && unpinned.isNotEmpty) {
        _evict(unpinned.first);
      }
    }
  }

  void _evict(_Entry entry) {
    _unpinned[entry.tier]!.remove(entry);
    if (identical(_entries[(entry.key, entry.spec)], entry)) {
      _entries.remove((entry.key, entry.spec));
    }
    final content = entry.content;
    if (content.entries.remove(entry)) {
      entry.keptForDownload = false;
      content
        ..stopReading(entry)
        ..refresh();
      _dropIfIdle(content);
    }
    if (entry.paintable != null) {
      _bytes[entry.tier] = _bytes[entry.tier]! - entry.bytes;
    }
    entry.paintable?.dispose();
    entry
      ..disposeStandIn()
      ..paintable = null
      ..bytes = 0;
  }

  void _detached(_EntryBinding binding) {
    final entry = binding.entry;
    entry.bindings.remove(binding);
    entry.demand.refresh(entry);
    entry.content.contextsChanged();
    if (binding.holdsFrame) entry.syncKeep();
    entry.syncShown();
    // A surface that requested the content left while others of the same
    // spec stay (a viewer page of a tile's own spec): its download stops
    // if nothing else wants it, as on the last claim.
    if (binding._requestsDownload && entry.bindings.isNotEmpty) {
      _requestChanged(entry);
    }
    _lastClaimGone(entry);
  }
}

// --- Internals --------------------------------------------------------------

final class _Entry {
  _Entry(this.scope, this.content, this.spec);

  final AssetCacheScope scope;
  // The content this entry decodes, shared by every spec of it.
  final _Content content;
  MediaKey get key => content.key;
  final AssetSpec spec;
  final Set<_EntryBinding> bindings = {};
  final Set<_Preload> preloads = Set.identity();
  late final _Demand demand = _Demand(this);
  AssetStage stage = AssetStage.none;
  AssetPaintable? paintable;
  // The stand-in the last rise replaced (a preview, a thumbnail), while a
  // binding still draws over it, and the stage it was.
  AssetPaintable? standIn;
  AssetStage standInStage = AssetStage.none;
  int standInHolders = 0;
  int bytes = 0;
  AssetTier tier = AssetTier.still;
  Object? lastError;
  AssetFailureKind? failureKind;
  _Attempt? attempt;
  // The content's transfer as this entry's last attempt reported it, an
  // input of the content's transfer (_Content.transfer), which is what the
  // surfaces show. A failed or waiting one outlives its attempt: the content
  // is still missing.
  AssetTransfer reported = AssetTransfer.none;

  // Sets what the attempt reported and lets the content derive its transfer
  // again.
  void report(AssetTransfer value) {
    if (value == reported) return;
    reported = value;
    content.refresh();
  }

  // Whether the entry stays, with no surface, for a user's download that
  // goes on (AssetCacheScope._lastClaimGone).
  bool keptForDownload = false;

  // The finished attempt whose paintable still pulls the content's bytes,
  // reporting them (_Content.streamFrom).
  _Attempt? streaming;

  // Whether this entry downloads the content: its attempt reports a
  // transfer under way, or it stays for a user's download.
  bool get downloads => reported.isActive || keptForDownload;

  // The tags of the attached bindings.
  Set<AutoDownloadContext?> get downloadContexts => {
    for (final binding in bindings) binding.downloadContext,
  };

  // What the producer said the content is; kept beyond the attempt, since it
  // is a fact about the content, not about one attempt.
  MediaDescriptor? descriptor;
  // Bindings of sibling entries that show this entry's stage.
  int borrowers = 0;
  // Holds of the entry's playback (AssetCacheScope.holdPlayback).
  int playbackHolds = 0;

  void setHeld({required bool held}) {
    for (final binding in List<_EntryBinding>.of(bindings)) {
      binding.entryHeld = held;
    }
  }

  bool get isPinned =>
      bindings.isNotEmpty ||
      preloads.isNotEmpty ||
      borrowers > 0 ||
      keptForDownload;

  // What a binding of a sibling entry may show of this one. A paintable that
  // plays may be in the middle of a loop, and the borrower's own entry starts
  // from frame 0: it is lent as its first-frame still, or not at all.
  AssetPaintable? get lent => switch (paintable) {
    final playing? when playing.isAnimated => playing.firstFrame,
    final other => other,
  };

  // The stage of what is lent: a playing paintable's still is a first frame.
  AssetStage get lentStage =>
      (paintable?.isAnimated ?? false) ? AssetStage.firstFrame : stage;

  // Whether the paintable keeps its frame: some binding holds it on screen.
  void syncKeep() =>
      paintable?.keepFrame(keep: bindings.any((binding) => binding.holdsFrame));

  // Whether a binding plays the paintable now (is on the clock).
  bool _playing = false;

  // Tells the paintable when its playback goes on after a stop: the first
  // binding that plays again after none did.
  void syncPlaying() {
    final playing = bindings.any((binding) => binding._registered);
    if (playing == _playing) return;
    _playing = playing;
    if (playing) paintable?.playbackResumed();
  }

  // Whether a binding shows the entry: one is attached and visible.
  bool _shown = false;

  // Tells the paintable when the last binding that showed it hid or
  // detached, so it gives back what it leased for the screen now rather than
  // at its idle sweep. Called after syncKeep wherever both change, so a
  // binding held as it hides has its frame kept first.
  void syncShown() {
    final shown = bindings.any((binding) => binding.visible);
    if (shown == _shown) return;
    _shown = shown;
    if (!shown) paintable?.leftScreen();
  }

  void disposeStandIn() {
    standIn?.dispose();
    standIn = null;
    standInStage = AssetStage.none;
    standInHolders = 0;
  }

  // Whether the producer said the stage reached is the best it can make for
  // the spec (AssetProgress.bestReached).
  bool bestReached = false;

  bool get isFinal =>
      stage == AssetStage.full ||
      (stage == AssetStage.firstFrame &&
          spec.variant == AssetVariant.firstFrame) ||
      (bestReached && stage != AssetStage.none);
}

// What the user asked of a content's download.
enum _UserIntent {
  // Nothing: the policy and the surfaces decide.
  none,

  // Download it whole (AssetBinding.download), whatever the policy.
  requested,

  // Do not download it until the user asks (AssetBinding.cancelDownload).
  cancelled,
}

// Bytes of a content held outside an attempt: by a reader outside the cache
// (AssetOutsideReader) or by the paintable of a spec whose attempt finished
// while the content was still streaming.
typedef _Held = ({int received, int? total, bool streamed});

/// The download state of one content, whatever the spec: its entries, the
/// user's intent, the most of its bytes any report gave, the bytes readers
/// hold outside an attempt, and the transfer every surface of it shows.
///
/// One record per key; the transfer is derived here and nowhere else
/// ([refresh]), and the policy's answer is kept until something it weighs
/// changes. A record whose entries are gone and that no reader holds keeps
/// only the user's intent and, for a while, its bytes mark
/// (AssetCacheScope._dropIfIdle).
final class _Content {
  _Content(this.scope, this.key);

  final AssetCacheScope scope;
  final MediaKey key;

  // Every entry of the content, whatever its spec: the siblings a binding
  // below its first frame borrows a stage from, and the attempts whose
  // reports make the transfer.
  final Set<_Entry> entries = Set.identity();

  // Kept for the scope's life, past eviction: content scrolled back into
  // view after a cancel is not fetched again until the user asks.
  _UserIntent userIntent = _UserIntent.none;

  // The most of the content's bytes any report gave, until it is whole: a
  // surface that comes back to a download draws it where it was, whatever
  // the next attempt reports first (a fresh request counts from 0, and the
  // bytes stored meanwhile are not lost).
  ({int received, int? total})? _mark;

  // Bytes held outside an attempt, per holder (an AssetOutsideReader, or an
  // _Entry whose finished attempt streams).
  final Map<Object, _Held> _held = {};

  // The rest of a streamed user's download failed (AssetProgress.fail after
  // the spec was final).
  AssetFailureKind? _streamFailure;

  // Whether all the content's bytes are local now.
  bool _whole = false;

  bool get isWhole {
    if (_whole) return true;
    final mark = _mark;
    return mark != null && mark.total != null && mark.received >= mark.total!;
  }

  // Whether nothing but the user's intent keeps the record.
  bool get isIdle => entries.isEmpty && _held.isEmpty;

  // --- Policy ---------------------------------------------------------------

  AutoDownload? _policy;
  MediaDescriptor? _policyFor;

  void policyChanged() => _policy = null;

  void contextsChanged() => _policy = null;

  // The policy's answer for the content as every surface of it shows it, the
  // most permissive of their tags; kept until the policy, the tags or the
  // descriptor change.
  AutoDownload _policyAnswer(MediaDescriptor descriptor) {
    if (_policy case final kept? when _policyFor == descriptor) return kept;
    final policy = scope.autoDownload;
    final contexts = {for (final entry in entries) ...entry.downloadContexts};
    var best = AutoDownload.manual;
    if (contexts.isEmpty) {
      best = policy.decide(descriptor, policy.defaultContext);
    }
    for (final context in contexts) {
      best = best.or(
        policy.decide(descriptor, context ?? policy.defaultContext),
      );
      if (best == AutoDownload.now) break;
    }
    _policyFor = descriptor;
    return _policy = best;
  }

  // Whether a surface of the content requests it while it shows it
  // (AssetBinding.requestsDownload).
  bool get _requested => entries.any(
    (entry) => entry.bindings.any((binding) => binding._requestsDownload),
  );

  /// The scope's answer for [entry] (AssetDemand.autoDownload). A user's cancel wins over everything; one
  /// transfer runs per content, so another spec downloading it makes this
  /// one wait; then a user's download, a surface's request, and the policy.
  AutoDownload answer(_Entry entry, MediaDescriptor? descriptor) {
    if (userIntent == _UserIntent.cancelled) return AutoDownload.manual;
    for (final other in entries) {
      if (!identical(other, entry) && other.downloads) {
        return AutoDownload.manual;
      }
    }
    if (userIntent == _UserIntent.requested || _requested) {
      return AutoDownload.now;
    }
    if (descriptor == null) return AutoDownload.now;
    return _policyAnswer(descriptor);
  }

  // Whether anyone wants the content downloaded now: the user, a surface
  // that requests it, or the policy. The user's cancel wins.
  bool get wanted {
    if (userIntent == _UserIntent.cancelled) return false;
    if (userIntent == _UserIntent.requested || _requested) return true;
    final descriptor = _descriptor;
    return descriptor == null || _policyAnswer(descriptor) == AutoDownload.now;
  }

  MediaDescriptor? get _descriptor {
    for (final entry in entries) {
      if (entry.descriptor case final known?) return known;
    }
    return null;
  }

  // --- Bytes ----------------------------------------------------------------

  // Whether an entry of the content downloads it: its attempt reports a
  // transfer under way, or it stays for a user's download.
  bool get downloading => entries.any((entry) => entry.downloads);

  // Whether [entry]'s finished attempt still streams the content.
  bool streams(_Entry entry) => _held.containsKey(entry);

  // [entry]'s attempt finished with the content still arriving: its
  // paintable pulls the rest, and the attempt goes on reporting it.
  void streamFrom(_Entry entry, _Attempt attempt) {
    entry.streaming = attempt;
    final last = entry.reported;
    _held[entry] = (
      received: switch (last) {
        AssetTransfer$Receiving(:final received) => received,
        _ => 0,
      },
      total: last.total,
      streamed: true,
    );
  }

  // [holder] holds [received] bytes of [total] now.
  void read(Object holder, int received, int? total) {
    final value = note(
      received < 0 ? 0 : received,
      total == null || total <= 0 ? null : total,
    );
    _held[holder] = (
      received: value.received,
      total: value.total,
      streamed: holder is _Entry,
    );
    if (value.total case final all? when value.received >= all) local();
    refresh();
  }

  void stopReading(Object holder) {
    if (holder is _Entry) holder.streaming = null;
    if (_held.remove(holder) != null) refresh();
  }

  void streamFailed(AssetFailureKind kind) {
    _streamFailure = kind;
    refresh();
  }

  // Forgets a failed rest; whether there was one.
  bool clearStreamFailure() {
    final failed = _streamFailure != null;
    _streamFailure = null;
    return failed;
  }

  // The content is local: the bytes it took are no longer a download.
  void local() {
    _whole = true;
    _mark = null;
    _streamFailure = null;
    for (final holder in List<Object>.of(_held.keys)) {
      if (holder is _Entry) holder.streaming = null;
    }
    _held.clear();
  }

  bool get hasMark => _mark != null;

  // Nobody holds the content: what the entries and readers made goes; the
  // user's intent and the mark stay (AssetCacheScope._dropIfIdle).
  void idle() {
    _streamFailure = null;
    _whole = false;
    _policy = null;
    _transfer = AssetTransfer.none;
  }

  void forgetMark() => _mark = null;

  // Raises the mark to [received] of [total] and answers the bytes the
  // surfaces show: at least the mark, for the same total.
  ({int received, int? total}) note(int received, int? total) {
    final mark = _mark;
    if (mark != null &&
        mark.received > received &&
        (total == null || mark.total == null || mark.total == total)) {
      return (received: mark.received, total: total ?? mark.total);
    }
    _whole = false;
    return _mark = (received: received, total: total ?? mark?.total);
  }

  // --- Transfer -------------------------------------------------------------

  AssetTransfer _transfer = AssetTransfer.none;

  /// What the surfaces of every spec show that is not final for its spec.
  AssetTransfer get transfer => _transfer;

  /// What a surface of [entry] shows: nothing once the entry is final,
  /// unless the rest of its streamed content failed (the control's retry).
  AssetTransfer transferFor(_Entry entry) {
    if (!entry.isFinal) return _transfer;
    return _transfer is AssetTransfer$Failed && _streamFailure != null
        ? _transfer
        : AssetTransfer.none;
  }

  // Derives the transfer from its inputs and tells every surface of the
  // content when it changed; a change of bytes only is heard at most once
  // per frame.
  void refresh() {
    final next = _withSize(_derive());
    if (next == _transfer) return;
    final bytesOnly =
        next is AssetTransfer$Receiving && _transfer is AssetTransfer$Receiving;
    _transfer = next;
    _signal(bytesOnly: bytesOnly);
  }

  AssetTransfer _derive() {
    // A download under way, of the spec furthest along.
    AssetTransfer? active;
    for (final entry in entries) {
      final reported = entry.reported;
      if (!reported.isActive) continue;
      if (active == null || _receivedOf(reported) > _receivedOf(active)) {
        active = reported;
      }
    }
    // Bytes held outside an attempt: a user's download streaming on, or a
    // reader outside the cache pulling content someone wants, are the
    // download; otherwise they are bytes received.
    final wanted = this.wanted;
    for (final held in _held.values) {
      final counts = held.streamed
          ? userIntent == _UserIntent.requested
          : wanted;
      if (!counts) continue;
      if (active == null || held.received > _receivedOf(active)) {
        active = AssetTransfer.receiving(held.received, held.total);
      }
    }
    if (active != null) return _atMark(active);
    if (_streamFailure case final kind?) {
      return AssetTransfer.failed(kind, _mark?.received ?? 0, _mark?.total);
    }
    // The content waits: for a retry after a failure, or for the user.
    var waiting = AssetTransfer.none;
    for (final entry in entries) {
      switch (entry.reported) {
        case final AssetTransfer$Failed failed:
          waiting = failed;
        case final AssetTransfer$AwaitingUser awaiting
            when waiting is! AssetTransfer$Failed:
          waiting = awaiting;
        default:
          break;
      }
    }
    return _atMark(waiting);
  }

  static int _receivedOf(AssetTransfer transfer) => switch (transfer) {
    AssetTransfer$Receiving(:final received) => received,
    _ => 0,
  };

  // [value] as the surfaces see it: a waiting or receiving transfer of a
  // content that has received more before reads that much, and one that
  // waits for the user shows the bytes the last download left, which the
  // next one resumes from.
  AssetTransfer _atMark(AssetTransfer value) {
    final mark = _mark;
    if (mark == null || mark.received == 0) return value;
    return switch (value) {
      AssetTransfer$Receiving(:final received, :final total)
          when mark.received > received &&
              (total == null || mark.total == null || mark.total == total) =>
        AssetTransfer.receiving(mark.received, total ?? mark.total),
      AssetTransfer$Waiting() => AssetTransfer.receiving(
        mark.received,
        mark.total,
      ),
      AssetTransfer$AwaitingUser(:final total, received: 0) =>
        AssetTransfer.awaitingUser(total ?? mark.total, mark.received),
      _ => value,
    };
  }

  // The source did not say how large the content is; the host did.
  AssetTransfer _withSize(AssetTransfer transfer) {
    final size = _descriptor?.byteSize;
    if (size == null || transfer.total != null) return transfer;
    return switch (transfer) {
      AssetTransfer$Waiting() => AssetTransfer.waiting(size),
      AssetTransfer$Receiving(:final received) => AssetTransfer.receiving(
        received,
        size,
      ),
      AssetTransfer$AwaitingUser(:final received) => AssetTransfer.awaitingUser(
        size,
        received,
      ),
      AssetTransfer$Failed(:final kind, :final received) =>
        AssetTransfer.failed(kind, received, size),
      AssetTransfer$None() => transfer,
    };
  }

  void _signal({required bool bytesOnly}) {
    // A scope going away detaches every binding: nobody is to hear more.
    if (scope._disposed) return;
    final hearing = [for (final entry in entries) ...entry.bindings];
    if (hearing.isEmpty) return;
    void tell() {
      if (scope._disposed) return;
      for (final binding in hearing) {
        binding.transferChanged(bytesOnly: bytesOnly);
      }
    }

    // Inside a frame the change may come from a surface leaving the tree
    // (its binding detached while the tree is locked): the surfaces of the
    // content hear it after the frame, when they may rebuild.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      tell();
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) => tell());
    }
  }
}

/// A reader outside the cache (a platform player streaming the content)
/// accounting for the bytes it holds of one content; see
/// [AssetCacheScope.openOutsideReader]. Closed exactly once.
final class AssetOutsideReader {
  AssetOutsideReader._(this._scope, this._key);

  final AssetCacheScope _scope;
  final MediaKey _key;
  bool _closed = false;

  /// Whether [close] has run.
  bool get isClosed => _closed;

  /// The reader holds [received] bytes of [total] (null when unknown) of
  /// the content now. Ignored once closed.
  void report(int received, int? total) {
    if (_closed) return;
    _scope._outsideBytes(this, received, total);
  }

  /// The reader let the content go: its surfaces show the bytes it left and
  /// await the user, unless a spec of the content, or another reader,
  /// downloads it. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _scope._outsideClosed(this);
  }
}

final class _Demand implements AssetDemand {
  _Demand(this._entry);

  final _Entry _entry;

  @override
  Set<AutoDownloadContext?> get downloadContexts => _entry.downloadContexts;

  @override
  AutoDownload autoDownload(MediaDescriptor? descriptor) =>
      _entry.content.answer(_entry, descriptor);

  @override
  bool get downloadRequested =>
      _entry.content.userIntent == _UserIntent.requested;

  @override
  AssetPriority priority = AssetPriority.visible;

  @override
  AssetPreloadStage? preloadStage;

  @override
  int distance = 0;

  void refresh(_Entry entry) {
    // A user's download that goes on with no surface is still wanted now.
    priority =
        entry.keptForDownload ||
            entry.bindings.any((binding) => binding.visible)
        ? AssetPriority.visible
        : AssetPriority.preload;
    if (entry.bindings.isNotEmpty || entry.preloads.isEmpty) {
      preloadStage = null;
      distance = 0;
      return;
    }
    AssetPreloadStage? furthest;
    var nearest = entry.preloads.first.distance;
    for (final preload in entry.preloads) {
      furthest = furthest?.furthest(preload.stage) ?? preload.stage;
      if (preload.distance < nearest) nearest = preload.distance;
    }
    preloadStage = furthest;
    distance = nearest;
  }
}

final class _Preload implements AssetPreload {
  _Preload(this._scope, this.entry, this.stage, this.distance);

  final AssetCacheScope _scope;
  final _Entry entry;

  @override
  final AssetPreloadStage stage;

  @override
  final int distance;

  bool cancelled = false;

  @override
  bool get isCancelled => cancelled;

  @override
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    if (!_scope._disposed) _scope._preloadCancelled(this);
  }
}

final class _Attempt implements AssetProgress {
  _Attempt(this._scope, this._entry);

  final AssetCacheScope _scope;
  final _Entry _entry;
  AssetTask? task;
  bool ended = false;
  // Whether it ended at the entry's final stage, with no failure.
  bool finished = false;

  bool get _live => !ended && identical(_entry.attempt, this);

  // Whether it finished with the content still streaming: its byte reports
  // and a failure of the rest still count for the content.
  bool get _streams =>
      finished && !_scope._disposed && identical(_entry.streaming, this);

  @override
  void advance(
    AssetStage stage,
    AssetPaintable paintable, {
    required int bytes,
    AssetTier tier = AssetTier.still,
  }) {
    if (!_live || _scope._disposed) {
      paintable.dispose();
      return;
    }
    _scope._advance(_entry, stage, paintable, bytes, tier);
  }

  @override
  void describe(MediaDescriptor descriptor) {
    if (!_live || _scope._disposed || _entry.descriptor == descriptor) return;
    _entry.descriptor = descriptor;
    for (final binding in List<_EntryBinding>.of(_entry.bindings)) {
      binding.descriptorChanged();
    }
  }

  @override
  void waiting() {
    if (!_live || _scope._disposed) return;
    _entry.report(const AssetTransfer.waiting());
  }

  @override
  void transfer(int received, int? total) {
    if (_streams) {
      _scope._streamed(_entry, received, total);
      return;
    }
    if (!_live || _scope._disposed) return;
    final bytes = _entry.content.note(
      received < 0 ? 0 : received,
      total == null || total <= 0 ? null : total,
    );
    _entry.report(AssetTransfer.receiving(bytes.received, bytes.total));
  }

  @override
  void awaitingUser() {
    if (!_live || _scope._disposed) return;
    _entry.report(AssetTransfer.awaitingUser(_entry.reported.total));
  }

  @override
  void fail(
    Object error, [
    StackTrace? stackTrace,
    AssetFailureKind kind = AssetFailureKind.transient,
  ]) {
    if (_streams) {
      _scope._streamFailed(_entry, kind);
      return;
    }
    if (!_live) return;
    _entry
      ..lastError = error
      ..failureKind = kind;
    // A download that was under way turns into the retry a control shows.
    switch (_entry.reported) {
      case AssetTransfer$Waiting(:final total):
        _entry.report(AssetTransfer.failed(kind, 0, total));
      case AssetTransfer$Receiving(:final received, :final total):
        _entry.report(AssetTransfer.failed(kind, received, total));
      default:
        break;
    }
    _end();
  }

  @override
  void cancelled() {
    if (!_live) return;
    _end();
  }

  @override
  void bestReached() {
    if (!_live || _scope._disposed) return;
    _scope._bestReached(_entry);
  }

  /// Called by the scope: stops the work for good.
  void cancel() {
    if (ended) return;
    final running = task;
    _end();
    running?.cancel();
  }

  // The transfer stays: a failed or waiting one leaves the content missing.
  // The final stage, the last binding leaving and the next attempt clear it.
  void _end() {
    ended = true;
    if (!identical(_entry.attempt, this)) return;
    _entry.attempt = null;
    if (!_scope._disposed) _scope._keptAttemptEnded(_entry);
  }
}

final class _EntryBinding extends AssetBindingBase {
  _EntryBinding({
    required AssetCacheScope scope,
    required this.entry,
    required super.profile,
    required this.downloadContext,
  }) : _scope = scope,
       super(
         key: entry.key,
         spec: entry.spec,
         placeholder: scope.placeholder,
         clock: scope.clock,
         backgroundHeld: scope._backgroundHeldFor(entry.key),
       );

  final AssetCacheScope _scope;
  final _Entry entry;
  final AutoDownloadContext? downloadContext;
  bool _registered = false;
  // Waiting to release the entry's stand-in.
  bool _holdsStandIn = false;
  // The sibling whose stage this binding shows while its entry is below that
  // stage and below its first frame, or null.
  _Entry? _borrowed;
  // A replay turns a profile that does not animate into one that does, for
  // this binding.
  bool _replayed = false;
  // The pass of a profile that does not loop is over. The animated stage is
  // the entry's final one, so the paintable never changes under it.
  bool _ended = false;
  // The paintable a foreground binding rewound as it started to play: once
  // per attach and paintable, so a hold or a hide in between goes on from
  // the frame it was at.
  AssetPaintable? _rewound;
  late final _PlaybackTarget _target = _PlaybackTarget(
    clock.policy.frameIntervalFor(spec),
    _onTick,
  );

  /// Called by the scope when the entry's descriptor became known.
  void descriptorChanged() => signal();

  // Whether a byte report was heard in the frame under way, and whether one
  // waits for the next frame.
  bool _bytesHeard = false;
  bool _bytesPending = false;

  /// Called by the scope when the entry's transfer changed. Bytes arrive per
  /// chunk, several per frame on a fast network, and a surface needs one
  /// repaint per frame: a byte report after the first of a frame is heard on
  /// the next one.
  void transferChanged({required bool bytesOnly}) {
    if (bytesOnly && _bytesHeard) {
      _bytesPending = true;
      return;
    }
    signal();
    if (_bytesHeard) return;
    _bytesHeard = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _bytesHeard = false;
      if (!_bytesPending) return;
      _bytesPending = false;
      signal();
    });
  }

  @override
  MediaDescriptor? get descriptor => isDetached ? null : entry.descriptor;

  @override
  AssetTransfer get transfer =>
      isDetached ? AssetTransfer.none : entry.content.transferFor(entry);

  @override
  void download() {
    if (!isDetached) _scope._download(entry);
  }

  bool _requestsDownload = false;

  @override
  bool get requestsDownload => _requestsDownload;

  @override
  set requestsDownload(bool value) {
    if (value == _requestsDownload) return;
    _requestsDownload = value;
    if (!isDetached) _scope._requestChanged(entry);
  }

  @override
  void cancelDownload() {
    if (!isDetached) _scope._cancelDownload(entry);
  }

  /// Called by the scope when the entry gained a stage.
  void entryChanged() {
    reborrow();
    syncPlayback();
    signal();
  }

  /// Called by the scope when [sibling], another entry of this key, gained a
  /// stage: what this binding shows changes when it borrows from it or may
  /// borrow it now.
  void siblingChanged(_Entry sibling) {
    if (_borrowed == null && _ownStage.index >= AssetStage.firstFrame.index) {
      return;
    }
    final before = _borrowed;
    reborrow();
    if (identical(before, sibling) || identical(_borrowed, sibling)) {
      syncPlayback();
      signal();
    }
  }

  /// Borrows the best sibling stage while the entry's own, as this binding
  /// shows it, is below that stage and below its first frame; gives the
  /// sibling back otherwise.
  void reborrow() {
    final own = _ownStage;
    _Entry? next;
    // The sibling's stage as this binding would show it (a profile that does
    // not autoplay waits for the full asset there too) must beat its own.
    if (!isDetached && own.index < AssetStage.firstFrame.index) {
      if (_scope._siblingOf(entry, own) case final sibling?
          when _lentStageOf(sibling).index > own.index) {
        next = sibling;
      }
    }
    final previous = _borrowed;
    if (identical(next, previous)) return;
    _borrowed = next;
    if (next != null) _scope._borrow(next);
    if (previous != null) _scope._giveBack(previous);
  }

  // What this binding paints: its entry's paintable, or the borrowed one.
  AssetPaintable? get _shown => switch (_borrowed) {
    final sibling? => sibling.lent,
    null => entry.paintable,
  };

  // The paint that follows a tick is what steps the paintable, so a pass that
  // ended is seen on the tick after: here, the frame after the one that held.
  void _onTick() {
    if (!profile.loop && !_ended && (_shown?.isHolding ?? false)) {
      _ended = true;
      syncPlayback();
    }
    signal();
  }

  @override
  bool get animates => profile.animate || _replayed;

  @override
  AssetPlayback get playback {
    if (isDetached) return AssetPlayback.idle;
    if (_ended) return AssetPlayback.ended;
    return _registered ? AssetPlayback.playing : AssetPlayback.idle;
  }

  @override
  bool replay() {
    if (isDetached || !visible) return false;
    final paintable = entry.paintable;
    if (paintable == null ||
        !paintable.isAnimated ||
        _ownStage != entry.stage) {
      return false;
    }
    if (_ended) {
      _ended = false;
    } else if (animates) {
      return false;
    }
    _replayed = true;
    syncPlayback();
    signal();
    return true;
  }

  @override
  AssetReadiness get liveReadiness {
    if (_borrowed case final sibling?) {
      // Shown, not final: the entry's own decode is still to come.
      return AssetReadiness(_lentStageOf(sibling));
    }
    final stage = _ownStage;
    return AssetReadiness(
      stage,
      isFinal: entry.isFinal && stage == entry.stage,
    );
  }

  // A profile that does not autoplay shows its placeholder until the full
  // asset exists; a first-frame-only spec has nothing later to wait for.
  AssetStage _stageOf(_Entry of) =>
      of.stage == AssetStage.firstFrame &&
          !profile.autoplayFirstFrame &&
          of.spec.variant == AssetVariant.full
      ? AssetStage.placeholder
      : of.stage;

  // A sibling's stage as this binding shows what it lends: a playing
  // sibling lends a first frame.
  AssetStage _lentStageOf(_Entry sibling) {
    final stage = _stageOf(sibling);
    return stage.index > sibling.lentStage.index ? sibling.lentStage : stage;
  }

  // The entry's own stage as this binding paints it, borrowing aside.
  AssetStage get _ownStage => _stageOf(entry);

  @override
  AssetPaintable get livePaintable {
    if (_borrowed case _Entry(:final lent?)) return lent;
    final paintable = entry.paintable;
    if (paintable == null || _ownStage != entry.stage) {
      return _scope.placeholder;
    }
    return paintable;
  }

  // A surface that paints a stage above the stand-in opaque has nothing left
  // to fade over it, so it is released with that paint: surfaces that do not
  // fade never have to know about it.
  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    Color? tint,
    double opacity = 1,
    OutlineLook? outline,
  }) {
    super.paint(canvas, rect, tint: tint, opacity: opacity, outline: outline);
    if (opacity >= 1 &&
        _holdsStandIn &&
        _ownStage.index > entry.standInStage.index) {
      releaseStandIn();
    }
  }

  @override
  bool paintStandIn(
    Canvas canvas,
    Rect rect, {
    double contentOpacity = 0,
    OutlineLook? outline,
  }) {
    final standIn = entry.standIn;
    if (!_holdsStandIn || standIn == null || isDetached) return false;
    final opacity = _standInFadesOut ? 1 - contentOpacity.clamp(0.0, 1.0) : 1.0;
    standIn.paint(
      canvas,
      rect,
      AssetPaintContext(fit: profile.fit, opacity: opacity, outline: outline),
    );
    return true;
  }

  // Whether the kept stand-in fades out under what rises over it rather than
  // staying opaque: an outline has no pixels of the content's to hide behind,
  // and content that may be transparent would show any stand-in through.
  bool get _standInFadesOut {
    final descriptor = entry.descriptor;
    if (descriptor == null) return false;
    if (descriptor.kind == MediaKind.vectorAnimation) return true;
    return entry.standInStage == AssetStage.preview &&
        descriptor.preview is MediaPreview$Outline;
  }

  @override
  void releaseStandIn() {
    if (!_holdsStandIn) return;
    _holdsStandIn = false;
    if (--entry.standInHolders <= 0) entry.disposeStandIn();
  }

  @override
  Object? get lastError => entry.lastError;

  @override
  bool get isPlaying => _registered && !clock.isPaused;

  @override
  void retry() {
    if (isDetached) return;
    if (entry.attempt == null && !entry.isFinal) _scope._start(entry);
  }

  @override
  void onVisibleChanged() {
    entry.demand.refresh(entry);
    syncPlayback();
    entry.syncShown();
  }

  @override
  void onHeldChanged() => syncPlayback();

  /// Registers with or leaves the playback clock to match what the binding
  /// wants now.
  void syncPlayback() {
    entry.syncKeep();
    final wanted =
        !isDetached &&
        visible &&
        !holdsFrame &&
        animates &&
        !_ended &&
        (_shown?.isAnimated ?? false);
    if (wanted == _registered) return;
    _registered = wanted;
    if (wanted) {
      final shown = _shown;
      // A foreground surface plays its own pass from the first frame (a
      // borrowed sibling only lends a still, and never plays).
      if (profile.foreground &&
          _borrowed == null &&
          shown != null &&
          !identical(shown, _rewound)) {
        _rewound = shown;
        shown.rewind();
      } else {
        // A binding that starts to play wakes a playback another binding of
        // the entry left holding its rest frame; a running one is left
        // alone.
        shown?.restart();
      }
      clock.register(_target);
    } else {
      clock.unregister(_target);
    }
    entry.syncPlaying();
  }

  @override
  void releaseResources() {
    releaseStandIn();
    if (_borrowed case final sibling?) {
      _borrowed = null;
      _scope._giveBack(sibling);
    }
    if (_registered) {
      _registered = false;
      clock.unregister(_target);
      entry.syncPlaying();
    }
    _scope._detached(this);
  }
}

/// One hold of an entry's playback, released exactly once.
///
/// Returned by [AssetCacheScope.holdPlayback].
final class AssetPlaybackHold {
  AssetPlaybackHold._(this._onRelease);

  void Function()? _onRelease;

  /// Whether [release] has run.
  bool get isReleased => _onRelease == null;

  /// Gives the hold back: the entry plays again from its frame once no hold
  /// is left. Idempotent; after the scope's dispose it does nothing.
  void release() {
    final onRelease = _onRelease;
    _onRelease = null;
    onRelease?.call();
  }
}

/// One claim on the background of a scope, released exactly once.
///
/// Returned by [AssetCacheScope.holdBackground].
final class AssetBackgroundHold {
  AssetBackgroundHold._(this._onRelease);

  void Function()? _onRelease;

  /// Whether [release] has run.
  bool get isReleased => _onRelease == null;

  /// Gives the claim back: the background plays again from its frames once
  /// no claim is left. Idempotent; after the scope's dispose it does nothing.
  void release() {
    final onRelease = _onRelease;
    _onRelease = null;
    onRelease?.call();
  }
}

final class _PlaybackTarget implements PlaybackTarget {
  _PlaybackTarget(this.frameInterval, this._onTick);

  @override
  final Duration frameInterval;

  final VoidCallback _onTick;

  @override
  void tick(Duration now) => _onTick();
}
