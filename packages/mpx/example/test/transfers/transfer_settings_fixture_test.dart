/// The demo's stored settings, pinned: a file a previous run wrote is read
/// back, and the settings are written as the same bytes.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_example/transfers/transfer_settings.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

// Written by the encoder before it became a codec.
const _stored =
    '{"server":"http://10.0.0.2:8090","submitAt":"onResignActive",'
    '"startRule":"always","transport":"numberedParts"}';
const _defaults =
    '{"server":"http://10.0.0.2:8090","submitAt":"afterDelay",'
    '"startRule":null,"transport":"tus"}';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('settings'));
  tearDown(() => directory.deleteSync(recursive: true));

  test('a stored file reads back and is written as the same bytes', () {
    final file = File('${directory.path}/settings.json')
      ..writeAsStringSync(_stored);

    final settings = TransferSettings.load(file.path);
    expect(settings.server, Uri.parse('http://10.0.0.2:8090'));
    expect(settings.submitAt, isA<TransferEnvelopeSubmitAt$OnResignActive>());
    expect(settings.startRule, TransferEnvelopeStartRule.always);
    expect(settings.transport, DemoTransport.numberedParts);

    settings.transport = DemoTransport.numberedParts;
    expect(file.readAsStringSync(), _stored);
  });

  test('a file with no rule and the default send reads back the same', () {
    final file = File('${directory.path}/settings.json')
      ..writeAsStringSync(_defaults);

    final settings = TransferSettings.load(file.path);
    expect(settings.submitAt, isA<TransferEnvelopeSubmitAt$AfterDelay>());
    expect(settings.startRule, isNull);
    expect(settings.transport, DemoTransport.tus);

    settings.startRule = null;
    expect(file.readAsStringSync(), _defaults);
  });

  test('no file reads as the defaults', () {
    final settings = TransferSettings.load('${directory.path}/none.json');
    expect(settings.server, TransferSettings.defaultServer);
    expect(settings.transport, DemoTransport.tus);
    expect(settings.startRule, isNull);
  });

  test('a value of the wrong kind fails naming its key', () {
    expect(
      () => const TransferSettingsCodec().decode({'transport': 'carrier'}),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('transport'),
        ),
      ),
    );
    expect(
      () => const TransferSettingsCodec().decode({'server': 3}),
      throwsFormatException,
    );
    expect(
      () => const TransferSettingsCodec().decode({'server': 'no-host'}),
      throwsFormatException,
    );
  });

  test('an unreadable file reads as the defaults', () {
    final file = File('${directory.path}/settings.json')
      ..writeAsStringSync('{"transport": 7');
    expect(TransferSettings.load(file.path).transport, DemoTransport.tus);
  });
}
