import 'package:mpx_lottie/testing.dart';

void main() {
  LottieFrameCodecContract.run(
    () => LottieFrameCodecHarness(
      codec: FakeLottieFrameCodec(),
      unavailable: () => FakeLottieFrameCodec(isAvailable: false),
    ),
  );
}
