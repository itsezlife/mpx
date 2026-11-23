import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/download_request.dart';

void main() {
  test('a clip that waited and is now fetched was asked for', () {
    final request = DownloadRequest();

    expect(request.see(const AssetTransfer.awaitingUser(100)), isFalse);
    expect(request.see(const AssetTransfer.waiting(100)), isTrue);
    expect(request.see(const AssetTransfer.receiving(10, 100)), isTrue);
    expect(request.see(AssetTransfer.none), isTrue);
  });

  test('a clip the policy fetches by itself was not asked for', () {
    final request = DownloadRequest();

    expect(request.see(const AssetTransfer.waiting(100)), isFalse);
    expect(request.see(const AssetTransfer.receiving(10, 100)), isFalse);
    expect(request.see(AssetTransfer.none), isFalse);
  });

  test('a download the reader cancelled is not asked for any more', () {
    final request = DownloadRequest();
    request
      ..see(const AssetTransfer.awaitingUser(100))
      ..see(const AssetTransfer.receiving(10, 100));

    expect(request.see(const AssetTransfer.awaitingUser(100, 10)), isFalse);
  });
}
