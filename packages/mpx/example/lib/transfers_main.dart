import 'package:flutter/material.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/journal/data/environment_specific/host_environment.dart'
    as environment_specific;
import 'package:mpx_example/journal/data/journal_host.dart';
import 'package:mpx_example/transfers/transfers_demo.dart';
import 'package:mpx_example/transfers/transfers_page.dart';
import 'package:mpx_example/transfers/transfers_root.dart';
import 'package:mpx_example/transfers/transfers_wiring.dart';

/// The transfers demo as an app of its own, on every platform the set
/// runs on, the web included: the stack with the engine codecs only (no
/// native decoders, players or readers), the transfer engine over it, the
/// demo page, its debug panel and the log journal.
///
///   flutter run -t lib/transfers_main.dart
///       [--dart-define=MPX_UPLOAD_SERVER=http://<computer>:8090]
///
/// The gallery app (`lib/main.dart`) wires the same demo beside its media.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // First, so the previous run's tail and everything below are in it.
  final journal = await JournalHost.start(name: 'mpx_transfers_journal');
  final cacheDirectory = environment_specific.$journalDirectoryPath(
    'mpx_transfers',
  );
  final transfers = TransfersWiring.load(cacheDirectory: cacheDirectory);
  final signals = DeviceSignals();
  final stack = await MpxStack.create(
    tracked: transfers.tracked(signals.network),
    resolver: transfers.resolver,
    signals: signals,
    locate: (descriptor, part) => transfers.locationOf(descriptor.key),
    cacheDirectory: cacheDirectory,
    // The debug panel's network cut fails every request of this client,
    // which the transfer engine sends its parts through too.
    client: HttpBytesClient(middlewares: transfers.middlewares),
    platformTextures: false,
  );
  final demo = transfers.demo(stack);
  runApp(
    _TransfersApp(
      stack: stack,
      demo: demo,
      page: TransfersPage(
        demo: demo,
        journal: journal,
        pick: DemoPick.fromFileDialog,
      ),
    ),
  );
}

class _TransfersApp extends StatefulWidget {
  const _TransfersApp({
    required this.stack,
    required this.demo,
    required this.page,
  });

  final MpxStack stack;
  final TransfersDemo demo;
  final Widget page;

  @override
  State<_TransfersApp> createState() => _TransfersAppState();
}

class _TransfersAppState extends State<_TransfersApp> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  @override
  void dispose() {
    widget.demo.dispose();
    widget.demo.root.dispose();
    widget.stack.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigator,
    builder: (context, child) => TransfersQuitGuard(
      transfers: widget.demo.transfers,
      navigatorKey: _navigator,
      child: child!,
    ),
    home: AssetCacheProvider(scope: widget.stack.scope, child: widget.page),
  );
}
