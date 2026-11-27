import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

void main() {
  group('TransferId.forDownload', () {
    test('is the same for the same cache key, in every run', () {
      expect(
        TransferId.forDownload('https://cdn.example/a.jpg'),
        TransferId.forDownload('https://cdn.example/a.jpg'),
      );
      // Pinned: a restart derives the id from the same key, so the value
      // must not change between releases either.
      expect(TransferId.forDownload('k'), 'd-8254c329a92850f6d539dd376f4816ee');
    });

    test('differs between keys', () {
      expect(TransferId.forDownload('a'), isNot(TransferId.forDownload('b')));
    });

    test('carries nothing of the key', () {
      final id = TransferId.forDownload('https://cdn.example/private.jpg');
      expect(id, isNot(contains('cdn')));
      expect(id, isNot(contains('private')));
    });
  });

  test('TransferId.issue gives a new id each time', () {
    final ids = {for (var i = 0; i < 1000; i++) TransferId.issue()};
    expect(ids, hasLength(1000));
  });

  group('Transfers', () {
    test('a second download of a key returns the job it already has', () async {
      final h = harness();
      final first = h.addDownload(photo, tag: 'first');
      final second = h.addDownload(photo, tag: 'second');

      expect(second, first);
      final jobs = await jobsOf(h.transfers);
      expect(jobs, hasLength(1));
      expect(jobs.single.tag, 'first');
      expect(h.runner.starts, hasLength(1));
    });

    test('derives a download id from the cache key cacheKeyOf gives', () async {
      final h = harness();
      final id = h.addDownload(photo);
      expect(id, TransferId.forDownload(h.cacheKeyOf(photo)));
    });

    test('keys with one cache key share a download job', () {
      final h = TransfersHarness(
        lifecycle: harness().lifecycle,
        cacheKeyOf: (_) => 'one',
      );
      addTearDown(h.transfers.dispose);
      expect(h.addDownload(photo), h.addDownload(video));
    });

    test('gives every upload a new id, also for the same tag', () async {
      final h = harness();
      final a = h.addUpload(tag: 'same');
      final b = h.addUpload(tag: 'same');

      expect(a, isNot(b));
      expect(await jobsOf(h.transfers), hasLength(2));
    });

    test('carries the host tag as given', () async {
      final h = harness();
      h.addUpload(tag: 'chat:1:abc');
      expect((await jobsOf(h.transfers)).single.tag, 'chat:1:abc');
    });

    test('carries the durability of every job', () async {
      final h = harness();
      h
        ..addUpload()
        ..addDownload(photo)
        ..addDownload(video, durability: TransferDurability.system);
      expect(
        [for (final job in await jobsOf(h.transfers)) job.durability],
        [
          TransferDurability.system,
          TransferDurability.inProcess,
          TransferDurability.system,
        ],
      );
    });

    test('a download keeps its key; an upload has none', () async {
      final h = harness();
      h
        ..addDownload(photo)
        ..addUpload();
      final jobs = await jobsOf(h.transfers);
      expect(jobs.first.key, photo);
      expect(jobs.last.key, isNull);
      expect(jobs.first.key, isA<MediaKey>());
    });
  });
}
