import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/post_selection.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';

Post _post(
  String id,
  String words, {
  String warning = '',
  bool sensitive = false,
}) => Post(
  id: PostId(id),
  host: 'm.example',
  author: const Account(handle: 'a@m.example', displayName: 'A', avatar: null),
  createdAt: DateTime.utc(2026, 11, 22),
  text: PostText(markdown: words, plain: words),
  media: sensitive
      ? [
          PostMedia(
            key: MediaKey.external('m.example/media/$id'),
            kind: PostMediaKind.photo,
          ),
        ]
      : const [],
  url: 'https://m.example/@a/$id',
  warning: warning,
  sensitive: sensitive,
);

void main() {
  late PostSelection selection;

  setUp(() => selection = PostSelection());
  tearDown(() => selection.dispose());

  test('a post is parsed once: its widget and the selection share a model', () {
    final post = _post('1', 'hello');
    expect(selection.markdownOf(post), same(selection.markdownOf(post)));
  });

  test('reset forgets the parsed texts', () {
    final post = _post('1', 'hello');
    final before = selection.markdownOf(post);
    selection.reset();
    expect(selection.markdownOf(post), isNot(same(before)));
  });

  MarkdownSelectionController body(Post post) => selection.controllerOf(post)
    ..setDocuments([
      MarkdownDocumentRef(
        id: post.id,
        model: selection.markdownOf(post),
        order: 0,
      ),
    ]);

  test('a post has a selection of its own, which reads its own text', () {
    final one = body(_post('1', 'one'));
    final two = body(_post('2', 'two'));

    one.selectAll();

    expect(one.getText(MarkdownSelectionFormatter.plain), 'one');
    expect(two.selection, isNull);
  });

  test('a selection that starts in one post ends the one in another', () {
    final one = body(_post('1', 'one'));
    final two = body(_post('2', 'two'));

    one.selectAll();
    two.selectAll();

    expect(one.selection, isNull);
    expect(two.getText(MarkdownSelectionFormatter.plain), 'two');
  });

  test('clear ends the selection wherever it is', () {
    final one = body(_post('1', 'one'));
    one.selectAll();

    selection.clear();

    expect(one.selection, isNull);
  });

  test('a post that goes takes its selection with it', () {
    final one = body(_post('1', 'one'));
    one.selectAll();
    one.dispose();

    // Nothing is left for the group to clear, and clearing is safe.
    expect(selection.clear, returnsNormally);
  });
}
