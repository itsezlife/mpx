import 'package:flutter/foundation.dart';

/// What the system says about the app's right to play sound.
enum AudioFocusChange {
  /// The app may play sound again after an [interrupted].
  gained,

  /// Another app took the sound for good (it started its own playback). The
  /// sound owner pauses and does not resume by itself.
  lost,

  /// Something takes the sound for a while: a call, an alarm, a navigation
  /// prompt. The sound owner pauses and resumes on [gained].
  ///
  /// A request to only lower the volume ("duck") arrives as this too: the
  /// sound owner plays video, often speech, which ducked under another
  /// voice is lost, so it pauses rather than plays on quietly.
  interrupted,

  /// The audio output went away (headphones unplugged, a Bluetooth device
  /// disconnected). The sound owner pauses, so the sound does not move to
  /// the speaker.
  outputRemoved,
}

/// The platform's audio session as the player pool's sound owner uses it:
/// the app asks for the right to play sound while one player is audible, and
/// hears when calls, other apps and outputs take it away.
///
/// Each `PlayerBackend` brings the one of its platform (Android audio focus,
/// the Apple audio session); `FakeAudioFocus` in `testing.dart` stands in for
/// it in tests. [request] and [abandon] come in pairs from the pool; a
/// platform that grants focus later reports [AudioFocusChange.gained].
abstract interface class AudioFocus {
  /// Asks for the right to play sound: a player became audible.
  void request();

  /// Gives the right back: no player is audible any more.
  void abandon();

  /// What the system says while the app holds or waits for the right.
  Stream<AudioFocusChange> get changes;
}

/// An [AudioFocus] for a platform without one: requests are granted and
/// nothing ever takes them away.
final class NoAudioFocus implements AudioFocus {
  /// Creates a focus that never changes.
  const NoAudioFocus();

  @override
  void request() {}

  @override
  void abandon() {}

  @override
  Stream<AudioFocusChange> get changes => const Stream.empty();
}

/// How an audible player takes the platform's sound from other apps.
enum PlayerAudioFocus {
  /// Takes it: other apps' sound pauses while the player is audible, and
  /// calls, alarms and other apps pause the player.
  exclusive,

  /// Asks other apps to lower their sound while the player is audible.
  duck,

  /// Plays over other apps' sound, which goes on as it was; only an output
  /// going away (headphones out) is still reported.
  mix;

  /// The reference behaviour of [platform]: Android plays a video over the
  /// music that plays; Apple platforms take the sound.
  static PlayerAudioFocus forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.android => PlayerAudioFocus.mix,
        _ => PlayerAudioFocus.exclusive,
      };
}
