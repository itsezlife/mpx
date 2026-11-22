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

  String copied() =>
      selection.controller.getText(MarkdownSelectionFormatter.plain);

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

  test('the posts shown are the documents, in reading order', () {
    final posts = [_post('3', 'three'), _post('2', 'two'), _post('1', 'one')];
    selection.sync(posts, shows: (_) => true);

    expect(selection.controller.documentCount, 3);
    selection.controller.selectAll();
    // Newest first, as the list reads, not in the order of ids.
    expect(copied(), 'three\n\ntwo\n\none');
  });

  test('a post that covers its text is not copied from', () {
    final posts = [
      _post('3', 'three'),
      _post('2', 'secret', warning: 'spoilers'),
      _post('1', 'one'),
    ];
    selection.sync(posts, shows: (post) => post.warning.isEmpty);

    expect(selection.controller.documentCount, 2);
    selection.controller.selectAll();
    expect(copied(), 'three\n\none');

    // Opened, it is read with the rest, in its place.
    selection.sync(posts, shows: (_) => true);
    selection.controller.selectAll();
    expect(copied(), 'three\n\nsecret\n\none');
  });

  test('a post with no words has nothing to select', () {
    final posts = [_post('2', ''), _post('1', 'one')];
    selection.sync(posts, shows: (_) => true);

    expect(selection.controller.documentCount, 1);
  });

  test('a new list replaces the old documents', () {
    selection.sync([_post('1', 'one')], shows: (_) => true);
    selection
      ..reset()
      ..sync([_post('9', 'nine'), _post('8', 'eight')], shows: (_) => true);

    expect(selection.controller.documentCount, 2);
    selection.controller.selectAll();
    expect(copied(), 'nine\n\neight');
  });
}
