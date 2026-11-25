import 'package:flutter/widgets.dart'
    show BuildContext, InheritedWidget, Widget;
import 'package:mpx/mpx.dart';
import 'package:mpx_example/social/src/common/media/media_origins.dart';
import 'package:mpx_example/social/src/feature/initialization/initialization_context.dart'
    show InitializationContext;
import 'package:mpx_example/social/src/feature/initialization/initialization_metrics.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/inline_sound.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/sound_requests.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/volume_rise.dart';
import 'package:mpx_example/social/src/feature/timeline/data/mastodon_client.dart';
import 'package:mpx_example/social/src/feature/timeline/data/timeline_repository.dart';
import 'package:mpx_player/mpx_player.dart';

/// Runtime dependencies available to the running app.
///
/// Filled step by step by `$initializeDependencies`, in the order of its
/// steps; the fields are read only after it returns. Transient objects used
/// only during composition live on [InitializationContext], not here.
class Dependencies {
  /// Creates an empty dependencies container.
  Dependencies();

  /// The dependencies from the closest [InheritedDependencies].
  factory Dependencies.of(BuildContext context) =>
      InheritedDependencies.of(context);

  /// Inject the dependencies into the widget tree.
  Widget inject(Widget child) =>
      InheritedDependencies(dependencies: this, child: child);

  /// Step timings of the initialization run that produced this container.
  late final InitializationMetrics initializationMetrics;

  /// Where each media key lives; the data layer fills it as posts arrive,
  /// and the stack's fetcher and the players read it.
  late final MediaOrigins origins;

  /// The signed-out Mastodon API.
  late final MastodonClient mastodonClient;

  /// The asset cache, its pipeline, the bytes store and the device's
  /// signals.
  late final MpxStack stack;

  /// The device's network, power and heat as the feed weighs them.
  late final FeedSignals feedSignals;

  /// The platform player over the stack's cache, or null where the build has
  /// no native reader: the viewer and the reels then show stills.
  late final PlayerPool? players;

  /// The reader's sound switch for the lists of posts, shared by all of them.
  late final InlineSound inlineSound;

  /// The reader asking for sound: every surface that plays video listens.
  late final SoundRequests soundRequests;

  /// What the system volume going up asks of them.
  late final VolumeRise volumeRise;

  /// Where a topic's posts are read from.
  late final TimelineRepository timelineRepository;
}

/// {@template inherited_dependencies}
/// InheritedDependencies widget.
/// {@endtemplate}
class InheritedDependencies extends InheritedWidget {
  /// {@macro inherited_dependencies}
  const InheritedDependencies({
    required this.dependencies,
    required super.child,
    super.key,
  });

  final Dependencies dependencies;

  /// The dependencies from the closest instance of this class that encloses
  /// the given context, if any.
  static Dependencies? maybeOf(BuildContext context) =>
      (context
                  .getElementForInheritedWidgetOfExactType<
                    InheritedDependencies
                  >()
                  ?.widget
              as InheritedDependencies?)
          ?.dependencies;

  static Never _notFoundInheritedWidgetOfExactType() => throw ArgumentError(
    'Out of scope, not found inherited widget '
        'a InheritedDependencies of the exact type',
    'out_of_scope',
  );

  /// The dependencies from the closest instance of this class that encloses
  /// the given context.
  static Dependencies of(BuildContext context) =>
      maybeOf(context) ?? _notFoundInheritedWidgetOfExactType();

  // The container is fixed for the session: nothing below ever has to
  // rebuild because of it.
  @override
  bool updateShouldNotify(InheritedDependencies oldWidget) => false;
}
