import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/transfers/dev_server.dart';
import 'package:mpx_example/transfers/network_cut.dart';
import 'package:mpx_example/transfers/transfer_settings.dart';
import 'package:mpx_example/transfers/transfers_demo.dart';
import 'package:mpx_example/transfers/transfers_root.dart';

/// The transfer half of an example app's composition root, made before the
/// media stack: the settings kept across runs, the debug panel's network
/// cut, the development server, and what the stack takes from them (its
/// tracked factory, client middlewares, resolver and locations).
///
/// ```
/// final wiring = TransfersWiring.load(cacheDirectory: dir);
/// final stack = await MpxStack.create(
///   tracked: wiring.tracked(signals.network),
///   resolver: wiring.resolver,
///   client: HttpBytesClient(middlewares: wiring.middlewares),
///   locate: (d, part) => wiring.locationOf(d.key) ?? ...,
///   ...
/// );
/// final demo = wiring.demo(stack);
/// ```
final class TransfersWiring {
  TransfersWiring._(this.cacheDirectory, this.settings, this.cut)
    : hostClient = cut.client(http.Client()) {
    server = DevServer(settings.server, client: hostClient);
  }

  /// Reads the settings beside [cacheDirectory] (the bytes cache's folder;
  /// null on the web, where they are in the page's storage).
  factory TransfersWiring.load({required String? cacheDirectory}) =>
      TransfersWiring._(
        cacheDirectory,
        TransferSettings.load(
          cacheDirectory == null
              ? 'mpx_example.transfer_settings'
              : '$cacheDirectory/transfer_settings.json',
        ),
        NetworkCut(),
      );

  /// The bytes cache's folder; the transfer journal sits below it.
  final String? cacheDirectory;

  /// The demo's settings.
  final TransferSettings settings;

  /// The debug panel's network cut.
  final NetworkCut cut;

  /// The host's own calls to the server, cut with the rest.
  final http.Client hostClient;

  /// The development server, at the settings' address.
  late final DevServer server;

  /// The transfer side, once the stack's [tracked] factory ran.
  TransfersRoot get root =>
      _root ?? (throw StateError('The media stack has not been created.'));
  TransfersRoot? _root;

  /// The stack's tracked factory: opens the transfer engine over the
  /// stack's fetcher and store, fed connectivity from [network].
  MpxTrackedFactory tracked(ValueListenable<NetworkClass> network) =>
      (context) async {
        final root = _root = await TransfersRoot.open(
          context: context,
          server: server,
          settings: settings,
          cut: cut,
          hostClient: hostClient,
          network: network,
          directory: cacheDirectory,
        );
        return root.transfers.tracked;
      };

  /// What the server's files are, for keys no one told the pipeline about
  /// (a tracked download resumed at start).
  late final MediaResolver resolver = DevServerResolver(server);

  /// The stack client's middlewares: the network cut outermost, so the
  /// transfer engine's parts fail with the rest.
  List<HttpBytesMiddleware> get middlewares => [
    cut.middleware,
    const HttpBytesTimeoutMiddleware().call,
  ];

  /// Where the server serves [key], or null for a key of no server file.
  MediaLocation? locationOf(MediaKey key) => switch (server.locationOf(key)) {
    final url? => MediaLocation('$url'),
    null => null,
  };

  /// The demo's headless side over [stack]: a picked file's bytes go into
  /// the stack's store under its local key, so its cell shows it before
  /// any upload; the server key is aliased to them after.
  TransfersDemo demo(MpxStack stack) => TransfersDemo(
    root: root,
    keepLocal: (key, pick) => CaptureCache(store: stack.store).put(
      key,
      CaptureOutput(
        path: pick.path,
        size: pick.size,
        duration: Duration.zero,
        dimensions: const MediaDimensions(1, 1),
        headerRewritten: false,
      ),
      deleteSource: false,
    ),
    know: stack.pipeline.know,
  );
}
