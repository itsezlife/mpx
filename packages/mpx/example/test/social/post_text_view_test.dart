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
    final controller = MarkdownSelectionController();
    addTearDown(controller.dispose);
    controller.setDocuments([
      MarkdownDocumentRef(id: 'a', model: markdown, order: 0),
    ]);
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
                  child: MarkdownSelectionScope(
                    controller: controller,
                    child: PostTextView(
                      markdown: markdown,
                      documentId: 'a',
                      host: 'm.example',
                      maxLines: 3,
                    ),
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
}
