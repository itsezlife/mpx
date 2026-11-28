import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mpx_example/journal/model/diagnostics_entry.dart';
import 'package:mpx_example/journal/model/journal_export.dart';
import 'package:mpx_example/journal/widget/diagnostics_entry_row.dart';

/// The whole of one record: level, time, source, operation, ids, fields,
/// error and stack. Copy puts the record on the clipboard as indented JSON.
class DiagnosticsEntryDetailsDialog extends StatelessWidget {
  /// The dialog of [record].
  const DiagnosticsEntryDetailsDialog({required this.record, super.key});

  /// The record shown.
  final DiagnosticsEntry record;

  /// Opens the dialog of [record].
  static Future<void> show(BuildContext context, DiagnosticsEntry record) =>
      showDialog<void>(
        useRootNavigator: false,
        context: context,
        builder: (_) => DiagnosticsEntryDetailsDialog(record: record),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium;
    final small = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return AlertDialog(
      title: Text(
        '${record.category}.${record.op}',
        style: theme.textTheme.titleMedium,
      ),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          _Field(
            label: 'Level',
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: JournalLevelBadge(level: record.level),
            ),
          ),
          _Field(
            label: 'Time',
            child: Text(record.time.journalDateTime, style: base),
          ),
          _Field(
            label: 'Source',
            child: Text(record.source.name, style: base),
          ),
          if (record.message case final message?)
            _Field(
              label: 'Message',
              child: SelectableText(message, style: base),
            ),
          if (record.ids.isNotEmpty)
            _Field(
              label: 'Ids',
              child: SelectableText(
                [
                  for (final MapEntry(:key, :value) in record.ids.entries)
                    '$key: $value',
                ].join('\n'),
                style: small,
              ),
            ),
          if (record.fields.isNotEmpty)
            _Field(
              label: 'Fields',
              child: SelectableText(
                [
                  for (final MapEntry(:key, :value) in record.fields.entries)
                    '$key: $value',
                ].join('\n'),
                style: small,
              ),
            ),
          if (record.error case final error?)
            _Field(
              label: 'Error',
              child: SelectableText(error, style: small),
            ),
          if (record.stackTrace case final trace?)
            _Field(
              label: 'Stack trace',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: SelectableText(trace, style: small),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(
              ClipboardData(text: JournalExport.entryText(record)),
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
      spacing: 4,
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
