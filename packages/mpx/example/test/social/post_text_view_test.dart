import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_md/flutter_md.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_example/social/src/feature/timeline/widget/post_text_view.dart';

void main() {
  testWidgets('clamped text paints nothing below its last line', (
    tester,
  ) async {
    final words = List.generate(60, (i) => 'word$i').join(' ');
    final markdown = Markdown.fromString(words);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: ColoredBox(
              color: Colors.black,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 300,
                  child: PostTextView(
                    markdown: markdown,
                    documentId: 'a',
                    host: 'm.example',
                    maxLines: 3,
                    selectionGroup: MarkdownSelectionGroup(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final clip = tester.getSize(find.byType(ClipRect).first);
    final full = tester.getSize(find.byType(MarkdownWidget));
    expect(full.height, greaterThan(clip.height), reason: 'text is clamped');

    // Ink below the clamp: any pixel brighter than the black background in
    // the rows under the clipped box and above the "Show more" text.
    final bottom = tester.getBottomLeft(find.byType(ClipRect).first).dy;
    final image = await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final data = await image.toByteData();
      return (image, data!);
    });
    final (picture, bytes) = image!;
    final pixelRatio =
        picture.width / tester.getSize(find.byKey(boundary)).width;
    var ink = 0;
    // The "Show more" button starts at `bottom`; look only inside the box
    // that holds the overflow, below it.
    final from = ((bottom + 40) * pixelRatio).round();
    final to = (full.height * pixelRatio).round().clamp(0, picture.height - 1);
    for (var y = from; y < to; y++) {
      for (var x = 0; x < 300 * pixelRatio; x++) {
        final offset = (y * picture.width + x.round()) * 4;
        if (bytes.getUint8(offset) > 60) ink++;
      }
    }
    expect(ink, 0, reason: 'text painted below the clamp');
  });

  Widget host(Widget child) => MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 300, child: child),
      ),
    ),
  );

  final words = List.generate(60, (i) => 'word$i').join(' ');

  bool selectable(WidgetTester tester) => tester
      .widget<MarkdownSelectionScope>(find.byType(MarkdownSelectionScope))
      .enabled;

  testWidgets('a long press on clamped text opens it, with the word '
      'selected', (tester) async {
    await tester.pumpWidget(
      host(
        PostTextView(
          markdown: Markdown.fromString(words),
          documentId: 'a',
          host: 'm.example',
          maxLines: 3,
          selectionGroup: MarkdownSelectionGroup(),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Show more'), findsOneWidget);
    expect(selectable(tester), isTrue);

    await tester.longPressAt(
      tester.getTopLeft(find.byType(MarkdownWidget)) + const Offset(8, 10),
    );
    await tester.pump();
    await tester.pump();

    // Opened: what is selected is what shows, and the rest is there to read.
    expect(find.text('Show more'), findsNothing);
    final controller = tester
        .widget<MarkdownSelectionScope>(find.byType(MarkdownSelectionScope))
        .controller;
    expect(controller.getText(MarkdownSelectionFormatter.plain), 'word0');
  });

  testWidgets('text that fits is selectable at once', (tester) async {
    await tester.pumpWidget(
      host(
        PostTextView(
          markdown: Markdown.fromString('a few words'),
          documentId: 'a',
          host: 'm.example',
          maxLines: 3,
          selectionGroup: MarkdownSelectionGroup(),
        ),
      ),
    );
    await tester.pump();

    expect(selectable(tester), isTrue);
  });

  testWidgets('text a post still covers cannot be selected', (tester) async {
    await tester.pumpWidget(
      host(
        PostTextView(
          markdown: Markdown.fromString('secret'),
          documentId: 'a',
          host: 'm.example',
          selectionGroup: MarkdownSelectionGroup(),
          selectable: false,
        ),
      ),
    );
    await tester.pump();

    expect(selectable(tester), isFalse);
  });

  testWidgets('a long press selects the word under it', (tester) async {
    final group = MarkdownSelectionGroup();
    await tester.pumpWidget(
      host(
        PostTextView(
          markdown: Markdown.fromString('alpha beta gamma'),
          documentId: 'a',
          host: 'm.example',
          selectionGroup: group,
        ),
      ),
    );
    await tester.pump();

    await tester.longPressAt(
      tester.getTopLeft(find.byType(MarkdownWidget)) + const Offset(8, 10),
    );
    await tester.pump();

    final controller = tester
        .widget<MarkdownSelectionScope>(find.byType(MarkdownSelectionScope))
        .controller;
    expect(controller.getText(MarkdownSelectionFormatter.plain), 'alpha');
  });
}
