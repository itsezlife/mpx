import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/timeline_controller.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/timeline_state.dart';
import 'package:mpx_example/social/src/feature/timeline/data/mastodon_client.dart';
import 'package:mpx_example/social/src/feature/timeline/model/topic.dart';

import 'support/fake_timeline_repository.dart';

void main() {
  late FakeTimelineRepository repository;
  late TimelineController controller;

  setUp(() {
    repository = FakeTimelineRepository();
    controller = TimelineController(
      topic: Topic.home.first,
      repository: repository,
    );
  });

  tearDown(() => controller.dispose());

  Future<void> settle() => pumpEventQueue();

  test('starts on the first page, not yet read', () {
    expect(controller.state, isA<TimelineState$Idle>());
    expect(controller.state.data.loaded, isFalse);
    expect(controller.state.isLoadingFirst, isTrue);
  });

  test('load reads the first page once', () async {
    repository.answers.add(
      TimelinePage(
        posts: [
          FakeTimelineRepository.post('2'),
          FakeTimelineRepository.post('1', mediaCount: 3),
        ],
        next: '1',
      ),
    );
    final seen = <String>[];
    controller.addListener(() => seen.add(controller.state.type));

    controller
      ..load()
      ..load();
    await settle();

    expect(seen, ['processing', 'idle']);
    expect(repository.cursors, [null]);
    final data = controller.state.data;
    expect(data.posts.map((p) => p.id), ['2', '1']);
    expect(data.loaded, isTrue);
    expect(data.exhausted, isFalse);
    // One feed item per media: 1 + 3.
    expect(data.mediaCount, 4);
    expect(data.feedIndexOf(1, 0), 1);
    expect(data.mediaAt(0), (0, 0));
    expect(data.mediaAt(3), (1, 2));

    // Once read, load does nothing.
    controller.load();
    await settle();
    expect(repository.cursors, [null]);
  });

  test('a failed first read says why and can be tried again', () async {
    repository.answers.add(MastodonFailure.offline);
    controller.load();
    await settle();

    expect(controller.state, isA<TimelineState$Failed>());
    expect(MastodonFailure.of(controller.state.error), MastodonFailure.offline);
    expect(controller.state.data.posts, isEmpty);

    repository.answers.add(
      TimelinePage(posts: [FakeTimelineRepository.post('1')], next: null),
    );
    controller.load();
    await settle();
    expect(controller.state, isA<TimelineState$Idle>());
    expect(controller.state.data.exhausted, isTrue);
  });

  test(
    'loadMore appends the next page from the cursor, without repeats',
    () async {
      repository.answers
        ..add(
          TimelinePage(posts: [FakeTimelineRepository.post('2')], next: '2'),
        )
        ..add(
          TimelinePage(
            posts: [
              FakeTimelineRepository.post('2'),
              FakeTimelineRepository.post('1'),
            ],
            next: null,
          ),
        );
      controller.load();
      await settle();
      controller.loadMore();
      await settle();

      expect(repository.cursors, [null, '2']);
      expect(controller.state.data.posts.map((p) => p.id), ['2', '1']);
      expect(controller.state.data.exhausted, isTrue);

      // Nothing more to read.
      controller.loadMore();
      await settle();
      expect(repository.cursors, hasLength(2));
    },
  );

  test('a call made while another runs is dropped', () async {
    repository
      ..gate = Completer<void>()
      ..answers.add(
        TimelinePage(posts: [FakeTimelineRepository.post('1')], next: '1'),
      );
    controller
      ..load()
      ..load();
    await settle();
    repository.gate!.complete();
    await settle();

    expect(repository.cursors, hasLength(1));
  });

  test('refresh replaces the list and counts a new generation', () async {
    repository.answers.add(
      TimelinePage(posts: [FakeTimelineRepository.post('1')], next: null),
    );
    controller.load();
    await settle();
    final first = controller.state.data.generation;

    repository.answers.add(
      TimelinePage(
        posts: [
          FakeTimelineRepository.post('3'),
          FakeTimelineRepository.post('2'),
        ],
        next: '2',
      ),
    );
    await controller.refresh();

    expect(controller.state.data.posts.map((p) => p.id), ['3', '2']);
    expect(controller.state.data.generation, first + 1);
    expect(controller.state.data.exhausted, isFalse);
  });

  test('a failed refresh keeps the posts on screen', () async {
    repository.answers.add(
      TimelinePage(posts: [FakeTimelineRepository.post('1')], next: null),
    );
    controller.load();
    await settle();

    repository.answers.add(MastodonFailure.rateLimited);
    await controller.refresh();

    expect(controller.state, isA<TimelineState$Failed>());
    expect(controller.state.data.operation, TimelineOperation.refresh);
    expect(controller.state.data.posts.map((p) => p.id), ['1']);
    expect(controller.state.isLoadingFirst, isFalse);
  });

  test('a failed next page can be read again', () async {
    repository.answers
      ..add(TimelinePage(posts: [FakeTimelineRepository.post('2')], next: '2'))
      ..add(MastodonFailure.server)
      ..add(
        TimelinePage(posts: [FakeTimelineRepository.post('1')], next: null),
      );
    controller.load();
    await settle();
    controller.loadMore();
    await settle();
    expect(controller.state, isA<TimelineState$Failed>());
    expect(controller.state.data.operation, TimelineOperation.more);

    controller.loadMore();
    await settle();
    expect(controller.state.data.posts.map((p) => p.id), ['2', '1']);
  });
}
