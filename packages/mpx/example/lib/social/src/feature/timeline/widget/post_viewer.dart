import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/gallery.dart';
import 'package:mpx_example/social/src/common/media/post_media_facts.dart';
import 'package:mpx_example/social/src/common/media/post_media_presets.dart';
import 'package:mpx_example/social/src/common/util/time_ago_extension.dart';
import 'package:mpx_example/social/src/feature/initialization/dependencies.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a post's media in the fullscreen viewer: its pictures and clips as
/// one gallery, from the one the reader tapped, with the author, the
/// description, and share.
abstract final class PostViewer {
  /// Shows [post]'s [index]th media over [context]'s surface, flying from the
  /// tile that is its `ViewerOrigin`. Completes when the viewer closes.
  static Future<void> open(BuildContext context, Post post, int index) async {
    final dependencies = Dependencies.of(context);
    final gallery = ListGallery([
      for (final media in post.media) PostMediaFacts.galleryItem(media),
    ]);
    // Where the tapped clip stands: its player's place when it plays aloud,
    // read before the suspend lets that player go.
    final aloudAt = dependencies.inlineSound.positionOf(post.media[index].key);
    // The tile draws the clip's player while it plays aloud and its loop
    // once the player lets go: the loop goes to the player's place first,
    // showing the picture the tile shows, so the tile does not change frame
    // between the tap and the viewer's first one.
    if (aloudAt != null) {
      AssetCacheProvider.of(context).seekPlayback(
        post.media[index].key,
        PostMediaPresets.of(
          post.media[index],
          size: Size.zero,
          devicePixelRatio: 1,
          profile: const AssetProfile(),
        ).spec,
        aloudAt,
        picture: ViewerOriginScope.maybeOf(
          context,
        )?.bridgeFor(gallery).frameOf(index),
      );
    }
    // The viewer plays a clip's own sound: nothing in the list plays aloud
    // under it.
    dependencies.inlineSound.suspend();
    // The tile that played aloud lets go of its player view in the next
    // frame. The pool pauses a sound owner whose last view goes with no other
    // view attached, so a viewer that starts the player in that same frame
    // would find it paused: it opens once the tile has let go.
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted) {
      gallery.dispose();
      dependencies.inlineSound.resume();
      return;
    }
    // A muted clip's loop is the picture the reader looks at: the player
    // goes on from there, not from the beginning or from where it was left.
    final rules = ViewerPolicyScope.resolve(context);
    try {
      await MediaViewer.show(
        context,
        source: gallery,
        initialIndex: index,
        players: dependencies.players,
        policy: rules.copyWith(
          video: rules.video.copyWith(start: ViewerVideoStart.origin),
        ),
        videoStartOf: (at, item) => at == index ? aloudAt : null,
        chrome: ViewerChrome(
          title: (context, index, item) => Text(post.author.displayName),
          subtitle: (context, index, item) => Text(post.createdAt.timeAgo()),
          caption: (context, index, item) {
            final alt = post.media[index].alt;
            final text = alt != null && alt.isNotEmpty ? alt : post.text.plain;
            // Whole: the viewer's caption sheet cuts it at its first height and
            // a drag grows and scrolls it.
            return text.isEmpty ? null : Text(text);
          },
          thumbnails: post.media.length > 1,
          openFile: cachedFiles(dependencies.stack),
          actions: (index, item) => [
            ViewerAction(
              label: 'Share',
              icon: const Icon(LucideIcons.share_2),
              inBar: true,
              onSelected: (request) async {
                final file = await request.file();
                if (file == null) return;
                await SharePlus.instance.share(
                  ShareParams(
                    files: [XFile(file.path)],
                    fileNameOverrides: [
                      _nameOf(dependencies, post.media[index]),
                    ],
                  ),
                );
              },
            ),
            ViewerAction(
              label: 'Open on the web',
              onSelected: (_) async {
                final uri = Uri.tryParse(post.url);
                if (uri != null) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
          ],
        ),
      );
    } finally {
      gallery.dispose();
      dependencies.inlineSound.resume();
    }
  }

  // The cache stores bytes without a file name: the share sheet needs one
  // with an extension the receiver knows.
  static String _nameOf(Dependencies dependencies, PostMedia media) {
    final path = dependencies.origins.of(media.key)?.content.path ?? '';
    final dot = path.lastIndexOf('.');
    final extension = dot < 0 ? '' : path.substring(dot);
    return 'post-media-${media.key.encoded.hashCode.toUnsigned(20)}'
        '${extension.isEmpty ? _defaultExtension(media.kind) : extension}';
  }

  static String _defaultExtension(PostMediaKind kind) => switch (kind) {
    PostMediaKind.photo => '.jpg',
    PostMediaKind.video || PostMediaKind.gif => '.mp4',
  };
}
