import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:l/l.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/common/util/log_buffer.dart';
import 'package:mpx_example/social/src/common/util/log_level_label.dart';
import 'package:mpx_example/social/src/common/widget/state_views.dart';
import 'package:mpx_example/social/src/feature/logs/controller/log_journal_controller.dart';
import 'package:mpx_example/social/src/feature/logs/model/log_export.dart';
import 'package:mpx_example/social/src/feature/logs/model/log_journal_snapshot.dart';
import 'package:mpx_example/social/src/feature/logs/widget/log_entry_details_dialog.dart';
import 'package:mpx_example/social/src/feature/logs/widget/log_entry_row.dart';
import 'package:share_plus/share_plus.dart';

/// Route entry for the log journal over the process-wide [LogBuffer].
class LogJournalPage extends StatefulWidget {
  const LogJournalPage({super.key});

  @override
  State<LogJournalPage> createState() => _LogJournalPageState();
}

class _LogJournalPageState extends State<LogJournalPage> {
  late final LogJournalController _controller = LogJournalController(
    buffer: LogBuffer.instance,
  );

  /// Distance from the live edge past which the list holds still: about one
  /// row.
  static const double _pauseOffset = 48;

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  // Scroll offset 0 is the live edge, where new logs arrive. Away from it
  // the list holds still, so rows stay under the finger.
  void _onScroll() => _scroll.offset > _pauseOffset
      ? _controller.pause()
      : _controller.resume();

  void _showNewLogs() {
    _controller.resume();
    if (!_scroll.hasClients) return;
    unawaited(
      _scroll.animateTo(
        0,
        duration: Durations.medium2,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _toggleOrder() {
    _controller
      ..toggleOrder()
      ..resume();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the logs?'),
        content: const Text('Every buffered log is dropped.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) _controller.clear();
  }

  /// Shares the visible logs as a CSV file.
  Future<void> _export(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject();
    final name = LogExport.fileName(DateTime.now());
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            utf8.encode(LogExport.csv(_controller.snapshot.visible)),
            mimeType: 'text/csv',
            name: name,
          ),
        ],
        fileNameOverrides: [name],
        sharePositionOrigin: switch (box) {
          final RenderBox box => box.localToGlobal(Offset.zero) & box.size,
          _ => null,
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final countStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: _controller.order == LogJournalOrder.newestFirst
                      ? 'Newest first'
                      : 'Oldest first',
                  onPressed: _toggleOrder,
                  icon: Icon(
                    _controller.order == LogJournalOrder.newestFirst
                        ? LucideIcons.arrow_down_wide_narrow
                        : LucideIcons.arrow_up_narrow_wide,
                  ),
                ),
                IconButton(
                  tooltip: 'Clear',
                  onPressed: _controller.snapshot.total == 0
                      ? null
                      : _confirmClear,
                  icon: const Icon(LucideIcons.trash),
                ),
                Builder(
                  builder: (buttonContext) => IconButton(
                    tooltip: 'Export as CSV',
                    onPressed: _controller.snapshot.visible.isEmpty
                        ? null
                        : () => _export(buttonContext),
                    icon: const Icon(LucideIcons.share_2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _NewLogsButton(
        controller: _controller,
        onPressed: _showNewLogs,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpacing.s),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l),
            child: SearchBar(
              hintText: 'Search the logs',
              leading: const Icon(LucideIcons.search),
              elevation: const WidgetStatePropertyAll(0),
              onChanged: _controller.search,
            ),
          ),
          const SizedBox(height: AppSpacing.m),
          ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _LevelFilterBar(controller: _controller),
          ),
          const SizedBox(height: AppSpacing.s),
          Expanded(
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) {
                final snapshot = _controller.snapshot;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.l,
                      ),
                      child: Text(
                        'Showing ${snapshot.visible.length} of ${snapshot.total}',
                        style: countStyle,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s),
                    const Divider(height: 1),
                    Expanded(
                      child: _LogList(
                        snapshot: snapshot,
                        order: _controller.order,
                        scroll: _scroll,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _LogList extends StatelessWidget {
  const _LogList({
    required this.snapshot,
    required this.order,
    required this.scroll,
  });

  final LogJournalSnapshot snapshot;
  final LogJournalOrder order;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    if (snapshot.total == 0) {
      return const MessageView(
        icon: LucideIcons.scroll_text,
        title: 'No logs yet',
        hint: 'What the app logs shows up here.',
      );
    }
    if (snapshot.visible.isEmpty) {
      return const MessageView(
        icon: LucideIcons.list_filter,
        title: 'No matches',
        hint: 'Change the search or turn more levels on.',
      );
    }
    return ListView.builder(
      controller: scroll,
      // Offset 0 is the live edge: the top when newest first, the bottom
      // when oldest first, as a console has it.
      reverse: order == LogJournalOrder.oldestFirst,
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + AppSpacing.xl * 2,
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: snapshot.visible.length,
      itemBuilder: (context, index) {
        final log = snapshot.visible[index];
        return LogEntryRow(
          log: log,
          onTap: () => LogEntryDetailsDialog.show(context, log),
          onLongPress: () async {
            await Clipboard.setData(
              ClipboardData(text: log.message.toString()),
            );
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(
                context,
              )?.showSnackBar(const SnackBar(content: Text('Copied')));
            }
          },
        );
      },
    );
  }
}

/// One chip per [LogLevel]: tap toggles a level, long-press shows only that
/// level. Badges count query hits per level.
class _LevelFilterBar extends StatelessWidget {
  const _LevelFilterBar({required this.controller});

  final LogJournalController controller;

  static const double _dimmedOpacity = .45;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filter = controller.filter;
    final snapshot = controller.snapshot;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l),
      child: Row(
        spacing: AppSpacing.s,
        children: [
          for (final level in LogLevel.values)
            Semantics(
              label: level.tag,
              selected: filter.levels.contains(level),
              child: Opacity(
                opacity: filter.levels.contains(level) ? 1 : _dimmedOpacity,
                child: GestureDetector(
                  onLongPress: () => controller.soloLevel(level),
                  child: FilterChip(
                    selected: filter.levels.contains(level),
                    showCheckmark: false,
                    onSelected: (_) => controller.toggleLevel(level),
                    label: Text('${level.emoji} ${snapshot.countOf(level)}'),
                    selectedColor: theme
                        .logLevelColor(level)
                        .withValues(alpha: .16),
                    side: BorderSide(
                      color: filter.levels.contains(level)
                          ? theme.logLevelColor(level)
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Floating pill with the count of logs held back while the journal is
/// paused; hidden while there are none. The arrow points to where new logs
/// arrive in the current order.
class _NewLogsButton extends StatelessWidget {
  const _NewLogsButton({required this.controller, required this.onPressed});

  final LogJournalController controller;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => AnimatedSwitcher(
      duration: Durations.short4,
      transitionBuilder: (child, animation) => ScaleTransition(
        scale: animation,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: switch (controller.newCount) {
        0 => const SizedBox.shrink(),
        final count => FilledButton.icon(
          key: const ValueKey('new-logs'),
          onPressed: onPressed,
          icon: Icon(
            controller.order == LogJournalOrder.newestFirst
                ? LucideIcons.arrow_up
                : LucideIcons.arrow_down,
            size: 18,
          ),
          label: Text('$count new'),
        ),
      },
    ),
  );
}
