import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_example/social/src/common/media/post_media_facts.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';

PostMedia _media(PostMediaKind kind, String id) => PostMedia(
  key: MediaKey.external('m.example/media/$id'),
  kind: kind,
  byteSize: 20 * 1024 * 1024,
);

void main() {
  late FakeFetcher fetcher;

  setUp(() => fetcher = FakeFetcher());

  test('a clip the fetcher has all of is on the device, whatever its size', () {
    final clip = _media(PostMediaKind.video, '1');

    expect(PostMediaFacts.isOnDevice(clip, fetcher), isTrue);
    expect(PostMediaFacts.feedItem(clip, onDevice: true).local, isTrue);
  });

  test('a clip the fetcher still needs is not: it waits for the reader', () {
    final clip = _media(PostMediaKind.video, '2');
    fetcher.missing.add(clip.key);

    expect(PostMediaFacts.isOnDevice(clip, fetcher), isFalse);
  });

  test('a photo is never asked about: only clips play', () {
    final photo = _media(PostMediaKind.photo, '3');

    expect(PostMediaFacts.isOnDevice(photo, fetcher), isFalse);
  });
}
