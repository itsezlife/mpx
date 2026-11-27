import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mpx_example/transfers/environment_specific/transfers_host.dart'
    as environment_specific;
import 'package:mpx_transfer/mpx_transfer.dart';

/// Which upload protocol the demo sends through.
enum DemoTransport {
  multipart('multipart', 'Multipart'),
  tus('tus', 'tus'),
  numberedParts('numberedParts', 'Numbered parts');

  const DemoTransport(this.id, this.label);

  /// The transport's id, as `PublishRequest.transport` names it.
  final String id;

  /// What the demo calls it.
  final String label;
}

/// The demo's settings, kept across runs (a file beside the cache on the
/// VM, the page's local storage on the web), so a job resumed after a kill
/// reaches the same server and the envelope is configured as the check
/// needs it from the start.
///
/// [server] and the envelope's [submitAt] and [startRule] are read when the
/// transfer engine opens: a change applies at the next start.
final class TransferSettings extends ChangeNotifier {
  TransferSettings._(this._path, Map<String, Object?> json)
    : _server = _serverOf(json['server']),
      _submitAt = json['submitAt'] == 'onResignActive'
          ? const TransferEnvelopeSubmitAt.onResignActive()
          : const TransferEnvelopeSubmitAt.afterDelay(),
      _startRule = TransferEnvelopeStartRule.values
          .asNameMap()[json['startRule']],
      _transport =
          DemoTransport.values.asNameMap()[json['transport']] ??
          DemoTransport.tus;

  /// Settings in memory only, as a test or a page without storage has them.
  TransferSettings.memory({Uri? server})
    : _path = null,
      _server = server ?? defaultServer,
      _submitAt = const TransferEnvelopeSubmitAt.afterDelay(),
      _startRule = null,
      _transport = DemoTransport.tus;

  /// Reads the settings kept at [path] (a file on the VM, a storage key on
  /// the web); the defaults where none were kept.
  factory TransferSettings.load(String path) {
    var json = const <String, Object?>{};
    try {
      final text = environment_specific.$readText(path);
      if (text != null) {
        json = (jsonDecode(text) as Map<String, Object?>?) ?? const {};
      }
    } on Object catch (error) {
      debugPrint('The transfer settings did not read ($error); defaults.');
    }
    return TransferSettings._(path, json);
  }

  /// The upload server when none was set: `--dart-define=MPX_UPLOAD_SERVER`,
  /// else the page's own host on the web and the loopback elsewhere, port
  /// 8090 (`tool/upload_server.dart`).
  static Uri get defaultServer {
    const defined = String.fromEnvironment('MPX_UPLOAD_SERVER');
    if (defined.isNotEmpty) return Uri.parse(defined);
    final host = kIsWeb && Uri.base.host.isNotEmpty
        ? Uri.base.host
        : 'localhost';
    return Uri(scheme: 'http', host: host, port: 8090);
  }

  static Uri _serverOf(Object? value) => switch (value) {
    final String text when Uri.tryParse(text)?.hasAuthority ?? false =>
      Uri.parse(text),
    _ => defaultServer,
  };

  final String? _path;

  /// The upload server's base URL.
  Uri get server => _server;
  Uri _server;
  set server(Uri value) => _set(() => _server = value);

  /// When the iOS continued-processing task is asked for.
  TransferEnvelopeSubmitAt get submitAt => _submitAt;
  TransferEnvelopeSubmitAt _submitAt;
  set submitAt(TransferEnvelopeSubmitAt value) => _set(() => _submitAt = value);

  /// The host's say over when the envelope starts; null for the platform's.
  TransferEnvelopeStartRule? get startRule => _startRule;
  TransferEnvelopeStartRule? _startRule;
  set startRule(TransferEnvelopeStartRule? value) =>
      _set(() => _startRule = value);

  /// The protocol new sends go through.
  DemoTransport get transport => _transport;
  DemoTransport _transport;
  set transport(DemoTransport value) => _set(() => _transport = value);

  void _set(void Function() change) {
    change();
    final path = _path;
    if (path != null) {
      try {
        environment_specific.$writeText(
          path,
          jsonEncode({
            'server': '$_server',
            'submitAt': _submitAt.name,
            'startRule': _startRule?.name,
            'transport': _transport.name,
          }),
        );
      } on Object catch (error) {
        debugPrint('The transfer settings did not save ($error).');
      }
    }
    notifyListeners();
  }
}
