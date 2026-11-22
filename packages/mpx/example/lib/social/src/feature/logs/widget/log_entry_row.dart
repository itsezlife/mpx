import 'package:flutter/material.dart';
import 'package:l/l.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/common/util/log_level_label.dart';
import 'package:mpx_example/social/src/feature/logs/model/log_export.dart';

/// Severity tones for the log journal: chip, row stripe, and level badge
/// share one colour per level so the eye can follow a level across all
/// three.
extension LogLevelPalette on ThemeData {
  /// Tone for [level]. Verbosity steps share a neutral that still reads as
  /// text on the surface.
  Color logLevelColor(LogLevel level) => level.maybeWhen(
    shout: () => colors.like,
    error: () => colorScheme.error,
    warning: () => colorScheme.tertiary,
    info: () => colors.boost,
    debug: () => colorScheme.primary,
    orElse: () => colorScheme.onSurfaceVariant,
  );
}

/// One journal line: level stripe, glyph, wall-clock time, level badge, and
/// the first two lines of the message.
class LogEntryRow extends StatelessWidget {
  const LogEntryRow({
    required this.log,
    required this.onTap,
    this.onLongPress,
    super.key,
  });

  final LogMessage log;
  final VoidCallback onTap;

  /// Secondary action, e.g. copy.
  final VoidCallback? onLongPress;

  static const double _stripeWidth = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final tone = theme.logLevelColor(log.level);
    final metaStyle = textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(color: tone, width: _stripeWidth),
          ),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            AppSpacing.m,
            AppSpacing.s,
            AppSpacing.l,
            AppSpacing.s,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(log.level.emoji, style: metaStyle),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(log.timestamp.clockTime, style: metaStyle),
                  ),
                  LogLevelBadge(level: log.level),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                log.message.toString(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tinted upper-case level tag (`ERROR`, `VVVV`).
class LogLevelBadge extends StatelessWidget {
  const LogLevelBadge({required this.level, super.key});

  final LogLevel level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = theme.logLevelColor(level);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          level.tag,
          style: theme.textTheme.labelSmall?.copyWith(
            color: tone,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
