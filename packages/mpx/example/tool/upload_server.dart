// The example's development upload server, for the transfers demo and the
// device checks: run it on a computer on the same network as the device.
//
//   dart run tool/upload_server.dart [--port 8090] [--dir upload_server_files]
//       [--upload ok|fail] [--publish ok|reject|rejectRetryable|reupload]
//       [--rate <KiB/s>]
//
// It prints the addresses to enter in the demo's settings. While it runs,
// type a command and Enter: `upload ok|fail`, `publish <mode>`,
// `rate <KiB/s>` (0 for none), `files`, `publishes`, `status`, `quit`. The
// demo's debug panel switches the same modes over `GET /control`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'upload_server/dev_upload_server.dart';

Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  for (var i = 0; i + 1 < arguments.length; i += 2) {
    options[arguments[i].replaceFirst(RegExp('^--'), '')] = arguments[i + 1];
  }
  final server = await DevUploadServer.start(
    directory: Directory(options['dir'] ?? 'upload_server_files'),
    port: int.tryParse(options['port'] ?? '') ?? 8090,
    log: stdout.writeln,
  );
  server.control(options);
  stdout.writeln(
    'Upload server on port ${server.port}, files in '
    '${server.directory.absolute.path}',
  );
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    for (final address in interface.addresses) {
      stdout.writeln('  http://${address.address}:${server.port}');
    }
  }
  stdout.writeln('Modes: ${jsonEncode(server.modes)}');

  final done = Completer<void>();
  final input = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        final words = line.trim().split(RegExp(r'\s+'));
        switch (words) {
          case ['quit' || 'exit']:
            if (!done.isCompleted) done.complete();
          case ['files']:
            for (final file in server.files.values) {
              stdout.writeln(jsonEncode(file.toJson()));
            }
          case ['publishes']:
            stdout.writeln(jsonEncode(server.publishes));
          case ['upload' || 'publish' || 'rate', final value]:
            server.control({words.first: value});
            stdout.writeln('Modes: ${jsonEncode(server.modes)}');
          default:
            stdout.writeln('Modes: ${jsonEncode(server.modes)}');
        }
      });
  await done.future;
  await input.cancel();
  await server.close();
}
