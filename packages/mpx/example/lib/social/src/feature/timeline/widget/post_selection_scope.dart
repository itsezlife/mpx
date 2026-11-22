import 'package:flutter/material.dart';
import 'package:flutter_md/flutter_md.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/post_selection.dart';

/// The text selection of a list of posts: a `MarkdownSelectionScope` over the
/// list that ends the selection the moment the list stops being what the
/// reader sees.
///
/// The selection's toolbar and handles live in the navigator's overlay, not
/// in the list. When the list goes off (another tab, another tab bar
/// destination, a route over it) the text they were anchored to is no longer
/// laid out, their anchors turn to NaN, and the toolbar throws from paint on
/// every frame: the screen stops updating. So the selection is cleared on the
/// three ways a list leaves the screen without leaving the tree:
///
/// - a route is pushed over it (`ModalRoute.isCurrent`);
/// - an `IndexedStack` hides it (`TickerMode`);
/// - the tab bar moves to another tab (`DefaultTabController`).
class PostSelectionScope extends StatefulWidget {
  const PostSelectionScope({
    required this.selection,
    required this.child,
    super.key,
  });

  final PostSelection selection;
  final Widget child;

  @override
  State<PostSelectionScope> createState() => _PostSelectionScopeState();
}

class _PostSelectionScopeState extends State<PostSelectionScope> {
  TabController? _tabs;
  bool _seen = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final seen =
        (ModalRoute.isCurrentOf(context) ?? true) &&
        TickerMode.valuesOf(context).enabled;
    if (_seen && !seen) widget.selection.clear();
    _seen = seen;

    final tabs = DefaultTabController.maybeOf(context);
    if (!identical(tabs, _tabs)) {
      _tabs?.removeListener(_onTabs);
      _tabs = tabs?..addListener(_onTabs);
    }
  }

  void _onTabs() => widget.selection.clear();

  @override
  void dispose() {
    _tabs?.removeListener(_onTabs);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MarkdownSelectionScope(
    controller: widget.selection.controller,
    selectionColor: Theme.of(
      context,
    ).colorScheme.primary.withValues(alpha: 0.35),
    child: widget.child,
  );
}
