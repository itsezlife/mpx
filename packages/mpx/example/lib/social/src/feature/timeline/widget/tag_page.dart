import 'package:control/control.dart';
import 'package:flutter/material.dart';
import 'package:mpx_example/social/src/feature/initialization/dependencies.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/timeline_controller.dart';
import 'package:mpx_example/social/src/feature/timeline/model/topic.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/timeline_view.dart';

/// One topic's timeline on a page of its own (a hashtag opened from a post).
/// Its controller lives as long as the page.
class TagPage extends StatelessWidget {
  const TagPage({required this.topic, super.key});

  final Topic topic;

  @override
  Widget build(BuildContext context) => ControllerScope(
    () => TimelineController(
      topic: topic,
      repository: Dependencies.of(context).timelineRepository,
    ),
    child: Scaffold(
      appBar: AppBar(title: Text(topic.label)),
      body: const TimelineView(),
    ),
  );
}
