import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_example/social/src/feature/timeline/controller/volume_rise.dart';

void main() {
  late ValueNotifier<int?> volume;
  late int rises;
  late VolumeRise watch;

  setUp(() {
    volume = ValueNotifier(null);
    rises = 0;
    watch = VolumeRise(volume, () => rises++);
  });

  tearDown(() {
    watch.dispose();
    volume.dispose();
  });

  test('a step up is a rise, even from silence', () {
    volume.value = 0;
    expect(rises, 0, reason: 'the first reading is where it stands');

    volume.value = 7;
    expect(rises, 1);

    volume.value = 13;
    expect(rises, 2);
  });

  test('a step down is not, and neither is the same volume again', () {
    volume.value = 50;

    volume.value = 40;
    volume.value = 0;
    expect(rises, 0);

    volume.value = 0;
    expect(rises, 0);
  });

  test('a volume that was unknown and is known is no rise', () {
    volume.value = 30;

    expect(rises, 0);
  });

  test('stops listening when disposed', () {
    volume.value = 10;
    watch.dispose();

    volume.value = 90;

    expect(rises, 0);
  });
}
