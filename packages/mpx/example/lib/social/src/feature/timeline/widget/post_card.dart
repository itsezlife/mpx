import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_md/flutter_md.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/common/util/count_format.dart';
import 'package:mpx_example/social/src/common/util/time_ago_extension.dart';
import 'package:mpx_example/social/src/common/widget/avatar.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/post_selection.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/post_media_album.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/post_text_view.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// One post: who wrote it and when, its text, its media as an album, and its
/// counts. A content warning or sensitive media wait behind a button.
class PostCard extends StatelessWidget {
  const PostCard({
    required this.post,
    required this.markdown,
    required this.firstIndex,
    required this.mediaWidth,
    required this.revealed,
    required this.onReveal,
    required this.selection,
    super.key,
  });

  final Post post;

  /// The post's text, parsed: the object the list's selection holds.
  final Markdown markdown;

  /// The feed index of the post's first media.
  final int firstIndex;

  /// The width the album has.
  final double mediaWidth;

  /// Whether the reader asked to see what the post covers.
  final bool revealed;
  final VoidCallback onReveal;

  /// What the post's text joins to be selected: one selection of the list
  /// at a time.
  final PostSelection selection;

  /// How many lines of text show before "Show more".
  static const int _collapsedLines = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;
    final covered = post.covered && !revealed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (post.boostedBy case final booster?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.l + 40 + AppSpacing.m,
              AppSpacing.m,
              AppSpacing.l,
              0,
            ),
            child: Row(
              children: [
                Icon(LucideIcons.repeat_2, size: 14, color: theme.colors.boost),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(
                    '${booster.displayName} boosted',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.l,
            AppSpacing.m,
            AppSpacing.xs,
            0,
          ),
          child: _Header(post: post),
        ),
        if (post.warning.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.l,
              AppSpacing.s,
              AppSpacing.l,
              0,
            ),
            child: _Warning(
              text: post.warning,
              revealed: revealed,
              onToggle: onReveal,
            ),
          ),
        if (!post.text.isEmpty && !(post.warning.isNotEmpty && covered))
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.l,
              AppSpacing.s,
              AppSpacing.l,
              0,
            ),
            child: PostTextView(
              markdown: markdown,
              documentId: post.id,
              host: post.host,
              maxLines: _collapsedLines,
              selectionGroup: selection.group,
              selectable: !post.covered || revealed,
            ),
          ),
        if (post.media.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.l,
              AppSpacing.m,
              AppSpacing.l,
              0,
            ),
            child: covered
                ? _MediaCover(
                    width: mediaWidth,
                    sensitive: post.sensitive,
                    onReveal: onReveal,
                  )
                : PostMediaAlbum(
                    post: post,
                    firstIndex: firstIndex,
                    width: mediaWidth,
                  ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s,
            AppSpacing.xs,
            AppSpacing.s,
            AppSpacing.xs,
          ),
          child: _Actions(post: post),
        ),
        const Divider(),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.post});

  final Post post;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final muted = theme.colorScheme.onSurfaceVariant;
    final author = post.author;
    return Row(
      children: [
        Avatar(name: author.displayName, picture: author.avatar),
        const SizedBox(width: AppSpacing.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      author.displayName,
                      style: textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (author.bot) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Icon(LucideIcons.bot, size: 14, color: muted),
                  ],
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    '· ${post.createdAt.timeAgoShort()}',
                    style: textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
              Text(
                '@${author.handle}',
                style: textTheme.bodySmall?.copyWith(color: muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        PopupMenuButton<_PostMenu>(
          icon: Icon(LucideIcons.ellipsis, color: muted),
          tooltip: 'More',
          onSelected: (action) => switch (action) {
            _PostMenu.web => launchUrl(
              Uri.parse(post.url),
              mode: LaunchMode.externalApplication,
            ),
            _PostMenu.share => SharePlus.instance.share(
              ShareParams(uri: Uri.parse(post.url)),
            ),
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: _PostMenu.web, child: Text('Open on the web')),
            PopupMenuItem(value: _PostMenu.share, child: Text('Share link')),
          ],
        ),
      ],
    );
  }
}

enum _PostMenu { web, share }

class _Warning extends StatelessWidget {
  const _Warning({
    required this.text,
    required this.revealed,
    required this.onToggle,
  });

  final String text;
  final bool revealed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadius.media),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Row(
          children: [
            Icon(
              LucideIcons.triangle_exclamation_point,
              color: colorScheme.tertiary,
            ),
            const SizedBox(width: AppSpacing.m),
            Expanded(child: Text(text)),
            if (!revealed)
              TextButton(onPressed: onToggle, child: const Text('Show')),
          ],
        ),
      ),
    );
  }
}

/// Stands where the album would: the media of a post the author marked
/// sensitive, or put behind a warning, are not fetched until asked for.
class _MediaCover extends StatelessWidget {
  const _MediaCover({
    required this.width,
    required this.sensitive,
    required this.onReveal,
  });

  final double width;
  final bool sensitive;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onReveal,
      child: Container(
        width: width,
        height: width / 1.6,
        decoration: BoxDecoration(
          color: theme.colors.mediaPlaceholder,
          borderRadius: BorderRadius.circular(AppRadius.media),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.eye_off,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.s),
            Text(
              sensitive ? 'Sensitive content' : 'Hidden by the author',
              style: theme.textTheme.titleSmall,
            ),
            Text(
              'Tap to show',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.post});

  final Post post;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget count(IconData icon, int value, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s,
        vertical: AppSpacing.s,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: color ?? muted),
          if (value > 0) ...[
            const SizedBox(width: AppSpacing.xs),
            Text(
              value.compact,
              style: theme.textTheme.labelMedium?.copyWith(color: muted),
            ),
          ],
        ],
      ),
    );
    return Row(
      children: [
        count(LucideIcons.message_circle, post.replies),
        const SizedBox(width: AppSpacing.m),
        count(LucideIcons.repeat_2, post.boosts, color: theme.colors.boost),
        const SizedBox(width: AppSpacing.m),
        count(LucideIcons.heart, post.likes, color: theme.colors.like),
        const Spacer(),
        IconButton(
          tooltip: 'Share',
          icon: Icon(LucideIcons.share, size: 20, color: muted),
          onPressed: () =>
              SharePlus.instance.share(ShareParams(uri: Uri.parse(post.url))),
        ),
      ],
    );
  }
}
