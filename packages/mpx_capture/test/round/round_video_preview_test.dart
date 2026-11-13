import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_core/mpx_core.dart';

final class _Recording implements RoundVideoRecording {
  _Recording(this.textureId);

  @override
  final int? textureId;

  @override
  MediaDimensions get previewSize => const MediaDimensions(480, 640);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('shows the texture clipped to a circle', (tester) async {
    await tester.pumpWidget(
      Center(
        child: SizedBox.square(
          dimension: 200,
          child: RoundVideoPreview(recording: _Recording(7)),
        ),
      ),
    );
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 7);
    expect(find.byType(ClipOval), findsOneWidget);
    // The 3:4 frame covers the square: its short side fills it.
    expect(tester.getSize(find.byType(ClipOval)), const Size(200, 200));
    final frame = tester.getRect(find.byType(Texture));
    expect(frame.width, closeTo(200, 0.01));
    expect(frame.height, closeTo(800 / 3, 0.01));
  });

  testWidgets('draws nothing without a texture', (tester) async {
    await tester.pumpWidget(RoundVideoPreview(recording: _Recording(null)));
    expect(find.byType(Texture), findsNothing);
  });
}
