import 'package:flutter_md/flutter_md.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';

/// What lets the text of a list of posts be selected across posts: the
/// selection itself, and the posts' parsed texts it reads from.
///
/// The controller anchors a selection on the immutable `Markdown` models, not
/// on the widgets, so a selection survives its posts scrolling out and being
/// disposed, and a copy reads the text of posts that are not on screen. For
/// that it needs the model of every post in the list, in reading order, and
/// the very model the post's widget draws (it compares by identity): so the
/// models are parsed here, once, and the widgets ask for them.
final class PostSelection {
  /// The selection; a `MarkdownSelectionScope` over the list takes it.
  final MarkdownSelectionController controller = MarkdownSelectionController();

  final Map<PostId, Markdown> _parsed = {};

  /// The parsed text of [post]: the same object every call, until [reset].
  Markdown markdownOf(Post post) => _parsed.putIfAbsent(
    post.id,
    () => Markdown.fromString(post.text.markdown),
  );

  /// Tells the selection which posts are in the list, in reading order, and
  /// which of them show their text.
  ///
  /// A post whose text is covered (a content warning not yet opened) is left
  /// out: a selection across it must not copy words the reader has not been
  /// shown. One with no text has nothing to select. The order of a document is
  /// its index in [posts], so the documents stay in reading order though some
  /// are left out.
  void sync(List<Post> posts, {required bool Function(Post post) shows}) {
    controller.setDocuments([
      for (final (index, post) in posts.indexed)
        if (!post.text.isEmpty && shows(post))
          MarkdownDocumentRef(
            id: post.id,
            model: markdownOf(post),
            order: index,
          ),
    ]);
  }

  /// Ends the selection, and its toolbar with it.
  void clear() => controller.clear();

  /// Forgets every parsed text: the list was replaced, and the old posts are
  /// not coming back.
  void reset() => _parsed.clear();

  void dispose() => controller.dispose();
}
