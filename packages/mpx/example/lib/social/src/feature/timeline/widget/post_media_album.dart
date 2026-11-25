import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/common/media/post_media_facts.dart';
import 'package:mpx_example/social/src/common/media/post_media_presets.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/feature/initialization/dependencies.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/download_request.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/inline_sound.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/album_layout.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/aloud_picture.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/post_viewer.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

/// The pictures and clips of one post, laid out as an album.
///
/// Each tile is an item of the feed: a clip plays muted on it while it shows,
/// a tap opens the viewer on it, and a speaker switches the sound on for it.
/// [firstIndex] is the feed index of the post's first media; the others
/// follow it.
class PostMediaAlbum extends StatelessWidget {
  const PostMediaAlbum({
    required this.post,
    required this.firstIndex,
    required this.width,
    super.key,
  });

  final Post post;
  final int firstIndex;
  final double width;

  @override
  Widget build(BuildContext context) {
    final layout = AlbumLayout.of([
      for (final media in post.media) media.aspect,
    ], width);
    return SizedBox(
      width: layout.size.width,
      height: layout.size.height,
      child: Stack(
        children: [
          for (final i in List.generate(post.media.length, (i) => i))
            Positioned.fromRect(
              rect: layout.tiles[i],
              child: _AlbumCell(
                post: post,
                index: i,
                feedIndex: firstIndex + i,
                size: layout.tiles[i].size,
                radius: _radiusOf(layout.tiles[i], layout.size),
              ),
            ),
        ],
      ),
    );
  }

  // Only the corners of the album are round: where two tiles meet they are
  // square.
  static BorderRadius _radiusOf(Rect tile, Size album) {
    const round = Radius.circular(AppRadius.media);
    final left = tile.left <= 0.5;
    final top = tile.top <= 0.5;
    final right = (tile.right - album.width).abs() <= 0.5;
    final bottom = (tile.bottom - album.height).abs() <= 0.5;
    return BorderRadius.only(
      topLeft: left && top ? round : Radius.zero,
      topRight: right && top ? round : Radius.zero,
      bottomLeft: left && bottom ? round : Radius.zero,
      bottomRight: right && bottom ? round : Radius.zero,
    );
  }
}

/// One media of an album: the feed's slot, which knows the item's facts, and
/// the tile. The facts that change while it is on screen are the cell's: a
/// clip is on the device once the reader's download lands, and the feed
/// plays it by itself from then on (the policy plays what is on the device
/// whatever its size), which it learns only from a new item on the slot.
class _AlbumCell extends StatefulWidget {
  const _AlbumCell({
    required this.post,
    required this.index,
    required this.feedIndex,
    required this.size,
    required this.radius,
  });

  final Post post;
  final int index;
  final int feedIndex;
  final Size size;
  final BorderRadius radius;

  @override
  State<_AlbumCell> createState() => _AlbumCellState();
}

class _AlbumCellState extends State<_AlbumCell> {
  // The content's own binding, held while the clip is not on the device, to
  // hear its download.
  AssetBinding? _content;
  bool _onDevice = false;
  bool _asked = false;
  bool _started = false;
  final DownloadRequest _request = DownloadRequest();

  PostMedia get _media => widget.post.media[widget.index];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final media = _media;
    if (!media.plays) return;
    final dependencies = Dependencies.of(context);
    _onDevice = PostMediaFacts.isOnDevice(media, dependencies.stack.fetcher);
    if (_onDevice) return;
    // The binding the clip itself holds is the feed's: same profile, same
    // entry, so the download the reader starts is heard here.
    final profile =
        (FeedScope.maybeOf(context)?.policy ?? const FeedPolicy.list())
            .clipProfile();
    _content = AssetCacheProvider.of(context).attach(
      media.key,
      PostMediaPresets.of(
        media,
        size: widget.size,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        profile: profile,
      ).spec,
      profile,
    )..addListener(_onContent);
  }

  // After the notification: the binding is detached from here, and a
  // notifier is not disposed while it notifies.
  void _onContent() {
    final binding = _content;
    if (binding == null) return;
    final asked = _request.see(binding.transfer);
    if (asked != _asked) {
      // The reader asked for it, or took it back: the feed plays it as it
      // streams in, not when it is whole.
      scheduleMicrotask(() {
        if (mounted) setState(() => _asked = asked);
      });
    }
    scheduleMicrotask(_check);
  }

  void _check() {
    if (!mounted || _onDevice) return;
    final fetcher = Dependencies.of(context).stack.fetcher;
    if (!PostMediaFacts.isOnDevice(_media, fetcher)) return;
    _release();
    setState(() => _onDevice = true);
  }

  void _release() {
    _content
      ?..removeListener(_onContent)
      ..detach();
    _content = null;
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FeedSlot(
    index: widget.feedIndex,
    item: PostMediaFacts.feedItem(_media, onDevice: _onDevice || _asked),
    child: _AlbumTile(
      post: widget.post,
      index: widget.index,
      size: widget.size,
      radius: widget.radius,
    ),
  );
}

class _AlbumTile extends StatefulWidget {
  const _AlbumTile({
    required this.post,
    required this.index,
    required this.size,
    required this.radius,
  });

  final Post post;
  final int index;
  final Size size;
  final BorderRadius radius;

  @override
  State<_AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends State<_AlbumTile> {
  InlineSound? _sound;
  ValueListenable<FeedItemState>? _state;
  bool _tickers = true;

  PostMedia get _media => widget.post.media[widget.index];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sound ??= Dependencies.of(context).inlineSound;
    // A tab that hides the list (the reels, over it) stops its tickers: the
    // clip is not in view then, whatever its place in the scroll says, and
    // the sound goes to the tab that shows.
    final tickers = TickerMode.valuesOf(context).enabled;
    if (tickers != _tickers) {
      _tickers = tickers;
      if (_state != null) _onState();
    }
    // A clip tells the sound switch how much of it shows, so the one most in
    // view can take the sound.
    if (_media.kind == PostMediaKind.video) {
      _state?.removeListener(_onState);
      _state = FeedSlot.of(context).state..addListener(_onState);
    }
  }

  @override
  void dispose() {
    _state?.removeListener(_onState);
    if (_media.kind == PostMediaKind.video) _sound?.forget(_media.key);
    super.dispose();
  }

  void _onState() => _sound?.report(
    _media.key,
    _tickers ? _state!.value.fraction : 0,
    clipPosition: _clipPosition,
  );

  // Where the loop of this clip is: the sound starts from there, so it goes
  // on from the picture the reader is looking at.
  Duration? _clipPosition() {
    if (!mounted) return null;
    final media = _media;
    final profile =
        (FeedScope.maybeOf(context)?.policy ?? const FeedPolicy.list())
            .clipProfile();
    final spec = PostMediaPresets.of(
      media,
      size: widget.size,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      profile: profile,
    ).spec;
    return AssetCacheProvider.of(context).playbackPosition(media.key, spec);
  }

  // The reader asks to play a clip the feed's policy holds. A GIF plays where
  // it is; a video opens in the viewer, where it has its controls and sound.
  void _play(PostMedia media) {
    if (media.kind == PostMediaKind.gif) {
      final slot = FeedSlot.of(context);
      slot.controller.requestPlay(slot.index);
    } else {
      PostViewer.open(context, widget.post, widget.index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final media = _media;
    final clip = FeedClip(
      preset: (profile) => PostMediaPresets.of(
        media,
        size: widget.size,
        devicePixelRatio: dpr,
        profile: profile,
      ),
      status: const MediaStatusMode.control(),
      badge: true,
      onPlay: () => _play(media),
    );
    final sound = _sound!;
    final alt = media.alt;
    return GestureDetector(
      // The picture paints without taking hits: the whole tile does.
      behavior: HitTestBehavior.opaque,
      onTap: () => PostViewer.open(context, widget.post, widget.index),
      child: ClipRRect(
        borderRadius: widget.radius,
        child: ViewerOrigin(
          media: media.key,
          borderRadius: widget.radius,
          fit: BoxFit.cover,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: Theme.of(context).colors.mediaPlaceholder),
              ListenableBuilder(
                listenable: sound,
                builder: (context, _) {
                  final lease = sound.playing == media.key ? sound.lease : null;
                  // The picture the viewer opens from is the player's, not the
                  // controls over it.
                  return lease == null
                      ? clip
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            AssetPicture(
                              child: AloudPicture(lease: lease, clip: clip),
                            ),
                            // The clip lays its badge and its download control
                            // over itself; a player draws neither, so they go
                            // over it, as the feed lays them over a player.
                            ViewerOriginOverlay(
                              media: media.key,
                              child: AssetView(
                                content: media.key,
                                preset: PostMediaPresets.of(
                                  media,
                                  size: widget.size,
                                  devicePixelRatio: dpr,
                                  profile: const AssetProfile(),
                                ),
                                opacity: 0,
                                status: const MediaStatusMode.control(),
                              ),
                            ),
                            // The clip's badge counts its own loop; the
                            // player's time is the lease's.
                            Positioned(
                              left: AppSpacing.s,
                              top: AppSpacing.s,
                              child: ViewerOriginOverlay(
                                media: media.key,
                                child: _PlayerBadge(
                                  lease: lease,
                                  total: media.duration,
                                  width: widget.size.width,
                                ),
                              ),
                            ),
                          ],
                        );
                },
              ),
              // Marks over the picture fade while the viewer shows it, so none
              // of them rides the morph or stands beside the viewer's picture.
              if (media.kind == PostMediaKind.video && sound.isAvailable)
                Positioned(
                  right: AppSpacing.s,
                  bottom: AppSpacing.s,
                  child: ViewerOriginOverlay(
                    media: media.key,
                    child: _SoundButton(sound: sound, media: media.key),
                  ),
                ),
              if (alt != null && alt.isNotEmpty)
                Positioned(
                  left: AppSpacing.s,
                  bottom: AppSpacing.s,
                  child: ViewerOriginOverlay(
                    media: media.key,
                    child: _AltBadge(alt: alt),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The time left of a clip a player draws: its length less the player's
/// place, read as it plays.
class _PlayerBadge extends StatefulWidget {
  const _PlayerBadge({
    required this.lease,
    required this.total,
    required this.width,
  });

  final PlayerLease lease;
  final Duration? total;
  final double width;

  @override
  State<_PlayerBadge> createState() => _PlayerBadgeState();
}

class _PlayerBadgeState extends State<_PlayerBadge> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.lease.state.addListener(_onState);
    _onState();
  }

  @override
  void dispose() {
    widget.lease.state.removeListener(_onState);
    _timer?.cancel();
    super.dispose();
  }

  // The place is a read, not a stream: while the player plays it is read
  // a few times a second, the time being whole seconds.
  void _onState() {
    final playing = widget.lease.state.value.playing;
    if (playing && _timer == null) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => setState(() {}),
      );
    } else if (!playing) {
      _timer?.cancel();
      _timer = null;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.total ?? widget.lease.state.value.duration;
    if (total == null) return const SizedBox.shrink();
    final left = total - widget.lease.position;
    return MediaBadge(
      duration: left.isNegative ? Duration.zero : left,
      width: widget.width,
    );
  }
}

class _SoundButton extends StatelessWidget {
  const _SoundButton({required this.sound, required this.media});

  final InlineSound sound;
  final MediaKey media;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sound,
    builder: (context, _) {
      final on = sound.playing == media && sound.isSoundOn;
      return Material(
        color: Theme.of(context).colors.scrim,
        shape: const CircleBorder(),
        child: InkResponse(
          onTap: () => sound.toggle(media),
          radius: 24,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s),
            child: Icon(
              on ? LucideIcons.volume_2 : LucideIcons.volume_x,
              size: 18,
              color: Colors.white,
              semanticLabel: on ? 'Mute' : 'Turn the sound on',
            ),
          ),
        ),
      );
    },
  );
}

/// "ALT" over a picture whose author described it; a tap reads the
/// description.
class _AltBadge extends StatelessWidget {
  const _AltBadge({required this.alt});

  final String alt;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colors.scrim,
    borderRadius: BorderRadius.circular(4),
    child: InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => showModalBottomSheet<void>(
        useRootNavigator: false,
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.l,
              0,
              AppSpacing.l,
              AppSpacing.l,
            ),
            child: SelectableText(alt),
          ),
        ),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          'ALT',
          style: TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );
}
