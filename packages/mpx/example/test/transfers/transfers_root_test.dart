import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_example/transfers/dev_server.dart';
import 'package:mpx_example/transfers/network_cut.dart';
import 'package:mpx_example/transfers/transfer_settings.dart';
import 'package:mpx_example/transfers/transfers_root.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

void main() {
  test('the settings outlive the run: saved on each change, read at the '
      'next start', () {
    final folder = Directory.systemTemp.createTempSync('mpx_settings_');
    addTearDown(() => folder.deleteSync(recursive: true));
    final path = '${folder.path}/transfer_settings.json';

    final first = TransferSettings.load(path);
    expect(first.server, TransferSettings.defaultServer);
    expect(first.submitAt, const TransferEnvelopeSubmitAt.afterDelay());
    expect(first.startRule, isNull);
    expect(first.transport, DemoTransport.tus);
    first
      ..server = Uri.parse('http://192.168.1.20:8090')
      ..submitAt = const TransferEnvelopeSubmitAt.onResignActive()
      ..startRule = TransferEnvelopeStartRule.always
      ..transport = DemoTransport.numberedParts;

    final next = TransferSettings.load(path);
    expect(next.server, Uri.parse('http://192.168.1.20:8090'));
    expect(next.submitAt, const TransferEnvelopeSubmitAt.onResignActive());
    expect(next.startRule, TransferEnvelopeStartRule.always);
    expect(next.transport, DemoTransport.numberedParts);
  });

  test('the envelope config carries the strings, the icon and the '
      'settings\' rule and submission time', () {
    final settings = TransferSettings.memory()
      ..startRule = TransferEnvelopeStartRule.never
      ..submitAt = const TransferEnvelopeSubmitAt.onResignActive();

    final config = TransfersRoot.envelopeConfig(settings);

    expect(config.title, 'Sending media');
    expect(config.text, isNotNull);
    expect(config.cancelAllLabel, 'Cancel all');
    expect(config.icon, 'ic_stat_transfer');
    expect(config.startRule, TransferEnvelopeStartRule.never);
    expect(config.submitAt, const TransferEnvelopeSubmitAt.onResignActive());
    expect(
      config.progressText!(
        const TransferEnvelopeProgress(jobs: {}, done: 0, total: 0),
      ),
      '0 uploads left',
    );
  });

  test('the network cut fails the bytes client and the host client while '
      'on, and lets them through when off', () async {
    final cut = NetworkCut();
    final host = cut.client(MockClient((_) async => http.Response('ok', 200)));
    final bytes = HttpBytesClient(
      client: MockClient((_) async => http.Response('ok', 200)),
      middlewares: [cut.middleware],
    );
    addTearDown(bytes.close);
    final url = Uri.parse('http://server.test/x');

    expect((await host.get(url)).statusCode, 200);
    cut.value = true;
    await expectLater(host.get(url), throwsA(isA<http.ClientException>()));
    await expectLater(bytes.getBytes(url), throwsA(anything));
    cut.value = false;
    expect((await host.get(url)).statusCode, 200);
  });

  testWidgets('the engine is told the connectivity of the device\'s network '
      'signal, and offline while the network is cut', (tester) async {
    final recorder = RecordingDiagnostics.install();
    final harness = await UploadsHarness.open(
      lifecycle: ManualPlaybackLifecycleSource(),
      transports: [FakeUploadTransport()],
    );
    final network = ValueNotifier(NetworkClass.unmetered);
    final cut = NetworkCut();
    final root = TransfersRoot(
      transfers: harness.transfers,
      server: DevServer(
        Uri.parse('http://server.test'),
        client: MockClient((_) async => http.Response('[]', 200)),
      ),
      settings: TransferSettings.memory(),
      cut: cut,
      network: network,
    );
    addTearDown(root.dispose);

    network.value = NetworkClass.none;
    network.value = NetworkClass.metered;
    cut.value = true;
    network.value = NetworkClass.none; // still offline: no second event
    cut.value = false; // still offline: the device has no network
    network.value = NetworkClass.unmetered;

    expect(
      [
        for (final event in recorder.whereOp(SchedulerOp.connectivityChanged))
          event.fields['online'],
      ],
      [false, true, false, true],
    );
    await harness.transfers.dispose();
  });
}
