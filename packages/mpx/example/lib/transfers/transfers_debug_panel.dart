import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mpx_example/journal/data/diagnostics_journal.dart';
import 'package:mpx_example/journal/view/journal_page.dart';
import 'package:mpx_example/transfers/transfers_demo.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

/// The debug panel over the transfers demo: the engine's
/// `debugSnapshot()`, read live, with its counters (parts in flight,
/// retries, restarts from zero, envelopes started and ended by the
/// system), and the actions a device check needs: kill the process in
/// 3 s, cut the app's network, act out a system end of the OS envelope,
/// switch the server's modes, and the envelope settings of the next start.
class TransfersDebugPanel extends StatefulWidget {
  const TransfersDebugPanel({
    required this.demo,
    required this.journal,
    this.refresh = const Duration(milliseconds: 500),
    super.key,
  });

  final TransfersDemo demo;
  final DiagnosticsJournal journal;

  /// How often the snapshot is read again.
  final Duration refresh;

  static Route<void> route({
    required TransfersDemo demo,
    required DiagnosticsJournal journal,
  }) => MaterialPageRoute<void>(
    settings: const RouteSettings(name: 'transfers/debug'),
    builder: (_) => TransfersDebugPanel(demo: demo, journal: journal),
  );

  @override
  State<TransfersDebugPanel> createState() => _TransfersDebugPanelState();
}

class _TransfersDebugPanelState extends State<TransfersDebugPanel> {
  TransfersDemo get _demo => widget.demo;
  late TransfersDebugSnapshot _snapshot = _demo.transfers.debugSnapshot();
  late final Timer _timer;
  Map<String, Object?>? _serverModes;
  bool _controlBusy = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.refresh, (_) {
      if (mounted) {
        setState(() => _snapshot = _demo.transfers.debugSnapshot());
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _control({String? upload, String? publish, int? rate}) async {
    if (_controlBusy) return;
    setState(() => _controlBusy = true);
    try {
      final modes = await _demo.server.control(
        upload: upload,
        publish: publish,
        rateKiBs: rate,
      );
      if (mounted) setState(() => _serverModes = modes);
    } on Object catch (error) {
      if (mounted) _say('Server not reached: $error');
    } finally {
      if (mounted) setState(() => _controlBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final uploads = snapshot.uploads;
    final connections = snapshot.connections;
    final journal = snapshot.journal;
    final reuse = snapshot.reuse;
    final publish = snapshot.publish;
    final envelope = snapshot.envelope;
    final settings = _demo.settings;
    final title = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfers debug'),
        actions: [
          IconButton(
            tooltip: 'Logs',
            icon: const Icon(Icons.article_outlined),
            onPressed: () => Navigator.of(
              context,
            ).push(JournalPage.route(journal: widget.journal)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Actions', style: title),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                key: const ValueKey('debug.kill'),
                onPressed: () => setState(
                  _demo.killPending ? _demo.cancelKill : _demo.killIn,
                ),
                child: Text(
                  _demo.killPending ? 'Killing in 3 s: cancel' : 'Kill in 3 s',
                ),
              ),
              FilledButton.tonal(
                key: const ValueKey('debug.interrupt'),
                onPressed: () {
                  final paused = _demo.simulateSystemInterruption();
                  _say('$paused jobs paused (systemInterrupted)');
                },
                child: const Text('Simulate system interruption'),
              ),
            ],
          ),
          SwitchListTile(
            key: const ValueKey('debug.cut'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Cut the network'),
            subtitle: const Text('Every request fails; the engine is offline'),
            value: _demo.networkCut,
            onChanged: (cut) => setState(() => _demo.networkCut = cut),
          ),
          const SizedBox(height: 16),
          Text('Server', style: title),
          Text(
            _serverModes == null
                ? '${_demo.server.base}'
                : '${_demo.server.base}  $_serverModes',
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final upload in const ['ok', 'fail'])
                OutlinedButton(
                  onPressed: () => _control(upload: upload),
                  child: Text('upload $upload'),
                ),
              for (final publish in const [
                'ok',
                'reject',
                'rejectRetryable',
                'reupload',
              ])
                OutlinedButton(
                  onPressed: () => _control(publish: publish),
                  child: Text('publish $publish'),
                ),
              for (final rate in const [0, 256, 2048])
                OutlinedButton(
                  onPressed: () => _control(rate: rate),
                  child: Text(rate == 0 ? 'no rate limit' : '$rate KiB/s'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Envelope at the next start', style: title),
          ListenableBuilder(
            listenable: settings,
            builder: (context, _) => Column(
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('After 10 s')),
                    ButtonSegment(value: true, label: Text('On resign active')),
                  ],
                  selected: {
                    settings.submitAt
                        is TransferEnvelopeSubmitAt$OnResignActive,
                  },
                  onSelectionChanged: (selected) =>
                      settings.submitAt = selected.single
                      ? const TransferEnvelopeSubmitAt.onResignActive()
                      : const TransferEnvelopeSubmitAt.afterDelay(),
                ),
                const SizedBox(height: 8),
                SegmentedButton<TransferEnvelopeStartRule?>(
                  segments: [
                    const ButtonSegment(value: null, label: Text('Platform')),
                    for (final rule in TransferEnvelopeStartRule.values)
                      ButtonSegment(value: rule, label: Text(rule.name)),
                  ],
                  selected: {settings.startRule},
                  onSelectionChanged: (selected) =>
                      settings.startRule = selected.single,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('Counters', style: title),
          _Rows({
            'Parts in flight': '${uploads?.partsInFlight ?? '-'}',
            'Part retries': '${uploads?.partRetries ?? '-'}',
            'Restarts from zero': '${uploads?.restartsFromZero ?? '-'}',
            'Envelopes started': '${envelope?.started ?? '-'}',
            'Ended by the system': '${envelope?.endedBySystem ?? '-'}',
          }),
          Text('Engine', style: title),
          _Rows({
            'Online': '${snapshot.online}',
            'System active': '${_demo.transfers.systemActive.value}',
            'Jobs': '${snapshot.jobs.length}',
            for (final MapEntry(key: lane, value: queue)
                in (uploads?.lanes ??
                        const <UploadLane, UploadLaneDebugSnapshot>{})
                    .entries)
              'Lane ${lane.name}':
                  '${queue.running ?? 'idle'}, ${queue.queued} queued',
            if (connections != null)
              'Connections':
                  '${connections.downloads} down / ${connections.uploads} up '
                  'of ${connections.cap} (down ${connections.downloadCap}, '
                  'up ${connections.uploadCap}), ${connections.waiting} waiting',
          }),
          Text('Journal', style: title),
          _Rows({
            'Store': journal.store,
            'Bytes': '${journal.bytes}',
            'Records since compaction': '${journal.recordsSinceCompaction}',
            'Last state write': '${journal.lastStateWriteAt ?? '-'}',
            'Last progress flush': '${journal.lastProgressFlushAt ?? '-'}',
          }),
          Text('Envelope', style: title),
          _Rows({
            if (envelope == null)
              'Envelope': 'none on this platform (jobs run in process)'
            else ...{
              'State': envelope.state.name,
              'Rule': envelope.rule.name,
              'Kind': envelope.kind?.name ?? '-',
              'Handle': envelope.handle ?? '-',
              'Jobs inside': '${envelope.jobs.length}',
              'Submit at': envelope.submitAt?.name ?? '-',
              'Submit due': '${envelope.submitDueAt ?? '-'}',
            },
          }),
          Text('Reuse and publish', style: title),
          _Rows({
            if (reuse != null) ...{
              'Reuse': reuse.enabled ? 'on' : 'off',
              'Entries': '${reuse.entries}',
              'Hits / misses': '${reuse.hits} / ${reuse.misses}',
            },
            if (publish != null) ...{
              'Publishers': publish.publishers.join(', '),
              'Publish jobs': '${publish.jobs.length}',
              'Awaiting publisher': '${publish.awaitingPublisher.length}',
              'Awaiting owner': '${publish.awaitingOwner.length}',
            },
          }),
          Text('Jobs', style: title),
          for (final job in snapshot.jobs)
            Text(
              '${job.id.substring(0, 10)} ${job.direction.name} '
              '${job.durability.name} ${job.state.runtimeType}'
              '${job.tag == null ? '' : ' ${job.tag}'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          for (final job in publish?.jobs ?? const <PublishJobDebugSnapshot>[])
            Text(
              '${job.id} ${job.state.name} attempts ${job.attempts}: '
              '${[for (final item in job.items) '${item.item.state.name}${item.reuseHit ? ' (reuse)' : ''}'].join(', ')}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _Rows extends StatelessWidget {
  const _Rows(this.rows);

  final Map<String, String> rows;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      children: [
        for (final MapEntry(:key, :value) in rows.entries)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(key)),
              Expanded(child: Text(value, textAlign: TextAlign.end)),
            ],
          ),
      ],
    ),
  );
}
