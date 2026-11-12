import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';

/// Builds the page of [index] around its [media]: the player's picture, or
/// the poster while the page holds no player.
typedef FeedPagerCellBuilder =
    Widget Function(BuildContext context, int index, Widget media);

/// A pager where the page shown plays with sound and its neighbours keep
/// prepared players, as a pager-mode [FeedPolicy] says: a reels or stories
/// surface.
///
/// A [FeedPager] over [pool] decides what plays and what is warm; a swipe
/// takes over the neighbour's prepared player. Each page shows its player
/// through a `PlayerView`, with the page's poster as the stand-in until the
/// first frame. With [presetOf] the neighbours' bytes are preloaded to the
/// policy's stages through the asset cache scope ([scope], or the closest
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
    this.muted = false,
    this.scrollDirection = Axis.vertical,
    this.fit = BoxFit.contain,
    this.presetOf,
    this.posterBuilder,
    this.scope,
    this.cellBuilder,
    this.onPageChanged,
  });

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
  /// holds.
  final bool muted;

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

/// The state of a [FeedPagerView]; [pager] is the pager it drives.
class FeedPagerViewState extends State<FeedPagerView> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late final FeedPager _pager = FeedPager(
    pool: widget.pool,
    itemCount: widget.itemCount,
    itemOf: widget.itemOf,
    policy: widget.policy,
    conditions: widget.conditions,
    initialIndex: widget.initialIndex,
    muted: widget.muted,
    onAdvance: _advance,
  )..addListener(_onPager);
  final Map<int, AssetPreload> _preloads = {};
  AssetCacheScope? _scope;

  /// The pager: the page shown, the leases and the mute toggle.
  FeedPager get pager => _pager;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = widget.scope ?? AssetCacheProvider.maybeOf(context);
    if (!identical(scope, _scope)) {
      _cancelPreloads();
      _scope = scope;
      _applyPreloads();
    }
  }

  @override
  void didUpdateWidget(FeedPagerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pager.muted = widget.muted;
  }

  @override
  void dispose() {
    _cancelPreloads();
    _pager
      ..removeListener(_onPager)
      ..dispose();
    _pages.dispose();
    super.dispose();
  }

  void _onPager() {
    _applyPreloads();
    if (mounted) setState(() {});
  }

  void _advance(int next) {
    if (!mounted || !_pages.hasClients) return;
    _pages.animateToPage(
      next,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _cancelPreloads() {
    for (final preload in _preloads.values) {
      preload.cancel();
    }
    _preloads.clear();
  }

  void _applyPreloads() {
    final scope = _scope;
    final presetOf = widget.presetOf;
    if (scope == null || presetOf == null) return;
    final plan = _pager.plan;
    for (final index in _preloads.keys.toList()) {
      final wanted = plan.preloads[index];
      final current = _preloads[index]!;
      final drop =
          index == plan.active ||
          (wanted == null && widget.policy.cancelOnLeave) ||
          (wanted != null && wanted != current.stage);
      if (drop) _preloads.remove(index)!.cancel();
    }
    for (final MapEntry(key: index, value: stage) in plan.preloads.entries) {
      if (_preloads.containsKey(index)) continue;
      _preloads[index] = scope.preload(
        widget.itemOf(index).key,
        presetOf(index, const AssetProfile()).spec,
        stage: stage,
        distance: plan.distances[index] ?? 0,
      );
    }
  }

  @override
  Widget build(BuildContext context) => PageView.builder(
    controller: _pages,
    scrollDirection: widget.scrollDirection,
    itemCount: widget.itemCount,
    onPageChanged: (index) {
      _pager.show(index);
      widget.onPageChanged?.call(index);
    },
    itemBuilder: (context, index) {
      final lease = _pager.leaseOf(index);
      final poster = _poster(context, index);
      final media = lease == null
          ? poster
          : PlayerView(lease: lease, fit: widget.fit, standIn: poster);
      return widget.cellBuilder?.call(context, index, media) ?? media;
    },
  );

  Widget _poster(BuildContext context, int index) {
    final custom = widget.posterBuilder;
    if (custom != null) return custom(context, index);
    final presetOf = widget.presetOf;
    if (presetOf == null || _scope == null) return const SizedBox.expand();
    return ContentView(
      content: widget.itemOf(index).key,
      preset: presetOf(index, const AssetProfile()),
      scope: _scope,
    );
  }
}
