import 'package:flutter/material.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/feature/timeline/data/mastodon_client.dart';

/// What a failed read says, for the reader.
extension MastodonFailureText on MastodonFailure {
  String get title => switch (this) {
    MastodonFailure.offline => 'No connection',
    MastodonFailure.rateLimited => 'Slow down a little',
    MastodonFailure.server => 'The server did not answer',
  };

  String get hint => switch (this) {
    MastodonFailure.offline => 'Check the network and try again.',
    MastodonFailure.rateLimited =>
      'The server allows 300 requests in 5 minutes. Try again shortly.',
    MastodonFailure.server => 'It may be busy. Try again in a moment.',
  };
}

/// A full-area message with an action: a failed first read, an empty topic.
class MessageView extends StatelessWidget {
  const MessageView({
    required this.icon,
    required this.title,
    required this.hint,
    this.action,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String hint;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.l),
            Text(
              title,
              style: textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.s),
            Text(
              hint,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.l),
              FilledButton.tonal(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Grey blocks where the first page's posts will be.
class TimelineSkeleton extends StatelessWidget {
  const TimelineSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final block = Theme.of(context).colors.mediaPlaceholder;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: block,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 3,
      itemBuilder: (context, index) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppLayout.feedColumnWidth,
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: block,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.m),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        bar(120, 12),
                        const SizedBox(height: 6),
                        bar(80, 10),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.m),
                bar(double.infinity, 12),
                const SizedBox(height: 6),
                bar(220, 12),
                const SizedBox(height: AppSpacing.m),
                AspectRatio(
                  aspectRatio: 1.25,
                  child: Container(
                    decoration: BoxDecoration(
                      color: block,
                      borderRadius: BorderRadius.circular(AppRadius.media),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
