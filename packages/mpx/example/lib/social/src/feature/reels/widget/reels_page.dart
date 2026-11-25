import 'package:control/control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:mpx_example/social/src/common/media/post_media_facts.dart';
import 'package:mpx_example/social/src/common/media/post_media_presets.dart';
import 'package:mpx_example/social/src/common/widget/state_views.dart';
import 'package:mpx_example/social/src/feature/initialization/dependencies.dart';
import 'package:mpx_example/social/src/feature/reels/widget/reel_page.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/timeline_controller.dart';
import 'package:mpx_example/social/src/feature/timeline/data/mastodon_client.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

/// Videos one at a time, with sound: a pager whose page that shows plays
/// aloud and whose neighbours wait warm, as `FeedPolicy.pager` says.
///
/// The videos are those of the closest `TimelineController`. While [active]
/// is false the pager is not built: a pager that is not shown would go on
/// playing its page, so it is let go, and comes back on the page it left.
class ReelsPage extends StatefulWidget {
  const ReelsPage({required this.active, super.key});

  /// Whether the reels are the tab shown.
  final bool active;

  @override
  State<ReelsPage> createState() => _ReelsPageState();
}

class _ReelsPageState extends State<ReelsPage> {
  // The page the reader was on, for the pager that is built again.
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final pool = Dependencies.of(context).players;
    if (pool == null) {
      return const MessageView(
        icon: LucideIcons.video_off,
        title: 'Reels need the platform player',
        hint: 'This build has no native player, so clips cannot play here.',
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: widget.active
          ? _Reels(
              pool: pool,
              initialPage: _page,
              onPageChanged: (page) => _page = page,
            )
          : const SizedBox.expand(),
    );
  }
}

/// One video of the reels and the post it belongs to.
typedef _Reel = ({Post post, PostMedia media});

class _Reels extends StatefulWidget {
  const _Reels({
    required this.pool,
    required this.initialPage,
    required this.onPageChanged,
  });

  final PlayerPool pool;
  final int initialPage;
  final ValueChanged<int> onPageChanged;

  @override
  State<_Reels> createState() => _ReelsState();
}

class _ReelsState extends State<_Reels> {
  /// How many pages from the end the next page of videos is asked for.
  static const int _prefetchAhead = 3;

  // A reel plays by itself whatever its size: the player streams it, and
  // the reader came to watch. The standard gate holds back a file above its
  // size limit until a tap, which on a surface with no button to tap is a
  // black page that never plays. Only a device with no network has nothing
  // to play. The reader's settings and the power saver stand, as in the
  // standard gate.
  static const FeedPolicy _policy = FeedPolicy.pager(autoplayGate: _gate);

  static FeedAutoplay _gate(
    FeedItem item,
    FeedConditions conditions,
    FeedPolicy policy,
  ) =>
      !policy.lite.allows(item, conditions) ||
          conditions.network == FeedNetwork.none
      ? FeedAutoplay.none
      : FeedAutoplay.full;

  TimelineController? _controller;

  // The posts the reader liked. Likes are the app's own: the signed-out API
  // has no way to send one.
  final ValueNotifier<Set<PostId>> _liked = ValueNotifier({});

  @override
  void dispose() {
    _liked.dispose();
    super.dispose();
  }

  void _toggleLike(PostId id) => _liked.value = _liked.value.contains(id)
      ? ({..._liked.value}..remove(id))
      : {..._liked.value, id};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= context.controllerOf<TimelineController>()..load();
  }

  static List<_Reel> _reelsOf(List<Post> posts) => [
    for (final post in posts)
      for (final media in post.media)
        if (media.kind == PostMediaKind.video) (post: post, media: media),
  ];

  void _onPage(int index, int count) {
    widget.onPageChanged(index);
    if (index >= count - _prefetchAhead) _controller?.loadMore();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    final dependencies = Dependencies.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final size = MediaQuery.sizeOf(context);
    return ValueListenableBuilder(
      valueListenable: controller.select((s) => s.data.posts),
      builder: (context, posts, _) {
        final reels = _reelsOf(posts);
        final state = controller.state;
        if (reels.isEmpty) {
          return state.isFailed
              ? MessageView(
                  icon: LucideIcons.cloud_off,
                  title: MastodonFailure.of(state.error).title,
                  hint: MastodonFailure.of(state.error).hint,
                  action: 'Try again',
                  onAction: controller.load,
                )
              : const Center(child: CircularProgressIndicator());
        }
        return FeedPagerView(
          pool: widget.pool,
          policy: _policy,
          itemCount: reels.length,
          initialIndex: widget.initialPage.clamp(0, reels.length - 1),
          itemOf: (index) => PostMediaFacts.feedItem(reels[index].media),
          conditions: dependencies.feedSignals,
          presetOf: (index, profile) => PostMediaPresets.of(
            reels[index].media,
            size: size,
            devicePixelRatio: dpr,
            profile: profile,
          ),
          onPageChanged: (index) => _onPage(index, reels.length),
          // The page draws its own clip, to fit each video as it needs.
          cellBuilder: (context, index, _) => ReelPage(
            post: reels[index].post,
            media: reels[index].media,
            liked: _liked,
            onToggleLike: _toggleLike,
          ),
        );
      },
    );
  }
}
