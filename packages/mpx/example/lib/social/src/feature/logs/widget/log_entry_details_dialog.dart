import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:l/l.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/feature/logs/model/log_export.dart';
import 'package:mpx_example/social/src/feature/logs/widget/log_entry_row.dart';

/// Full view of one log: level, date and time, selectable message, context,
/// and stack trace. Copy puts the entry on the clipboard as a console block.
class LogEntryDetailsDialog extends StatelessWidget {
  const LogEntryDetailsDialog({required this.log, super.key});

  final LogMessage log;

  /// Opens the dialog for [log].
  static Future<void> show(BuildContext context, LogMessage log) =>
      showDialog<void>(
        context: context,
        builder: (_) => LogEntryDetailsDialog(log: log),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final monoStyle = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
    );
    final stackTrace = switch (log) {
      LogMessageError(:final stackTrace)
          when stackTrace.toString().trim().isNotEmpty =>
        stackTrace.toString().trim(),
      _ => null,
    };
    return AlertDialog(
      title: const Text('Log entry'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.m,
        children: [
          _Field(
            label: 'Level',
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: LogLevelBadge(level: log.level),
            ),
          ),
          _Field(label: 'Time', child: Text(log.timestamp.logDateTime)),
          _Field(
            label: 'Message',
            child: SelectableText(log.message.toString()),
          ),
          if (log.context.isNotEmpty)
            _Field(
              label: 'Context',
              child: SelectableText(
                [
                  for (final MapEntry(:key, :value) in log.context.entries)
                    '$key: $value',
                ].join('\n'),
                style: monoStyle,
              ),
            ),
          if (stackTrace case final trace?)
            _Field(
              label: 'Stack trace',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadius.media),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.s),
                  child: SelectableText(trace, style: monoStyle),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(
              ClipboardData(text: LogExport.entryText(log)),
            );
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(
                context,
              )?.showSnackBar(const SnackBar(content: Text('Copied')));
            }
          },
          child: const Text('Copy'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.xs,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        child,
      ],
    );
  }
}
