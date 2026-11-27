import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_bytes_cache/http_bytes_cache.dart';

/// The debug panel's switch that cuts the app's network: while [value] is
/// true every request through [middleware] (the bytes cache's client, which
/// the transfer engine sends its parts through) and through [client] (the
/// host's own calls to its server) fails as a dropped connection would.
///
/// The device keeps its network; only this app's requests fail, so a check
/// can cut the network in the middle of a transfer and give it back.
final class NetworkCut extends ValueNotifier<bool> {
  NetworkCut() : super(false);

  /// Fails every request while the network is cut.
  HttpBytesMiddleware get middleware =>
      (inner) => (request, context) {
        if (value) throw http.ClientException('network cut (debug panel)');
        return inner(request, context);
      };

  /// [inner], failing every request while the network is cut.
  http.Client client(http.Client inner) => _CutClient(inner, this);
}

final class _CutClient extends http.BaseClient {
  _CutClient(this._inner, this._cut);

  final http.Client _inner;
  final NetworkCut _cut;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_cut.value) {
      throw http.ClientException('network cut (debug panel)', request.url);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
