import 'package:flutter/material.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';
import 'package:mpx_example/social/src/feature/app/router/routes.dart';
import 'package:mpx_example/social/src/feature/initialization/dependencies.dart';
import 'package:squid/squid.dart';

/// The app: the routes' navigation over the media stack's asset cache, in
/// the dark theme.
class SocialApp extends StatefulWidget {
  const SocialApp({super.key});

  @override
  State<SocialApp> createState() => _SocialAppState();
}

class _SocialAppState extends State<SocialApp> {
  final NavigationController _navigation = NavigationController(
    const <NavigationRoute>[HomeRoute()],
    // Home is always at the bottom: back from anything ends there.
    guards: <NavigationGuard>[RootGuard(() => const HomeRoute())],
    debugLabel: 'social',
  );

  @override
  void dispose() {
    _navigation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Social feed',
    debugShowCheckedModeBanner: false,
    // Dark everywhere, whatever the system's brightness is.
    theme: AppTheme.dark(),
    darkTheme: AppTheme.dark(),
    themeMode: ThemeMode.dark,
    // Above the navigator, so the cache reaches every route and the viewer.
    builder: (context, child) => AssetCacheProvider(
      scope: Dependencies.of(context).stack.scope,
      child: child!,
    ),
    home: NavigationView(controller: _navigation),
  );
}
