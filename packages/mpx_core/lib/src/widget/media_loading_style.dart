import 'package:flutter/material.dart';
import 'package:mpx_core/src/widget/media_badge_style.dart';
import 'package:mpx_core/src/widget/media_status_control.dart';
import 'package:mpx_core/src/widget/media_status_style.dart';

/// The look and motion of what surfaces draw while media loads, as pure
/// values: the status control ([status]) and the badge ([badge]).
///
/// [$Android], [$IOS] and [$Desktop] are each platform's reference;
/// [forPlatform] picks one, and `MediaLoadingStyleScope` lets a host adjust
/// it with [copyWith] (its theme's colours and text, say) or replace it.
@immutable
final class MediaLoadingStyle {
  /// Creates a style.
  const MediaLoadingStyle({required this.status, required this.badge});

  /// The status control (`MediaStatusControl`).
  final MediaStatusStyle status;

  /// The duration and size label (`MediaBadge`).
  final MediaBadgeStyle badge;

  /// The Android reference.
  static const MediaLoadingStyle $Android = MediaLoadingStyle(
    status: MediaStatusStyle.$Android,
    badge: MediaBadgeStyle.$Android,
  );

  /// The iOS reference.
  static const MediaLoadingStyle $IOS = MediaLoadingStyle(
    status: MediaStatusStyle.$IOS,
    badge: MediaBadgeStyle.$IOS,
  );

  /// The desktop reference.
  static const MediaLoadingStyle $Desktop = MediaLoadingStyle(
    status: MediaStatusStyle.$Desktop,
    badge: MediaBadgeStyle.$Desktop,
  );

  /// The reference of [platform]: [$IOS] on iOS, [$Desktop] on macOS,
  /// Windows and Linux, [$Android] elsewhere. On the web the platform is the
  /// one the browser runs on (`ThemeData.platform`).
  static MediaLoadingStyle forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS => $IOS,
        TargetPlatform.macOS ||
        TargetPlatform.windows ||
        TargetPlatform.linux => $Desktop,
        TargetPlatform.android || TargetPlatform.fuchsia => $Android,
      };

  /// This style with the given fields replaced.
  MediaLoadingStyle copyWith({
    MediaStatusStyle? status,
    MediaBadgeStyle? badge,
  }) => MediaLoadingStyle(
    status: status ?? this.status,
    badge: badge ?? this.badge,
  );

  @override
  bool operator ==(Object other) =>
      other is MediaLoadingStyle &&
      other.status == status &&
      other.badge == badge;

  @override
  int get hashCode => Object.hash(status, badge);
}

/// Builds the status control of a surface in place of the default one: the
/// host's own widget for the [control] mpx would build (its status, or the
/// binding it maps, and its taps).
typedef MediaStatusBuilder =
    Widget Function(BuildContext context, MediaStatusControl control);

/// Sets the loading style of every surface below, as a change to the
/// platform's reference: [style] receives that reference and returns the
/// style to use, so `(platform) => platform.copyWith(...)` changes a field
/// and keeps the platform's other values.
///
/// [statusBuilder] replaces the status control of every surface below that
/// names none of its own.
///
/// ```dart
/// MediaLoadingStyleScope(
///   style: (platform) => platform.copyWith(
///     status: platform.status.copyWith(discColor: tokens.mediaScrim),
///   ),
///   child: app,
/// )
/// ```
class MediaLoadingStyleScope extends InheritedWidget {
  /// Applies [style] to the platform's reference for the surfaces below.
  const MediaLoadingStyleScope({
    required super.child,
    this.style,
    this.statusBuilder,
    super.key,
  });

  /// The style to use, given the platform's reference; null keeps it.
  final MediaLoadingStyle Function(MediaLoadingStyle platformDefault)? style;

  /// The host's status control, or null for the default one.
  final MediaStatusBuilder? statusBuilder;

  /// The style a surface at [context] uses: [style] when given, else the
  /// closest scope's applied to the platform's reference, else that
  /// reference. The platform is the theme's (`ThemeData.platform`).
  ///
  /// Registers [context] as a dependent of the theme and the scope.
  static MediaLoadingStyle resolve(
    BuildContext context, {
    MediaLoadingStyle? style,
  }) {
    if (style != null) return style;
    final platform = MediaLoadingStyle.forPlatform(Theme.of(context).platform);
    final scope = context
        .dependOnInheritedWidgetOfExactType<MediaLoadingStyleScope>();
    return scope?.style?.call(platform) ?? platform;
  }

  /// The host's status control of the closest scope, or null.
  static MediaStatusBuilder? statusBuilderOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MediaLoadingStyleScope>()
      ?.statusBuilder;

  @override
  bool updateShouldNotify(MediaLoadingStyleScope oldWidget) =>
      !identical(style, oldWidget.style) ||
      !identical(statusBuilder, oldWidget.statusBuilder);
}
