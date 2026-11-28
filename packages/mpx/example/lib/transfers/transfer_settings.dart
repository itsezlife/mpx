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
  TransferSettings._(this._path, TransferSettingsValues values)
    : _server = values.server,
      _submitAt = values.submitAt,
      _startRule = values.startRule,
      _transport = values.transport;

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
    var values = TransferSettingsCodec.defaults;
    try {
      final text = environment_specific.$readText(path);
      if (text != null) {
        values = switch (jsonDecode(text)) {
          final Map<String, Object?> json =>
            const TransferSettingsCodec().decode(json),
          final other => throw FormatException(
            'Expected an object, found ${other.runtimeType}.',
          ),
        };
      }
    } on Object catch (error) {
      // A file the demo cannot read (or one of another format) costs the
      // kept settings, never the start: the defaults apply and say so.
      debugPrint('The transfer settings did not read ($error); defaults.');
    }
    return TransferSettings._(path, values);
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
          jsonEncode(
            const TransferSettingsCodec().encode((
              server: _server,
              submitAt: _submitAt,
              startRule: _startRule,
              transport: _transport,
            )),
          ),
        );
      } on Object catch (error) {
        debugPrint('The transfer settings did not save ($error).');
      }
    }
    notifyListeners();
  }
}

/// The settings as they are kept.
typedef TransferSettingsValues = ({
  Uri server,
  TransferEnvelopeSubmitAt submitAt,
  TransferEnvelopeStartRule? startRule,
  DemoTransport transport,
});

/// [TransferSettingsValues] to and from the JSON object of the settings
/// file.
///
/// ## Fields
///
/// | Key | Value |
/// |---|---|
/// | `server` | the upload server's URL, with an authority |
/// | `submitAt` | `TransferEnvelopeSubmitAt.name`: `afterDelay`, `onResignActive` |
/// | `startRule` | `TransferEnvelopeStartRule` name, or null for the platform's |
/// | `transport` | [DemoTransport] name |
///
/// Every key is written, in that order. A missing key (or null) reads as
/// its default ([defaults]); a value of the wrong type, an unknown name or
/// a server with no authority fails with a [FormatException] naming the
/// key.
final class TransferSettingsCodec
    extends Codec<TransferSettingsValues, Map<String, Object?>> {
  /// The codec.
  const TransferSettingsCodec();

  /// What a key that is not kept reads as.
  static TransferSettingsValues get defaults => (
    server: TransferSettings.defaultServer,
    submitAt: const TransferEnvelopeSubmitAt.afterDelay(),
    startRule: null,
    transport: DemoTransport.tus,
  );

  @override
  Converter<TransferSettingsValues, Map<String, Object?>> get encoder =>
      const _SettingsEncoder();

  @override
  Converter<Map<String, Object?>, TransferSettingsValues> get decoder =>
      const _SettingsDecoder();
}

/// Keys of the settings file, shared by both directions.
abstract final class _Key {
  static const String server = 'server';
  static const String submitAt = 'submitAt';
  static const String startRule = 'startRule';
  static const String transport = 'transport';
}

final class _SettingsEncoder
    extends Converter<TransferSettingsValues, Map<String, Object?>> {
  const _SettingsEncoder();

  @override
  Map<String, Object?> convert(TransferSettingsValues input) => {
    _Key.server: '${input.server}',
    _Key.submitAt: input.submitAt.name,
    _Key.startRule: input.startRule?.name,
    _Key.transport: input.transport.name,
  };
}

final class _SettingsDecoder
    extends Converter<Map<String, Object?>, TransferSettingsValues> {
  const _SettingsDecoder();

  @override
  TransferSettingsValues convert(Map<String, Object?> input) {
    String? text(String key) => switch (input[key]) {
      null => null,
      final String value => value,
      final other => throw FormatException(
        'Expected a string under "$key", found ${other.runtimeType}.',
        input,
      ),
    };
    T? byName<T extends Enum>(List<T> values, String key) =>
        switch (text(key)) {
          null => null,
          final name =>
            values.asNameMap()[name] ??
                (throw FormatException('Unknown $key "$name".', input)),
        };

    final defaults = TransferSettingsCodec.defaults;
    return (
      server: switch (text(_Key.server)) {
        null => defaults.server,
        final value => switch (Uri.tryParse(value)) {
          final uri? when uri.hasAuthority => uri,
          _ => throw FormatException(
            'No server under "${_Key.server}".',
            input,
          ),
        },
      },
      submitAt: switch (text(_Key.submitAt)) {
        null || 'afterDelay' => defaults.submitAt,
        'onResignActive' => const TransferEnvelopeSubmitAt.onResignActive(),
        final other => throw FormatException(
          'Unknown ${_Key.submitAt} "$other".',
          input,
        ),
      },
      startRule: byName(TransferEnvelopeStartRule.values, _Key.startRule),
      transport:
          byName(DemoTransport.values, _Key.transport) ?? defaults.transport,
    );
  }
}
