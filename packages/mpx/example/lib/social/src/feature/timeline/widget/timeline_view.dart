import 'dart:math' as math;

import 'package:control/control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/common/media/post_media_facts.dart';
import 'package:mpx_example/social/src/common/media/post_media_presets.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/common/widget/state_views.dart';
import 'package:mpx_example/social/src/feature/initialization/dependencies.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/post_selection.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/timeline_controller.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/timeline_state.dart';
import 'package:mpx_example/social/src/feature/timeline/data/mastodon_client.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/album_layout.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/post_card.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/post_selection_scope.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

enum _Root { loading, failed, empty, content }

/// The timeline of the closest `TimelineController`: its first read, an
/// error, nothing, or the posts. It reads its controller's first page when it
/// is first built.
class TimelineView extends StatefulWidget {
  const TimelineView({super.key});

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView>
    with AutomaticKeepAliveClientMixin {
  TimelineController? _controller;

  // A tab keeps its scroll position and its posts while another shows.
  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= context.controllerOf<TimelineController>()..load();
  }

  static _Root _rootOf(TimelineState state) => switch (state) {
    _ when state.data.posts.isNotEmpty => _Root.content,
    TimelineState$Failed() => _Root.failed,
    _ when state.data.loaded => _Root.empty,
    _ => _Root.loading,
  };

  void _tellRefreshFailed(
    BuildContext context,
    TimelineController controller,
    TimelineState previous,
    TimelineState current,
  ) {
    if (current is! TimelineState$Failed ||
        current.data.operation != TimelineOperation.refresh) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(MastodonFailure.of(current.error).title)),
      );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final controller = _controller!;
    return StateConsumer(
      controller: controller,
      listener: _tellRefreshFailed,
      child: ValueListenableBuilder(
        valueListenable: controller.select(_rootOf),
        builder: (context, root, _) => switch (root) {
          _Root.loading => const TimelineSkeleton(),
          _Root.failed => MessageView(
            icon: LucideIcons.cloud_off,
            title: MastodonFailure.of(controller.state.error).title,
            hint: MastodonFailure.of(controller.state.error).hint,
            action: 'Try again',
            onAction: controller.load,
          ),
          _Root.empty => MessageView(
            icon: LucideIcons.images,
            title: 'Nothing here yet',
            hint: 'No posts matched this topic. Pull to read again.',
            action: 'Refresh',
            onAction: controller.refresh,
          ),
          _Root.content => _PostList(controller: controller),
        },
      ),
    );
  }
}

/// The posts, each media of them an item of a list-mode feed: every clip
/// that shows plays muted and loops, and the feed preloads ahead of the
/// scroll.
class _PostList extends StatefulWidget {
  const _PostList({required this.controller});

  final TimelineController controller;

  @override
  State<_PostList> createState() => _PostListState();
}

class _PostListState extends State<_PostList> {
  /// How far from the end the next page is asked for, in logical pixels.
  static const double _prefetchExtent = 1800;

  late FeedController _feed;
  late int _generation;
  final Set<PostId> _revealed = {};
  final PostSelection _selection = PostSelection();

  // Set by the layout: the album's width, which the presets are sized by
  // before any tile exists.
  double _mediaWidth = 360;
  double _devicePixelRatio = 1;

  TimelineStateEntity get _data => widget.controller.state.data;

  @override
  void initState() {
    super.initState();
    _generation = _data.generation;
    _feed = _createFeed();
    _syncSelection();
    widget.controller.addListener(_onTimeline);
  }

  FeedController _createFeed() => FeedController(
    policy: const FeedPolicy.list(),
    itemCount: _data.mediaCount,
    itemOf: _itemOf,
    presetOf: _presetOf,
    conditions: Dependencies.of(context).feedSignals,
  );

  FeedItem _itemOf(int index) {
    final (post, media) = _data.mediaAt(index);
    return PostMediaFacts.feedItem(_data.posts[post].media[media]);
  }

  AssetPreset _presetOf(int index, AssetProfile profile) {
    final (postIndex, mediaIndex) = _data.mediaAt(index);
    final post = _data.posts[postIndex];
    final layout = AlbumLayout.of([
      for (final media in post.media) media.aspect,
    ], _mediaWidth);
    return PostMediaPresets.of(
      post.media[mediaIndex],
      size: layout.tiles[mediaIndex].size,
      devicePixelRatio: _devicePixelRatio,
      profile: profile,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    _feed.scope = AssetCacheProvider.of(context);
  }

  void _onTimeline() {
    final data = _data;
    if (data.generation != _generation) {
      // The list was replaced, not extended: the feed numbers its items
      // from the start again.
      _generation = data.generation;
      _revealed.clear();
      _selection.reset();
      final old = _feed;
      setState(() => _feed = _createFeed()..scope = old.scope);
      old.dispose();
    } else if (data.mediaCount != _feed.itemCount) {
      _feed.itemCount = data.mediaCount;
    }
    _syncSelection();
  }

  // The selection reads the texts of the posts the reader is shown: not
  // those a content warning still covers.
  void _syncSelection() => _selection.sync(
    _data.posts,
    shows: (post) => !post.covered || _revealed.contains(post.id),
  );

  @override
  void dispose() {
    widget.controller.removeListener(_onTimeline);
    _selection.dispose();
    _feed.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.extentAfter < _prefetchExtent) {
      widget.controller.loadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => FeedScope(
    controller: _feed,
    child: ViewerOriginScope(
      child: RefreshIndicator(
        onRefresh: widget.controller.refresh,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: ValueListenableBuilder(
            valueListenable: widget.controller.select((s) => s.data),
            builder: (context, data, _) => LayoutBuilder(
              builder: (context, constraints) {
                _mediaWidth =
                    math.min(constraints.maxWidth, AppLayout.feedColumnWidth) -
                    AppSpacing.l * 2;
                return PostSelectionScope(
                  selection: _selection,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: data.posts.length + 1,
                    itemBuilder: (context, index) => Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: AppLayout.feedColumnWidth,
                        ),
                        child: index == data.posts.length
                            ? _Footer(controller: widget.controller)
                            : _card(data, index),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  Widget _card(TimelineStateEntity data, int index) {
    final post = data.posts[index];
    return PostCard(
      key: ValueKey(post.id),
      post: post,
      markdown: _selection.markdownOf(post),
      firstIndex: data.feedIndexOf(index, 0),
      mediaWidth: _mediaWidth,
      revealed: _revealed.contains(post.id),
      onReveal: () {
        setState(() => _revealed.add(post.id));
        _syncSelection();
      },
    );
  }
}

/// What ends the list: the next page on its way, a failed one to read again,
/// or the end.
class _Footer extends StatelessWidget {
  const _Footer({required this.controller});

  final TimelineController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller.select(
      (s) => (
        loading: s.isProcessing && s.data.operation == TimelineOperation.more,
        failed: s.isFailed && s.data.operation == TimelineOperation.more,
        exhausted: s.data.exhausted,
      ),
      (prev, next) => prev != next,
    ),
    builder: (context, slice, _) {
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Center(
          child: switch (slice) {
            (loading: true, failed: _, exhausted: _) =>
              const CircularProgressIndicator(),
            (loading: _, failed: true, exhausted: _) => TextButton(
              onPressed: controller.loadMore,
              child: const Text('Could not load more. Try again'),
            ),
            (loading: _, failed: _, exhausted: true) => Text(
              'You are all caught up',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            _ => const SizedBox(height: 24),
          },
        ),
      );
    },
  );
}
