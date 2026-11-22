import 'package:flutter/material.dart';

/// The spacing steps of the feed, in logical pixels.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
}

/// The corner radii of the feed.
abstract final class AppRadius {
  /// A picture in a post.
  static const double media = 14;

  /// A chip or a small cover.
  static const double chip = 20;
}

/// Sizes of the feed's layout, in logical pixels.
abstract final class AppLayout {
  /// The widest a column of posts grows to: wider windows centre it.
  static const double feedColumnWidth = 620;
}

/// Roles the Material scheme has no name for.
@immutable
final class AppColorsExt extends ThemeExtension<AppColorsExt> {
  const AppColorsExt({
    required this.like,
    required this.boost,
    required this.mediaPlaceholder,
    required this.scrim,
  });

  factory AppColorsExt.dark() => const AppColorsExt(
    like: Color(0xFFFF5C8A),
    boost: Color(0xFF3DD9A0),
    mediaPlaceholder: Color(0xFF23272B),
    scrim: Color(0xB3000000),
  );

  /// The heart of a post's likes.
  final Color like;

  /// The arrows of a post's boosts.
  final Color boost;

  /// What a picture shows before it has one.
  final Color mediaPlaceholder;

  /// Over a picture, behind the controls drawn on it.
  final Color scrim;

  @override
  AppColorsExt copyWith({
    Color? like,
    Color? boost,
    Color? mediaPlaceholder,
    Color? scrim,
  }) => AppColorsExt(
    like: like ?? this.like,
    boost: boost ?? this.boost,
    mediaPlaceholder: mediaPlaceholder ?? this.mediaPlaceholder,
    scrim: scrim ?? this.scrim,
  );

  @override
  AppColorsExt lerp(AppColorsExt? other, double t) => other == null
      ? this
      : AppColorsExt(
          like: Color.lerp(like, other.like, t)!,
          boost: Color.lerp(boost, other.boost, t)!,
          mediaPlaceholder: Color.lerp(
            mediaPlaceholder,
            other.mediaPlaceholder,
            t,
          )!,
          scrim: Color.lerp(scrim, other.scrim, t)!,
        );
}

extension AppThemeData on ThemeData {
  /// The feed's own colour roles.
  AppColorsExt get colors => extension<AppColorsExt>()!;
}

/// The feed's theme: dark, the only one the app opens in (the app does not
/// follow the system's brightness), as one Material 3 scheme from one seed
/// and the feed's own roles beside it.
abstract final class AppTheme {
  static const Color _seed = Color(0xFF5B6CFF);

  static ThemeData dark() => _build(AppColorsExt.dark());

  static ThemeData _build(AppColorsExt colors) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      extensions: [colors],
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 0.5,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      tabBarTheme: const TabBarThemeData(
        dividerColor: Colors.transparent,
        tabAlignment: TabAlignment.start,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.secondaryContainer,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
