import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mpx/mpx.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/transfers/dev_server.dart';
import 'package:mpx_example/transfers/network_cut.dart';
import 'package:mpx_example/transfers/transfer_settings.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

/// The example's transfer side, as its composition root wires it: one
/// [Transfers] over the media stack's own fetcher and store, the server it
/// sends to, the settings it was opened with and the debug panel's network
/// cut.
///
/// The engine's connectivity is the device's network signal (the one the
/// asset cache scope reads), and offline while the network is cut.
final class TransfersRoot {
  TransfersRoot({
    required this.transfers,
    required this.server,
    required this.settings,
    required this.cut,
    required ValueListenable<NetworkClass> network,
  }) : _network = network {
    _network.addListener(_feedConnectivity);
    cut.addListener(_feedConnectivity);
    _online = _isOnline;
  }

  /// The facade every transfer of the demo goes through.
  final Transfers transfers;

  /// The development server the demo sends to.
  final DevServer server;

  /// The settings the engine was opened with; changes apply at the next
  /// start.
  final TransferSettings settings;

  /// The debug panel's network cut.
  final NetworkCut cut;

  final ValueListenable<NetworkClass> _network;
  late bool _online;

  bool get _isOnline => _network.value != NetworkClass.none && !cut.value;

  void _feedConnectivity() {
    final online = _isOnline;
    if (online == _online) return;
    _online = online;
    transfers.connectivityChanged(online: online);
  }

  /// The OS envelope's text and icon, and the host's say over when it
  /// starts and (on iOS) when its continued-processing task is asked for.
  static TransferEnvelopeConfig envelopeConfig(TransferSettings settings) =>
      TransferEnvelopeConfig(
        title: 'Sending media',
        text: 'Uploads go on while the app is in the background.',
        cancelAllLabel: 'Cancel all',
        progressText: (progress) => switch (progress.jobs.length) {
          1 => '1 upload left',
          final left => '$left uploads left',
        },
        // A monochrome drawable of the example's own (Android).
        icon: 'ic_stat_transfer',
        startRule: settings.startRule,
        submitAt: settings.submitAt,
      );

  /// The platform's OS envelope: Android and iOS have one; desktop and the
  /// web run every job in process.
  static TransferEnvelope? platformEnvelope() {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return AndroidTransferEnvelope();
    if (Platform.isIOS) return IosTransferEnvelope();
    return null;
  }

  /// Opens the engine over the stack's pieces in [context] and registers
  /// the demo's publisher before any job of the last run can publish.
  ///
  /// [directory] is the bytes cache's folder (null on the web). [hostClient]
  /// carries the host's own calls to [server].
  static Future<TransfersRoot> open({
    required MpxTrackedContext context,
    required DevServer server,
    required TransferSettings settings,
    required NetworkCut cut,
    required http.Client hostClient,
    required ValueListenable<NetworkClass> network,
    required String? directory,
  }) async {
    final transfers = await Transfers.open(
      cacheKeyOf: MpxStack.cacheKeyOf,
      lifecycle: WidgetsPlaybackLifecycleSource(),
      directory: directory,
      downloads: TransferDownloads(
        fetcher: context.fetcher,
        resolver: context.resolver ?? DevServerResolver(server),
        store: context.store,
      ),
      envelope: platformEnvelope(),
      envelopeConfig: envelopeConfig(settings),
      transports: server.transports(context.client),
      client: context.client,
      preparation: _preparation(directory),
      online: network.value != NetworkClass.none,
    );
    transfers.registerPublisher(
      DevServerPublisher.id,
      DevServerPublisher(server, client: hostClient),
    );
    context.onDispose(transfers.dispose);
    return TransfersRoot(
      transfers: transfers,
      server: server,
      settings: settings,
      cut: cut,
      network: network,
    );
  }

  // The platform's preparation: stills scaled, videos compressed, into a
  // folder beside the cache.
  static MediaPreparation? _preparation(String? directory) {
    if (kIsWeb || directory == null) return null;
    final output = Directory('$directory/prepared')
      ..createSync(recursive: true);
    return CaptureMediaPreparation(
      preparer: MediaPreparer(
        codec: const PlatformPreparationCodec(),
        transcoder: const PlatformTranscoder(),
        outputDirectory: output.path,
      ),
      policy: PreparationPolicy.forPlatform(defaultTargetPlatform),
    );
  }

  /// Stops listening to the device; the stack disposes [transfers].
  void dispose() {
    _network.removeListener(_feedConnectivity);
    cut.removeListener(_feedConnectivity);
  }
}

/// Asks before the app quits while a `system` upload is active
/// ([Transfers.systemActive]): on desktop there is no OS envelope, so a
/// quit ends every job. Elsewhere the platform does not ask the app.
class TransfersQuitGuard extends StatefulWidget {
  const TransfersQuitGuard({
    required this.transfers,
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  final Transfers transfers;

  /// Where the confirmation is shown.
  final GlobalKey<NavigatorState> navigatorKey;

  final Widget child;

  @override
  State<TransfersQuitGuard> createState() => _TransfersQuitGuardState();
}

class _TransfersQuitGuardState extends State<TransfersQuitGuard> {
  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  Future<AppExitResponse> _onExitRequested() async {
    if (!widget.transfers.systemActive.value) return AppExitResponse.exit;
    final context = widget.navigatorKey.currentContext;
    if (context == null) return AppExitResponse.exit;
    final quit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Uploads are running'),
        content: const Text(
          'Quitting now stops them. They resume from where they were at the '
          'next start.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep running'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Quit'),
          ),
        ],
      ),
    );
    return (quit ?? false) ? AppExitResponse.exit : AppExitResponse.cancel;
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
