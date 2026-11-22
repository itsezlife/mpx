import 'package:flutter/widgets.dart';
import 'package:mpx_example/social/src/feature/app/view/home_page.dart';
import 'package:mpx_example/social/src/feature/logs/view/log_journal_page.dart';
import 'package:mpx_example/social/src/feature/timeline/model/topic.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/tag_page.dart';
import 'package:squid/squid.dart';

/// A screen of the app. The whole navigation is a list of these.
sealed class AppRoute with NavigationRoute {
  const AppRoute();
}

/// The home: the topics' feed and the reels.
final class HomeRoute extends AppRoute {
  const HomeRoute();

  @override
  String get name => 'home';

  @override
  Widget build(BuildContext context) => const HomePage();
}

/// The journal of what the app logged.
final class LogsRoute extends AppRoute {
  const LogsRoute();

  @override
  String get name => 'logs';

  @override
  Widget build(BuildContext context) => const LogJournalPage();
}

/// The posts under one hashtag of one server, opened from a post's text.
final class TagRoute extends AppRoute {
  const TagRoute({required this.host, required this.tag});

  final String host;

  /// The tag, without `#`.
  final String tag;

  @override
  String get name => 'tag';

  // Two routes with the same key are one screen: opening the tag again from
  // another post brings the open one to the top.
  @override
  LocalKey get key => ValueKey<String>('tag/$host/$tag');

  @override
  Map<String, Object?> get arguments => {'host': host, 'tag': tag};

  @override
  Widget build(BuildContext context) => TagPage(topic: Topic.tag(host, tag));
}
