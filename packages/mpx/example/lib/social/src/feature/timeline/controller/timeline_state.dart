import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';

/// What a timeline's phase narrates: the operation running, or the one that
/// failed.
enum TimelineOperation {
  /// The first page.
  load,

  /// The first page again, the posts shown meanwhile.
  refresh,

  /// The page after the last one.
  more,
}

/// Screen fields carried by every [TimelineState] variant.
class TimelineStateEntity extends Equatable {
  TimelineStateEntity({
    this.posts = const [],
    this.next,
    this.loaded = false,
    this.exhausted = false,
    this.operation = TimelineOperation.load,
    this.generation = 0,
  });

  /// The posts read so far, newest first.
  final List<Post> posts;

  /// Where the next page starts; null when the source has no more.
  final String? next;

  /// Whether the first page was read.
  final bool loaded;

  /// Whether the source has no more.
  final bool exhausted;

  /// The operation the phase narrates.
  final TimelineOperation operation;

  /// Counts the times the list was replaced, not extended: a surface that
  /// numbers items by position starts over when it changes.
  final int generation;

  // Each post's first item among all the posts' media, in list order: the
  // feed numbers its items that way, one per picture or clip.
  late final List<int> _first = () {
    var next = 0;
    return [
      for (final post in posts)
        () {
          final first = next;
          next += post.media.length;
          return first;
        }(),
    ];
  }();

  /// How many media the posts have in all: the feed's item count.
  int get mediaCount =>
      posts.isEmpty ? 0 : _first.last + posts.last.media.length;

  /// The feed index of the [media]th attachment of the [post]th post.
  int feedIndexOf(int post, int media) => _first[post] + media;

  /// The post and attachment the feed index [index] is.
  (int post, int media) mediaAt(int index) {
    var low = 0;
    var high = posts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_first[mid] <= index) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return (low, index - _first[low]);
  }

  TimelineStateEntity copyWith({
    List<Post>? posts,
    Object? next = _null,
    bool? loaded,
    bool? exhausted,
    TimelineOperation? operation,
    int? generation,
  }) => TimelineStateEntity(
    posts: posts ?? this.posts,
    next: next == _null ? this.next : next as String?,
    loaded: loaded ?? this.loaded,
    exhausted: exhausted ?? this.exhausted,
    operation: operation ?? this.operation,
    generation: generation ?? this.generation,
  );

  @override
  List<Object?> get props => [
    posts,
    next,
    loaded,
    exhausted,
    operation,
    generation,
  ];
}

const Object _null = {};

/// The phase of a timeline over its [TimelineStateEntity].
sealed class TimelineState extends _$TimelineStateBase {
  const TimelineState({
    required super.data,
    required super.message,
    super.error,
  });

  /// Idle
  const factory TimelineState.idle({
    required TimelineStateEntity data,
    String message,
    Object? error,
  }) = TimelineState$Idle;

  /// Processing
  const factory TimelineState.processing({
    required TimelineStateEntity data,
    String message,
    Object? error,
  }) = TimelineState$Processing;

  /// Failed
  const factory TimelineState.failed({
    required TimelineStateEntity data,
    String message,
    Object? error,
  }) = TimelineState$Failed;

  /// Initial
  factory TimelineState.initial({
    required TimelineStateEntity data,
    String? message,
    Object? error,
  }) => TimelineState$Idle(
    data: data,
    message: message ?? 'Initial',
    error: error,
  );
}

/// Idle
final class TimelineState$Idle extends TimelineState {
  const TimelineState$Idle({
    required super.data,
    super.message = 'Idle',
    super.error,
  });

  @override
  String get type => 'idle';
}

/// Processing
final class TimelineState$Processing extends TimelineState {
  const TimelineState$Processing({
    required super.data,
    super.message = 'Processing',
    super.error,
  });

  @override
  String get type => 'processing';
}

/// Failed
final class TimelineState$Failed extends TimelineState {
  const TimelineState$Failed({
    required super.data,
    super.message = 'Failed',
    super.error,
  });

  @override
  String get type => 'failed';
}

/// Pattern matching for [TimelineState].
typedef TimelineStateMatch<R, S extends TimelineState> = R Function(S element);

@immutable
abstract base class _$TimelineStateBase {
  const _$TimelineStateBase({
    required this.data,
    required this.message,
    this.error,
  });

  /// Type alias for [TimelineState].
  abstract final String type;

  /// Data entity payload.
  @nonVirtual
  final TimelineStateEntity data;

  /// Message or description.
  @nonVirtual
  final String message;

  /// Error object.
  @nonVirtual
  final Object? error;

  /// Whether the first page is yet to show: nothing read, nothing failed.
  bool get isLoadingFirst =>
      data.posts.isEmpty && (this is TimelineState$Processing || !data.loaded);

  /// Check if is Idle.
  bool get isIdle => this is TimelineState$Idle;

  /// Check if is Processing.
  bool get isProcessing => this is TimelineState$Processing;

  /// Check if is Failed.
  bool get isFailed => this is TimelineState$Failed;

  /// Pattern matching for [TimelineState].
  R map<R>({
    required TimelineStateMatch<R, TimelineState$Idle> idle,
    required TimelineStateMatch<R, TimelineState$Processing> processing,
    required TimelineStateMatch<R, TimelineState$Failed> failed,
  }) => switch (this) {
    TimelineState$Idle s => idle(s),
    TimelineState$Processing s => processing(s),
    TimelineState$Failed s => failed(s),
    _ => throw AssertionError(),
  };

  /// Pattern matching for [TimelineState].
  R maybeMap<R>({
    required R Function() orElse,
    TimelineStateMatch<R, TimelineState$Idle>? idle,
    TimelineStateMatch<R, TimelineState$Processing>? processing,
    TimelineStateMatch<R, TimelineState$Failed>? failed,
  }) => map<R>(
    idle: idle ?? (_) => orElse(),
    processing: processing ?? (_) => orElse(),
    failed: failed ?? (_) => orElse(),
  );

  /// Pattern matching for [TimelineState].
  R? mapOrNull<R>({
    TimelineStateMatch<R, TimelineState$Idle>? idle,
    TimelineStateMatch<R, TimelineState$Processing>? processing,
    TimelineStateMatch<R, TimelineState$Failed>? failed,
  }) => map<R?>(
    idle: idle ?? (_) => null,
    processing: processing ?? (_) => null,
    failed: failed ?? (_) => null,
  );

  @override
  int get hashCode => Object.hash(type, data);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _$TimelineStateBase &&
          type == other.type &&
          identical(data, other.data));

  @override
  String toString() => 'TimelineState.$type{message: $message}';
}
