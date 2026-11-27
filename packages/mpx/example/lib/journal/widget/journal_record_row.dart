import 'package:flutter/material.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/journal/model/journal_export.dart';
import 'package:mpx_example/journal/model/journal_record.dart';

/// One colour per level, shared by the chip, the row's stripe and the
/// badge, so the eye can follow a level across all three.
extension JournalLevelPalette on ThemeData {
  /// The tone of [level]; the two quiet levels share a neutral.
  Color journalLevelColor(MpxEventLevel level) => switch (level) {
    MpxEventLevel.error => colorScheme.error,
    MpxEventLevel.warning => colorScheme.tertiary,
    MpxEventLevel.info => colorScheme.primary,
    MpxEventLevel.debug || MpxEventLevel.trace => colorScheme.onSurfaceVariant,
  };
}

/// One journal line: level stripe, wall-clock time, `category.op`, level
/// badge, then the correlation ids and the fields.
class JournalRecordRow extends StatelessWidget {
  /// A row for [record].
  const JournalRecordRow({
    required this.record,
    required this.onTap,
    super.key,
  });

  /// The record shown.
  final JournalRecord record;

  /// Opens the record's details.
  final VoidCallback onTap;

  static const double _stripeWidth = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium;
    final meta = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final facts = [
      for (final MapEntry(:key, :value) in record.ids.entries) '$key=$value',
      ?record.message,
      for (final MapEntry(:key, :value) in record.fields.entries) '$key=$value',
      if (record.error != null) 'error',
    ].join('  ');
    return InkWell(
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: BorderDirectional(
            start: BorderSide(
              color: theme.journalLevelColor(record.level),
              width: _stripeWidth,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Row(
                spacing: 8,
                children: [
                  Text(record.time.clockTime, style: meta),
                  Expanded(
                    child: Text(
                      '${record.category}.${record.op}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: base?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  JournalLevelBadge(level: record.level),
                ],
              ),
              if (facts.isNotEmpty)
                Text(
                  facts,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: meta,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tinted upper-case level tag (`ERROR`, `DEBUG`).
class JournalLevelBadge extends StatelessWidget {
  /// The badge of [level].
  const JournalLevelBadge({required this.level, super.key});

  /// The level shown.
  final MpxEventLevel level;

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).journalLevelColor(level);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          level.name.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: tone,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
