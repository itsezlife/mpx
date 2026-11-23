import 'package:flutter_md/flutter_md.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';

/// What the text selection of a list of posts shares between its posts: one
/// group (at most one post has a selection at a time) and the parsed texts.
///
/// Each post's text has a selection of its own (`controllerOf`), as each
/// message of a chat has: a long press and a drag select inside one post, the
/// handles and the toolbar belong to it, a post scrolled off the list takes
/// its selection with it, and a selection that starts in another post ends
/// this one. Nothing reads a text that is not on screen, so a clipped text,
/// a covered one or one a list recycled cannot be selected through.
final class PostSelection {
  final MarkdownSelectionGroup _group = MarkdownSelectionGroup();
  final Map<PostId, Markdown> _parsed = {};

  /// The group a post's selection joins, for a text drawn without
  /// `controllerOf`.
  MarkdownSelectionGroup get group => _group;

  /// The parsed text of [post]: the same object every call, until [reset].
  Markdown markdownOf(Post post) => _parsed.putIfAbsent(
    post.id,
    () => Markdown.fromString(post.text.markdown),
  );

  /// A selection for one post's text, in the group. The post's text disposes
  /// it.
  MarkdownSelectionController controllerOf(Post post) =>
      MarkdownSelectionController(group: _group);

  /// Ends the selection, and its toolbar with it.
  void clear() => _group.clearExternal();

  /// Forgets every parsed text: the list was replaced, and the old posts are
  /// not coming back.
  void reset() => _parsed.clear();

  /// Ends the selection.
  void dispose() => clear();
}
