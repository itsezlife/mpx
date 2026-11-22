import 'package:control/control.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/timeline_state.dart';
import 'package:mpx_example/social/src/feature/timeline/data/timeline_repository.dart';
import 'package:mpx_example/social/src/feature/timeline/model/topic.dart';

/// One topic's timeline: loads it, reads it again, and pages it as the
/// reader nears the end.
///
/// A call made while another runs is dropped, not queued: a reader who pulls
/// twice wants one refresh, and a scroll that asks for the next page twice
/// wants one page.
final class TimelineController extends StateController<TimelineState>
    with DroppableControllerHandler {
  TimelineController({
    required this.topic,
    required TimelineRepository repository,
  }) : _repository = repository,
       super(initialState: TimelineState.initial(data: TimelineStateEntity()));

  final Topic topic;
  final TimelineRepository _repository;

  /// Reads the first page; does nothing once it was read.
  void load() {
    if (state.data.loaded) return;
    handle(
      () async {
        setState(
          TimelineState.processing(
            data: state.data.copyWith(operation: TimelineOperation.load),
            message: 'Loading ${topic.id}',
          ),
        );
        final page = await _repository.page(topic);
        setState(
          TimelineState.idle(
            data: state.data.copyWith(
              posts: page.posts,
              next: page.next,
              loaded: true,
              exhausted: page.next == null,
              generation: state.data.generation + 1,
            ),
            message: 'Loaded ${page.posts.length} posts of ${topic.id}',
          ),
        );
      },
      error: (error, stackTrace) async {
        setState(
          TimelineState.failed(
            data: state.data,
            message: 'Failed to load ${topic.id}',
            error: error,
          ),
        );
      },
      name: 'load',
      meta: {'topic': topic.id},
    );
  }

  /// Reads the first page again. The posts stay on screen while it runs, and
  /// when it fails.
  Future<void> refresh() async {
    if (!state.data.loaded) return load();
    await handle(
      () async {
        setState(
          TimelineState.processing(
            data: state.data.copyWith(operation: TimelineOperation.refresh),
            message: 'Refreshing ${topic.id}',
          ),
        );
        final page = await _repository.page(topic);
        setState(
          TimelineState.idle(
            data: state.data.copyWith(
              posts: page.posts,
              next: page.next,
              exhausted: page.next == null,
              generation: state.data.generation + 1,
            ),
            message: 'Refreshed ${topic.id} to ${page.posts.length} posts',
          ),
        );
      },
      error: (error, stackTrace) async {
        setState(
          TimelineState.failed(
            data: state.data.copyWith(operation: TimelineOperation.refresh),
            message: 'Failed to refresh ${topic.id}',
            error: error,
          ),
        );
      },
      name: 'refresh',
      meta: {'topic': topic.id},
    );
  }

  /// Reads the page after the last one.
  void loadMore() {
    final data = state.data;
    if (!data.loaded || data.exhausted || data.posts.isEmpty) return;
    handle(
      () async {
        setState(
          TimelineState.processing(
            data: data.copyWith(operation: TimelineOperation.more),
            message: 'Loading more of ${topic.id}',
          ),
        );
        final page = await _repository.page(topic, cursor: data.next);
        final known = {for (final post in data.posts) post.id};
        setState(
          TimelineState.idle(
            data: state.data.copyWith(
              posts: [
                ...data.posts,
                for (final post in page.posts)
                  if (!known.contains(post.id)) post,
              ],
              next: page.next,
              exhausted: page.next == null,
            ),
            message: 'Loaded ${page.posts.length} more of ${topic.id}',
          ),
        );
      },
      error: (error, stackTrace) async {
        setState(
          TimelineState.failed(
            data: state.data.copyWith(operation: TimelineOperation.more),
            message: 'Failed to load more of ${topic.id}',
            error: error,
          ),
        );
      },
      name: 'loadMore',
      meta: {'topic': topic.id},
    );
  }
}
