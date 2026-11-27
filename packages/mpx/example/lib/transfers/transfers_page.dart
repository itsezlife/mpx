import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/journal/data/diagnostics_journal.dart';
import 'package:mpx_example/journal/model/journal_view.dart';
import 'package:mpx_example/journal/view/journal_page.dart';
import 'package:mpx_example/loading_demo.dart';
import 'package:mpx_example/transfers/dev_server.dart';
import 'package:mpx_example/transfers/transfer_settings.dart';
import 'package:mpx_example/transfers/transfers_debug_panel.dart';
import 'package:mpx_example/transfers/transfers_demo.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

/// Picks the files to send; an empty list when the user picked none.
typedef DemoPicker = Future<List<DemoPick>> Function();

/// The transfers demo: pick media and send it as a publish job through a
/// chosen protocol, watch each job's progress and each item's ring, list
/// every publish job (`watchJobs`) and transfer job (`watch`), the
/// server's files as cells that download as tracked jobs, and the debug
/// panel. A long press on a cell opens the logs of that item.
///
/// Must sit under the stack's `AssetCacheProvider`.
class TransfersPage extends StatefulWidget {
  const TransfersPage({
    required this.demo,
    required this.journal,
    required this.pick,
    super.key,
  });

  final TransfersDemo demo;

  /// The log the cells' long press opens, filtered to the item.
  final DiagnosticsJournal journal;

  /// Picks the files to send, or null where nothing can be picked.
  final DemoPicker? pick;

  static Route<void> route({
    required TransfersDemo demo,
    required DiagnosticsJournal journal,
    required DemoPicker? pick,
    required Widget Function(Widget page) wrap,
  }) => MaterialPageRoute<void>(
    settings: const RouteSettings(name: 'transfers'),
    builder: (_) =>
        wrap(TransfersPage(demo: demo, journal: journal, pick: pick)),
  );

  @override
  State<TransfersPage> createState() => _TransfersPageState();
}

class _TransfersPageState extends State<TransfersPage> {
  TransfersDemo get _demo => widget.demo;
  Transfers get _transfers => _demo.transfers;
  TransferSettings get _settings => _demo.settings;

  bool _prepare = !kIsWeb && defaultTargetPlatform.isMobile;
  bool _manualFiles = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_demo.refreshFiles());
  }

  Future<void> _pickAndSend() async {
    final pick = widget.pick;
    if (pick == null || _sending) return;
    setState(() => _sending = true);
    try {
      final picks = await pick();
      if (picks.isEmpty) return;
      await _demo.send(picks, prepare: _prepare);
    } on Object catch (error) {
      _say('Not sent: $error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _logsOf(JournalFilter filter) => Navigator.of(
    context,
  ).push(JournalPage.route(journal: widget.journal, filter: filter));

  Future<void> _editServer() async {
    final controller = TextEditingController(text: '${_settings.server}');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Upload server'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            helperText: 'Applies at the next start',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final uri = value == null ? null : Uri.tryParse(value.trim());
    if (uri == null || !uri.hasAuthority) return;
    _settings.server = uri;
    _say('Saved; restart the app to use it.');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Transfers'),
      actions: [
        IconButton(
          tooltip: 'Debug panel',
          icon: const Icon(Icons.bug_report_outlined),
          onPressed: () => Navigator.of(context).push(
            TransfersDebugPanel.route(demo: _demo, journal: widget.journal),
          ),
        ),
        IconButton(
          tooltip: 'Logs',
          icon: const Icon(Icons.article_outlined),
          onPressed: () => _logsOf(JournalFilter.all()),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Server'),
            subtitle: Text(
              _demo.server.base == _settings.server
                  ? '${_settings.server}'
                  : '${_demo.server.base} (next start: ${_settings.server})',
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: _editServer,
          ),
          SegmentedButton<DemoTransport>(
            segments: [
              for (final transport in DemoTransport.values)
                ButtonSegment(value: transport, label: Text(transport.label)),
            ],
            selected: {_settings.transport},
            onSelectionChanged: (selected) =>
                _settings.transport = selected.single,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Prepare before upload'),
            subtitle: const Text('Scale stills, compress videos'),
            value: _prepare,
            onChanged: (value) => setState(() => _prepare = value),
          ),
          FilledButton.icon(
            key: const ValueKey('transfers.send'),
            onPressed: widget.pick == null || _sending ? null : _pickAndSend,
            icon: const Icon(Icons.upload_outlined),
            label: Text(
              widget.pick == null
                  ? 'Picking is not available here'
                  : 'Pick and send',
            ),
          ),
          const SizedBox(height: 24),
          Text('Publish jobs', style: Theme.of(context).textTheme.titleMedium),
          StreamBuilder<List<PublishJobSnapshot>>(
            stream: _transfers.watchJobs(),
            builder: (context, snapshot) => Column(
              children: [
                for (final job in (snapshot.data ?? const []).reversed)
                  _JobCard(
                    job: job,
                    transfers: _transfers,
                    onForward: (key) => _demo.forward(key),
                    onLogs: _logsOf,
                  ),
                if (snapshot.data?.isEmpty ?? true)
                  const ListTile(title: Text('None yet')),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('Transfer jobs', style: Theme.of(context).textTheme.titleMedium),
          StreamBuilder<List<TransferJob>>(
            stream: _transfers.watch(),
            builder: (context, snapshot) => Column(
              children: [
                for (final job in (snapshot.data ?? const []).reversed)
                  _TransferTile(job: job, transfers: _transfers),
                if (snapshot.data?.isEmpty ?? true)
                  const ListTile(title: Text('None')),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Server files',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'List again',
                icon: const Icon(Icons.refresh),
                onPressed: _demo.refreshFiles,
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Wait for a tap'),
            subtitle: const Text('Off: cells download by themselves'),
            value: _manualFiles,
            onChanged: (value) => setState(() => _manualFiles = value),
          ),
          ValueListenableBuilder(
            valueListenable: _demo.filesError,
            builder: (context, error, _) => error == null
                ? const SizedBox.shrink()
                : Text('Not listed: $error'),
          ),
          ValueListenableBuilder(
            valueListenable: _demo.files,
            builder: (context, files, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final file in files)
                  _ServerFileCell(
                    file: file,
                    manual: _manualFiles,
                    onDownload: () => _demo.download(file.key),
                    onForward: () => _demo.forward(file.key),
                    onLogs: () =>
                        _logsOf(JournalFilter.ofMediaKey(file.key.encoded)),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

extension on TargetPlatform {
  bool get isMobile =>
      this == TargetPlatform.android || this == TargetPlatform.iOS;
}

/// One content's cell: its picture with the status control (ring, cancel,
/// download) and the size badge; a long press opens its logs.
class TransferCell extends StatelessWidget {
  const TransferCell({
    required this.content,
    required this.onLongPress,
    this.downloadContext,
    super.key,
  });

  static const double extent = 96;

  final MediaKey content;
  final VoidCallback onLongPress;
  final AutoDownloadContext? downloadContext;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPress: onLongPress,
    child: SizedBox.square(
      dimension: extent,
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: AssetView(
            content: content,
            preset: AssetPresets.square(
              extent: extent,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              profile: const AssetProfile(animate: true),
            ),
            downloadContext: downloadContext,
            status: const MediaStatusMode.control(),
            badge: true,
          ),
        ),
      ),
    ),
  );
}

class _JobCard extends StatelessWidget {
  const _JobCard({
    required this.job,
    required this.transfers,
    required this.onForward,
    required this.onLogs,
  });

  final PublishJobSnapshot job;
  final Transfers transfers;
  final void Function(MediaKey key) onForward;
  final void Function(JournalFilter filter) onLogs;

  String get _state => switch (job.state) {
    PublishJobState$Paused(:final reason) => 'paused (${reason.name})',
    PublishJobState$Failed(:final stage, :final reason, :final retryable) =>
      'failed at ${stage.name}: $reason${retryable ? ', retryable' : ''}',
    final state => state.name,
  };

  @override
  Widget build(BuildContext context) {
    final handle = transfers.publishJob(job.id);
    final ended =
        job.state is PublishJobState$Completed ||
        job.state is PublishJobState$Failed;
    return Card(
      key: ValueKey('transfers.job.${job.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${job.tag ?? job.id}\n$_state',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Text('${(job.progress * 100).round()} %'),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: job.progress),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in job.items)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TransferCell(
                        key: ValueKey('transfers.item.${item.itemId}'),
                        content: item.key,
                        onLongPress: () =>
                            onLogs(JournalFilter.ofItem(item.itemId)),
                      ),
                      SizedBox(
                        width: TransferCell.extent,
                        child: Text(
                          item.state.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      if (TransfersDemo.serverKeyOf(item) case final key?
                          when job.state is PublishJobState$Completed)
                        TextButton(
                          onPressed: () => onForward(key),
                          child: const Text('Forward'),
                        ),
                    ],
                  ),
              ],
            ),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => onLogs(switch (job.tag) {
                    // The tag reaches the job's uploads too.
                    final tag? => JournalFilter.all().withId(
                      JournalIdKind.tag,
                      tag,
                    ),
                    null => JournalFilter.all().withId(
                      JournalIdKind.jobId,
                      job.id,
                    ),
                  }),
                  child: const Text('Logs'),
                ),
                if (job.state is PublishJobState$Failed)
                  TextButton(
                    onPressed: () => handle?.retry(),
                    child: const Text('Retry'),
                  ),
                if (!ended)
                  TextButton(
                    onPressed: () => handle?.cancel(),
                    child: const Text('Cancel'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.job, required this.transfers});

  final TransferJob job;
  final Transfers transfers;

  String get _state => switch (job.state) {
    TransferState$Queued() => 'queued',
    TransferState$Running(:final done, :final total) =>
      'running ${_bytes(done)} of ${total == null ? '?' : _bytes(total)}',
    TransferState$Paused(:final reason, :final done) =>
      'paused (${reason.name}) at ${_bytes(done)}',
    TransferState$Failed(:final kind, :final retryable) =>
      'failed (${kind.name}${retryable ? ', retryable' : ''})',
    TransferState$Completed() => 'completed',
  };

  static String _bytes(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KiB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';

  @override
  Widget build(BuildContext context) {
    final state = job.state;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        job.direction == TransferDirection.upload
            ? Icons.upload_outlined
            : Icons.download_outlined,
      ),
      title: Text(_state),
      subtitle: Text(
        '${job.id.substring(0, 10)} · ${job.durability.name}'
        '${job.tag == null ? '' : ' · ${job.tag}'}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state is TransferState$Running || state is TransferState$Queued)
            IconButton(
              tooltip: 'Pause',
              icon: const Icon(Icons.pause),
              onPressed: () => transfers.pause(job.id),
            ),
          if (state is TransferState$Paused)
            IconButton(
              tooltip: 'Resume',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => transfers.resume(job.id),
            ),
          if (state is TransferState$Failed)
            IconButton(
              tooltip: 'Retry',
              icon: const Icon(Icons.refresh),
              onPressed: () => transfers.retry(job.id),
            ),
        ],
      ),
    );
  }
}

class _ServerFileCell extends StatelessWidget {
  const _ServerFileCell({
    required this.file,
    required this.manual,
    required this.onDownload,
    required this.onForward,
    required this.onLogs,
  });

  final DevServerFile file;
  final bool manual;
  final VoidCallback onDownload;
  final VoidCallback onForward;
  final VoidCallback onLogs;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      TransferCell(
        key: ValueKey('transfers.file.${file.id}'),
        content: file.key,
        downloadContext: manual ? LoadingDemo.manual : null,
        onLongPress: onLogs,
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Download (resumes after a restart)',
            icon: const Icon(Icons.download_outlined, size: 18),
            onPressed: onDownload,
          ),
          IconButton(
            tooltip: 'Forward',
            icon: const Icon(Icons.forward_outlined, size: 18),
            onPressed: onForward,
          ),
        ],
      ),
    ],
  );
}
