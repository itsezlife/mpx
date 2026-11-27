import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

void main() {
  UploadTransportContract.run(
    'FakeUploadTransport',
    transport: FakeUploadTransport.new,
  );

  UploadTransportContract.run(
    'FakeUploadTransport, one part at a time, no resume',
    transport: () => FakeUploadTransport(
      capabilities: UploadCapabilities(
        partSize: (_) => 1000,
        reuse: const UploadReuse.lifetime(Duration.zero),
      ),
    ),
  );

  test('a RemoteRef with attributes reads back from the journal', () {
    final ref = RemoteRef('file-1', attributes: const {'url': 'https://h/f'});
    expect(RemoteRef.codec.decode(RemoteRef.codec.encode(ref)!), ref);
    expect(ref.toString(), isNot(contains('https')));
  });
}
