import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mpx_example/social/src/feature/timeline/data/dto/mastodon_dto.dart';

/// Why a request to a server did not give statuses.
enum MastodonFailure {
  /// The device could not reach the server.
  offline,

  /// The server asked the client to slow down (300 requests in 5 minutes).
  rateLimited,

  /// The server answered with an error, or with something that is not
  /// statuses.
  server;

  /// The failure [error] stands for: the one a [MastodonException] carries,
  /// a server failure for anything else.
  static MastodonFailure of(Object? error) =>
      error is MastodonException ? error.failure : server;
}

/// A request that failed; [cause] is what was thrown.
final class MastodonException implements Exception {
  const MastodonException(this.failure, this.cause);

  final MastodonFailure failure;
  final Object cause;

  @override
  String toString() => 'MastodonException(${failure.name}: $cause)';
}

/// The signed-out part of the Mastodon API: lists of statuses from the
/// timelines a server shows anyone. No key and no account; the server's own
/// rate limit (300 requests per 5 minutes per address) applies.
final class MastodonClient {
  MastodonClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// How long a request may take.
  final Duration timeout;

  /// The statuses [path] of [host] lists under [query].
  Future<List<StatusDto>> statuses(
    String host,
    String path,
    Map<String, Object> query,
  ) async {
    final uri = Uri.https(host, path, {
      for (final MapEntry(:key, :value) in query.entries)
        key: value is Iterable ? value.map((e) => '$e').toList() : '$value',
    });
    final http.Response response;
    try {
      response = await _client
          .get(uri, headers: const {'accept': 'application/json'})
          .timeout(timeout);
    } on Object catch (error) {
      // A socket that does not open, a name that does not resolve and a
      // request that runs out of time are all "no way to reach it".
      if (error is SocketException ||
          error is TimeoutException ||
          error is http.ClientException) {
        throw MastodonException(MastodonFailure.offline, error);
      }
      rethrow;
    }
    if (response.statusCode == 429) {
      throw MastodonException(MastodonFailure.rateLimited, response.body);
    }
    if (response.statusCode != 200) {
      throw MastodonException(
        MastodonFailure.server,
        'HTTP ${response.statusCode} from $uri',
      );
    }
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      return [
        for (final item in body as List<Object?>)
          StatusDto.fromJson(item! as Map<String, Object?>),
      ];
    } on Object catch (error) {
      throw MastodonException(MastodonFailure.server, error);
    }
  }

  void close() => _client.close();
}
