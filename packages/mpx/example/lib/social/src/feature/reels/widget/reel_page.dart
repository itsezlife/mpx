import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:mpx_example/social/src/common/media/post_media_presets.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/common/util/count_format.dart';
import 'package:mpx_example/social/src/common/util/time_ago_extension.dart';
import 'package:mpx_example/social/src/common/widget/avatar.dart';
import 'package:mpx_example/social/src/feature/reels/widget/reel_hearts.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// One reel, as a reels surface draws it: the video filling the page, and over
/// it
///
/// - a tap mutes or unmutes, a double tap likes (a heart bursts where it
///   landed), a press holds the video still until the finger leaves;
/// - a seek bar along the bottom edge, dragged to scrub;
/// - the author and the caption at the bottom left, the actions at the right;
/// - the sound switch at the top.
///
/// It sits in a `FeedSlot` of a pager `FeedController`, and plays through that
/// pager's lease; nothing here owns a player.
class ReelPage extends StatefulWidget {
  const ReelPage({
    required this.post,
    required this.media,
    required this.liked,
    required this.onToggleLike,
    super.key,
  });

  final Post post;
  final PostMedia media;

  /// The height of the seek bar's touch target, along the bottom edge.
  static const double barHeight = 32;

  /// The seek bar's look: a hairline that thickens, with a thumb, under a
  /// finger.
  static const ViewerSeekBarStyle seekStyle = ViewerSeekBarStyle(
    track: 2,
    trackWhileDragging: 6,
    thumb: 0,
    thumbWhileDragging: 8,
    alignment: 1,
    faintOpacity: 0.25,
  );

  /// The posts the reader liked.
  final ValueListenable<Set<PostId>> liked;
  final ValueChanged<PostId> onToggleLike;

  @override
  State<ReelPage> createState() => _ReelPageState();
}

class _ReelPageState extends State<ReelPage> with TickerProviderStateMixin {
  // The pager tells its listeners after every plan it applies, which is
  // every measure of the page: a widget listening to the pager itself would
  // rebuild on each, lay the page out again, and be measured again, a loop
  // that calls play and pause on the players every frame. This page listens
  // to the two things it draws, and each changes only when it is changed.
  final ValueNotifier<bool> _muted = ValueNotifier(true);
  // The playhead and the seek of the page that plays: made for its lease,
  // and null while the page waits warm.
  final ValueNotifier<ViewerSeekController?> _seek = ValueNotifier(null);
  final ValueNotifier<bool> _held = ValueNotifier(false);
  final ValueNotifier<bool> _scrubbing = ValueNotifier(false);
  final GlobalKey<ReelHeartsState> _hearts = GlobalKey();
  final GlobalKey _surface = GlobalKey();

  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  FeedPager? _pager;
  ValueListenable<FeedItemState>? _slot;

  // The holds on the pager this page took: a press and a drag can overlap,
  // and the pager is released when the last of them ends.
  int _holds = 0;
  bool _pressing = false;
  Offset _doubleTapAt = Offset.zero;
  bool _captionOpen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pager = FeedScope.maybeOf(context)!.pager!;
    if (!identical(pager, _pager)) {
      _pager?.removeListener(_onPager);
      _pager = pager..addListener(_onPager);
      _muted.value = pager.muted;
    }
    final slot = FeedSlot.of(context).state;
    if (!identical(slot, _slot)) {
      _slot?.removeListener(_onSlot);
      _slot = slot..addListener(_onSlot);
      _onSlot();
    }
  }

  void _onPager() => _muted.value = _pager!.muted;

  // The lease is the page's while it plays: the neighbours hold leases too,
  // and have no seek bar.
  void _onSlot() {
    final state = _slot!.value;
    final lease = state.inView ? state.lease : null;
    if (identical(lease, _seek.value?.lease)) return;
    _dropSeek();
    if (lease == null) return;
    _seek.value = ViewerSeekController(
      vsync: this,
      lease: lease,
      knownDuration: widget.media.duration,
    )..addListener(_onSeek);
  }

  void _dropSeek() {
    _seek.value
      ?..removeListener(_onSeek)
      ..dispose();
    _seek.value = null;
    if (_scrubbing.value) _scrubHold(held: false);
  }

  // A finger on the bar holds the video still and fades the page's words;
  // the video goes to the preview when the finger leaves.
  void _onSeek() {
    final dragging = _seek.value?.isDragging ?? false;
    if (dragging != _scrubbing.value) _scrubHold(held: dragging);
  }

  @override
  void dispose() {
    _slot?.removeListener(_onSlot);
    _pager?.removeListener(_onPager);
    // A page swiped away mid-press must not leave the pager held.
    _dropSeek();
    if (_holds > 0) _pager?.held = false;
    _flash.dispose();
    _muted.dispose();
    _seek.dispose();
    _held.dispose();
    _scrubbing.dispose();
    super.dispose();
  }

  // --- Holding the pager -------------------------------------------------

  void _hold({required bool held}) {
    _holds = (_holds + (held ? 1 : -1)).clamp(0, 2);
    _pager?.held = _holds > 0;
    _held.value = _holds > 0;
  }

  void _scrubHold({required bool held}) {
    _scrubbing.value = held;
    _hold(held: held);
  }

  // --- Gestures -------------------------------------------------------------

  void _toggleMute() {
    final pager = _pager!;
    pager.muted = !pager.muted;
    _flash.forward(from: 0);
  }

  void _like() {
    _hearts.currentState?.burst(_doubleTapAt);
    if (!widget.liked.value.contains(widget.post.id)) {
      widget.onToggleLike(widget.post.id);
    }
  }

  void _pressStart() {
    if (_pressing) return;
    _pressing = true;
    _hold(held: true);
  }

  void _pressEnd() {
    if (!_pressing) return;
    _pressing = false;
    _hold(held: false);
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  // A portrait or square video fills the page; a wide one is shown whole, on
  // black, as a cut one would lose most of its picture.
  BoxFit get _fit => widget.media.aspect <= 1.1 ? BoxFit.cover : BoxFit.contain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = widget.media;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final size = MediaQuery.sizeOf(context);
    final clip = FeedClip(
      fit: _fit,
      // The page has its own controls: the stack's play and download button
      // would flash over a video that is already on its way. A video that
      // waits for its bytes shows the buffering spinner, which is all a
      // reel says about loading.
      showsBuffering: true,
      preset: (profile) => PostMediaPresets.of(
        media,
        size: size,
        devicePixelRatio: dpr,
        profile: profile,
      ),
    );
    return Stack(
      key: _surface,
      fit: StackFit.expand,
      children: [
        clip,
        const _Shade(),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleMute,
          onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
          onDoubleTap: _like,
          onLongPressStart: (_) => _pressStart(),
          onLongPressEnd: (_) => _pressEnd(),
          onLongPressCancel: _pressEnd,
        ),
        // What the page says while the video is held or dragged fades, so the
        // picture is clear.
        ValueListenableBuilder(
          valueListenable: _held,
          builder: (context, held, _) => AnimatedOpacity(
            opacity: held ? 0 : 1,
            duration: const Duration(milliseconds: 160),
            child: IgnorePointer(
              ignoring: held,
              child: _Chrome(
                post: widget.post,
                muted: _muted,
                liked: widget.liked,
                captionOpen: _captionOpen,
                onCaption: () => setState(() => _captionOpen = !_captionOpen),
                onMute: _toggleMute,
                onLike: () => widget.onToggleLike(widget.post.id),
                onComments: () => _open(widget.post.url),
                onShare: () => SharePlus.instance.share(
                  ShareParams(uri: Uri.parse(widget.post.url)),
                ),
              ),
            ),
          ),
        ),
        // The tap's answer: the sound's new state, flashing at the centre.
        IgnorePointer(
          child: Center(
            child: ValueListenableBuilder(
              valueListenable: _muted,
              builder: (context, muted, _) => AnimatedBuilder(
                animation: _flash,
                builder: (context, _) => Opacity(
                  opacity: _flashOpacity(_flash.value),
                  child: _RoundIcon(
                    icon: muted ? LucideIcons.volume_x : LucideIcons.volume_2,
                    size: 36,
                    scrim: theme.colors.scrim,
                  ),
                ),
              ),
            ),
          ),
        ),
        // A video held by a press says so.
        ValueListenableBuilder(
          valueListenable: _held,
          builder: (context, held, _) => IgnorePointer(
            child: AnimatedOpacity(
              opacity: held && !_scrubbing.value ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: Center(
                child: _RoundIcon(
                  icon: LucideIcons.pause,
                  size: 36,
                  scrim: theme.colors.scrim,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ValueListenableBuilder(
            valueListenable: _seek,
            builder: (context, seek, _) => seek == null
                ? const SizedBox(height: ReelPage.barHeight)
                : Stack(
                    // The time stands above the bar, outside its own box.
                    clipBehavior: Clip.none,
                    children: [
                      ViewerSeekBar(
                        controller: seek,
                        foreground: Colors.white,
                        style: ReelPage.seekStyle,
                        height: ReelPage.barHeight,
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: ReelPage.barHeight + 24,
                        child: _ScrubTime(seek: seek),
                      ),
                    ],
                  ),
          ),
        ),
        ReelHearts(key: _hearts),
      ],
    );
  }

  // In at once, held a moment, then out.
  static double _flashOpacity(double t) => switch (t) {
    <= 0 => 0,
    < 0.15 => t / 0.15,
    < 0.55 => 1,
    _ => 1 - (t - 0.55) / 0.45,
  };
}

/// The top and the bottom of the page darkened, so what is written over the
/// video reads on any picture.
class _Shade extends StatelessWidget {
  const _Shade();

  @override
  Widget build(BuildContext context) => const IgnorePointer(
    child: Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: 140,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            height: 300,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xCC000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _Chrome extends StatelessWidget {
  const _Chrome({
    required this.post,
    required this.muted,
    required this.liked,
    required this.captionOpen,
    required this.onCaption,
    required this.onMute,
    required this.onLike,
    required this.onComments,
    required this.onShare,
  });

  final Post post;
  final ValueListenable<bool> muted;
  final ValueListenable<Set<PostId>> liked;
  final bool captionOpen;
  final VoidCallback onCaption;
  final VoidCallback onMute;
  final VoidCallback onLike;
  final VoidCallback onComments;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    const onVideo = Colors.white;
    final caption = post.text.plain;
    return SafeArea(
      bottom: false,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: AppSpacing.s,
            left: AppSpacing.l,
            right: AppSpacing.s,
            child: Row(
              children: [
                Text(
                  'Reels',
                  style: textTheme.titleLarge?.copyWith(
                    color: onVideo,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                ValueListenableBuilder(
                  valueListenable: muted,
                  builder: (context, muted, _) => IconButton(
                    tooltip: muted ? 'Turn the sound on' : 'Mute',
                    color: onVideo,
                    icon: Icon(
                      muted ? LucideIcons.volume_x : LucideIcons.volume_2,
                    ),
                    onPressed: onMute,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: AppSpacing.l,
            right: 84,
            bottom: ReelPage.barHeight + AppSpacing.m,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Avatar(
                      name: post.author.displayName,
                      picture: post.author.avatar,
                      size: 36,
                    ),
                    const SizedBox(width: AppSpacing.s),
                    Flexible(
                      child: Text(
                        post.author.displayName,
                        style: textTheme.titleSmall?.copyWith(color: onVideo),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s),
                    Text(
                      post.createdAt.timeAgoShort(),
                      style: textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
                if (caption.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.s),
                  GestureDetector(
                    onTap: onCaption,
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 160),
                      alignment: Alignment.topLeft,
                      child: Text(
                        caption,
                        style: textTheme.bodyMedium?.copyWith(color: onVideo),
                        maxLines: captionOpen ? 12 : 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            right: AppSpacing.s,
            bottom: ReelPage.barHeight + AppSpacing.m,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder(
                  valueListenable: liked,
                  builder: (context, liked, _) {
                    final isLiked = liked.contains(post.id);
                    return _RailButton(
                      label: (post.likes + (isLiked ? 1 : 0)).compact,
                      tooltip: isLiked ? 'Unlike' : 'Like',
                      onPressed: onLike,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        transitionBuilder: (child, animation) =>
                            ScaleTransition(scale: animation, child: child),
                        child: isLiked
                            ? FilledHeart(
                                key: const ValueKey('liked'),
                                size: 28,
                                color: theme.colors.like,
                              )
                            : const Icon(
                                LucideIcons.heart,
                                key: ValueKey('not liked'),
                                size: 28,
                                color: onVideo,
                              ),
                      ),
                    );
                  },
                ),
                _RailButton(
                  label: post.replies.compact,
                  tooltip: 'Replies',
                  onPressed: onComments,
                  child: const Icon(
                    LucideIcons.message_circle,
                    size: 28,
                    color: onVideo,
                  ),
                ),
                _RailButton(
                  label: post.boosts.compact,
                  tooltip: 'Boosts',
                  onPressed: onComments,
                  child: const Icon(
                    LucideIcons.repeat_2,
                    size: 28,
                    color: onVideo,
                  ),
                ),
                _RailButton(
                  label: '',
                  tooltip: 'Share',
                  onPressed: onShare,
                  child: const Icon(
                    LucideIcons.share_2,
                    size: 28,
                    color: onVideo,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.label,
    required this.tooltip,
    required this.onPressed,
    required this.child,
  });

  final String label;
  final String tooltip;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.m),
    child: Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: 56,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              child,
              if (label.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                    shadows: const [Shadow(blurRadius: 4)],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({
    required this.icon,
    required this.size,
    required this.scrim,
  });

  final IconData icon;
  final double size;
  final Color scrim;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(shape: BoxShape.circle, color: scrim),
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.l),
      child: Icon(icon, size: size, color: Colors.white),
    ),
  );
}

/// Where a finger on the seek bar would put the video, and how long it is,
/// at the middle of the page: seen only while the finger is down.
class _ScrubTime extends StatelessWidget {
  const _ScrubTime({required this.seek});

  final ViewerSeekController seek;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ListenableBuilder(
      listenable: seek,
      builder: (context, _) => AnimatedOpacity(
        opacity: seek.isDragging ? 1 : 0,
        duration: const Duration(milliseconds: 120),
        child: Center(
          child: Text(
            '${seek.shown.clock} / ${seek.duration.clock}',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              shadows: const [Shadow(blurRadius: 6)],
            ),
          ),
        ),
      ),
    ),
  );
}
