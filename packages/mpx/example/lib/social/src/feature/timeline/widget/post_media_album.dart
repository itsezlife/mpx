import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/common/media/post_media_facts.dart';
import 'package:mpx_example/social/src/common/media/post_media_presets.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/feature/initialization/dependencies.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/inline_sound.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/album_layout.dart';
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
          for (final (i, media) in post.media.indexed)
            Positioned.fromRect(
              rect: layout.tiles[i],
              child: FeedSlot(
                index: firstIndex + i,
                item: PostMediaFacts.feedItem(media),
                child: _AlbumTile(
                  post: post,
                  index: i,
                  size: layout.tiles[i].size,
                  radius: _radiusOf(layout.tiles[i], layout.size),
                ),
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

  PostMedia get _media => widget.post.media[widget.index];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sound ??= Dependencies.of(context).inlineSound;
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

  void _onState() => _sound?.report(_media.key, _state!.value.fraction);

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
                  return lease == null
                      ? clip
                      : PlayerView(
                          lease: lease,
                          fit: BoxFit.cover,
                          standIn: clip,
                        );
                },
              ),
              if (media.kind == PostMediaKind.video && sound.isAvailable)
                Positioned(
                  right: AppSpacing.s,
                  bottom: AppSpacing.s,
                  child: _SoundButton(sound: sound, media: media.key),
                ),
              if (alt != null && alt.isNotEmpty)
                Positioned(
                  left: AppSpacing.s,
                  bottom: AppSpacing.s,
                  child: _AltBadge(alt: alt),
                ),
            ],
          ),
        ),
      ),
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
      final on = sound.playing == media;
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
