import 'package:control/control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:mpx_example/social/src/feature/app/router/routes.dart';
import 'package:mpx_example/social/src/feature/initialization/dependencies.dart';
import 'package:mpx_example/social/src/feature/reels/widget/reels_page.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/timeline_controller.dart';
import 'package:mpx_example/social/src/feature/timeline/model/topic.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/timeline_view.dart';
import 'package:squid/squid.dart';

/// The home: the feed of topics under a tab bar, and the reels, under a
/// navigation bar.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _destination = 0;

  // The reels are built the first time they are opened: a pager of players
  // is not worth holding for a reader who never goes there.
  bool _reelsOpened = false;
  TimelineController? _reels;

  // The reels' videos are read once and kept, though the pager is built only
  // while the tab shows.
  TimelineController _reelsController() => _reels ??= TimelineController(
    topic: Topic.reels,
    repository: Dependencies.of(context).timelineRepository,
  );

  @override
  void dispose() {
    _reels?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _destination,
      children: [
        const _TopicTabs(),
        if (_reelsOpened)
          ControllerScope<TimelineController>.value(
            _reelsController(),
            child: ReelsPage(active: _destination == 1),
          )
        else
          const SizedBox(),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _destination,
      onDestinationSelected: (index) => setState(() {
        _destination = index;
        if (index == 1) _reelsOpened = true;
      }),
      destinations: const [
        NavigationDestination(icon: Icon(LucideIcons.newspaper), label: 'Feed'),
        NavigationDestination(
          icon: Icon(LucideIcons.circle_play),
          label: 'Reels',
        ),
      ],
    ),
  );
}

/// The topics of [Topic.home], one tab each. Each timeline is read when its
/// tab is first shown and kept for the session, so a tab comes back as the
/// reader left it.
class _TopicTabs extends StatefulWidget {
  const _TopicTabs();

  @override
  State<_TopicTabs> createState() => _TopicTabsState();
}

class _TopicTabsState extends State<_TopicTabs> {
  final Map<String, TimelineController> _controllers = {};

  TimelineController _controllerOf(Topic topic) => _controllers.putIfAbsent(
    topic.id,
    () => TimelineController(
      topic: topic,
      repository: Dependencies.of(context).timelineRepository,
    ),
  );

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: Topic.home.length,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Mastodon'),
        actions: [
          IconButton(
            tooltip: 'Logs',
            icon: const Icon(LucideIcons.scroll_text),
            onPressed: () => context.navigation.push(const LogsRoute()),
          ),
        ],
        bottom: TabBar(
          isScrollable: true,
          tabs: [for (final topic in Topic.home) Tab(text: topic.label)],
        ),
      ),
      body: TabBarView(
        children: [
          for (final topic in Topic.home)
            ControllerScope<TimelineController>.value(
              _controllerOf(topic),
              child: const TimelineView(),
            ),
        ],
      ),
    ),
  );
}
