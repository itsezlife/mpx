import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/feed/feed_clip.dart';
import 'package:mpx_ui/src/feed/feed_items_known.dart';
import 'package:mpx_ui/src/gallery/gallery_keep_alive.dart';
import 'package:mpx_ui/src/gallery/gallery_page_transition.dart';
import 'package:mpx_ui/src/gallery/gallery_pager.dart';
import 'package:mpx_ui/src/gallery/gallery_pager_physics.dart';

/// Builds the page of [index] around its [media]: the player's picture, or
/// the poster while the page holds no player.
typedef FeedPagerCellBuilder =
    Widget Function(BuildContext context, int index, Widget media);

/// A pager where the page shown plays with sound and its neighbours keep
/// prepared players, as a pager-mode [FeedPolicy] says: a reels or stories
/// surface.
///
/// The assembled default of the feed's pieces: a pager-mode
/// [FeedController] over [pool] and a `GalleryPager` (the viewer's pager,
/// along [scrollDirection], with [physics]) whose pages are `FeedSlot`s
/// showing a [FeedClip]. The page that plays is the most visible one,
/// measured like any slot against the pager's window, so a host's own pager
/// plays the same way with those pieces. A swipe takes over the neighbour's
/// prepared player.
/// With [presetOf] the neighbours' bytes are preloaded to the policy's
/// stages through the asset cache scope ([scope], or the closest
/// `AssetCacheProvider`), and the poster is the item's first frame from the
/// cache.
class FeedPagerView extends StatefulWidget {
  /// Creates a pager of [itemCount] items.
  const FeedPagerView({
    required this.pool,
    required this.itemCount,
    required this.itemOf,
    super.key,
    this.policy = const FeedPolicy.pager(),
    this.conditions,
    this.initialIndex = 0,
    this.muted,
    this.scrollDirection = Axis.vertical,
    this.fit = BoxFit.contain,
    this.presetOf,
    this.posterBuilder,
    this.scope,
    this.cellBuilder,
    this.onPageChanged,
    this.status = MediaStatusMode.none,
    this.badge = false,
    this.physics = GalleryPagerPhysics.feed,
  });

  /// The paging rules: when a drag pages, release and settle.
  final GalleryPagerPhysics physics;

  /// The status control over each page's media ([FeedClip.status]).
  final MediaStatusMode status;

  /// Whether the media badge shows over each page ([FeedClip.badge]).
  final bool badge;

  /// The players.
  final PlayerPool pool;

  /// How many items the pager has.
  final int itemCount;

  /// The feed facts of an item.
  final FeedItem Function(int index) itemOf;

  /// The rules; pager mode.
  final FeedPolicy policy;

  /// The device's conditions the autoplay gate weighs, live (a
  /// `FeedSignals`); neutral when null.
  final ValueListenable<FeedConditions>? conditions;

  /// The page shown first.
  final int initialIndex;

  /// Whether the pager plays without sound; applies to every player it
  /// holds. Null leaves it to the policy's initial mute and the user's
  /// toggle on [FeedPagerViewState.pager].
  final bool? muted;

  /// The swipe axis.
  final Axis scrollDirection;

  /// How the picture fills a page.
  final BoxFit fit;

  /// The size and decode of an item's still and preloads; no preloads and
  /// no cached poster when null.
  final AssetPreset Function(int index, AssetProfile profile)? presetOf;

  /// What a page shows while it has no picture; the cached first frame
  /// (with [presetOf]) or nothing when null.
  final Widget Function(BuildContext context, int index)? posterBuilder;

  /// The cache the preloads and posters go through.
  final AssetCacheScope? scope;

  /// Builds a page around its media; the media alone when null.
  final FeedPagerCellBuilder? cellBuilder;

  /// Told the page shown when it changes.
  final ValueChanged<int>? onPageChanged;

  @override
  State<FeedPagerView> createState() => FeedPagerViewState();
}

/// The state of a [FeedPagerView]; [feed] is the controller it drives and
/// [pager] the pager that holds its leases.
class FeedPagerViewState extends State<FeedPagerView>
    with FeedItemsKnown<FeedPagerView> {
  late final GalleryPagerController _pages = GalleryPagerController(
    initialPage: widget.initialIndex,
  )..position.addListener(_moved);
  // The host's callbacks are read through the widget, so a parent that
  // rebuilds with new closures is followed without a new controller.
  late final FeedController _feed = FeedController(
    policy: widget.policy,
    pool: widget.pool,
    itemCount: widget.itemCount,
    itemOf: knownItemOf,
    presetOf: widget.presetOf == null
        ? null
        : (index, profile) => widget.presetOf!(index, profile),
    conditions: widget.conditions,
    initialIndex: widget.initialIndex,
    muted: widget.muted,
    onAdvance: _advance,
  )..inView.addListener(_pageChanged);

  /// The feed: per-page decisions and the page that plays.
  FeedController get feed => _feed;

  /// The pager: the page shown, the leases and the mute toggle.
  FeedPager get pager => _feed.pager!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _feed.scope = itemsScope;
  }

  @override
  void didUpdateWidget(FeedPagerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final muted = widget.muted;
    if (muted != null && muted != oldWidget.muted) pager.muted = muted;
    _feed
      ..itemCount = widget.itemCount
      ..scope = widget.scope ?? AssetCacheProvider.maybeOf(context);
  }

  @override
  void dispose() {
    _feed
      ..inView.removeListener(_pageChanged)
      ..dispose();
    _pages
      ..position.removeListener(_moved)
      ..dispose();
    super.dispose();
  }

  @override
  FeedItem hostItemOf(int index) => widget.itemOf(index);

  @override
  AssetCacheScope? get hostScope => widget.scope;

  void _pageChanged() {
    final index = _feed.inView.value;
    if (index != null) widget.onPageChanged?.call(index);
  }

  // The pages move by transforms, which lay nothing out: the feed measures
  // its slots again as the pager moves, as it does when a scrollable
  // scrolls.
  void _moved() => _feed.markNeedsMeasure();

  // An advance asked while a slide runs (the page that took over mid-slide
  // reporting its own state) is dropped: the slide lands first.
  void _advance(int next) {
    if (!mounted || _pages.isSettling) return;
    unawaited(
      _pages.animateTo(
        next,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FeedScope(
    controller: _feed,
    child: GalleryPager(
      controller: _pages,
      axis: widget.scrollDirection,
      count: widget.itemCount,
      physics: widget.physics,
      transition: const GalleryPageTransition.strip(),
      // The feed keeps its neighbours' players itself; their pages are
      // built while they show.
      keepAlive: const GalleryKeepAlive.none(),
      pageBuilder: (context, index) {
        final media = FeedClip(
          fit: widget.fit,
          poster: widget.posterBuilder?.call(context, index),
          showsBuffering: true,
          status: widget.status,
          badge: widget.badge,
        );
        return FeedSlot(
          index: index,
          item: knownItemOf(index),
          child: widget.cellBuilder?.call(context, index, media) ?? media,
        );
      },
    ),
  );
}
