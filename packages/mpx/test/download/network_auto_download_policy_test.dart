import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx/testing.dart';
import 'package:mpx_core/mpx_core.dart';

const int _mb = 1024 * 1024;

MediaDescriptor _media(MediaKind kind, int? bytes) => MediaDescriptor(
  key: MediaKey.remote('$kind-$bytes'),
  kind: kind,
  byteSize: bytes,
);

void main() {
  late FakeDeviceSignals signals;

  setUp(() => signals = FakeDeviceSignals());
  tearDown(() => signals.dispose());

  NetworkAutoDownloadPolicy policyOf(
    AutoDownloadPresets presets,
    NetworkClass network,
  ) {
    signals.network.value = network;
    final policy = NetworkAutoDownloadPolicy(signals, presets: presets);
    addTearDown(policy.dispose);
    return policy;
  }

  AutoDownload decide(
    AutoDownloadPresets presets,
    NetworkClass network,
    MediaKind kind,
    int? bytes, [
    AutoDownloadContext? context,
  ]) => policyOf(presets, network).decide(_media(kind, bytes), context);

  test('a GIF sent as a silent video loop is weighed as a GIF', () {
    const limits = AutoDownloadLimits(
      still: AutoDownloadLimit.any(),
      video: AutoDownloadLimit.upTo(10 * _mb, prefixBeyondLimit: true),
      animatedImage: AutoDownloadLimit.off(),
    );
    final policy = policyOf(
      const AutoDownloadPresets(
        fallback: AutoDownloadNetworkLimits.all(limits),
      ),
      NetworkClass.unmetered,
    );
    const loop = MediaDescriptor(
      key: MediaKey.remote('gif-as-video'),
      kind: MediaKind.video,
      byteSize: 2 * _mb,
      silentLoop: true,
    );

    expect(policy.decide(loop, null), AutoDownload.manual);
    expect(
      policy.decide(_media(MediaKind.video, 2 * _mb), null),
      AutoDownload.now,
    );
  });

  group(r'$Android', () {
    final presets = AutoDownloadPresets.$Android;

    test('metered: a 12 MB video is a prefix, 3 MB downloads, a 30 MB '
        'still downloads', () {
      const metered = NetworkClass.metered;
      expect(
        decide(presets, metered, MediaKind.video, 12 * _mb),
        AutoDownload.prefix,
      );
      expect(
        decide(presets, metered, MediaKind.video, 3 * _mb),
        AutoDownload.now,
      );
      expect(
        decide(presets, metered, MediaKind.still, 30 * _mb),
        AutoDownload.now,
      );
      expect(
        decide(presets, metered, MediaKind.animatedImage, 11 * _mb),
        AutoDownload.manual,
      );
    });

    test('unmetered: videos and animations up to 15 MB', () {
      const wifi = NetworkClass.unmetered;
      expect(
        decide(presets, wifi, MediaKind.video, 15 * _mb),
        AutoDownload.now,
      );
      expect(
        decide(presets, wifi, MediaKind.video, 16 * _mb),
        AutoDownload.prefix,
      );
      expect(
        decide(presets, wifi, MediaKind.animatedImage, 15 * _mb),
        AutoDownload.now,
      );
    });

    test('roaming: video and animations are manual, stills download', () {
      const roaming = NetworkClass.roaming;
      expect(
        decide(presets, roaming, MediaKind.video, 100),
        AutoDownload.manual,
      );
      expect(
        decide(presets, roaming, MediaKind.animatedImage, 100),
        AutoDownload.manual,
      );
      expect(
        decide(presets, roaming, MediaKind.still, 30 * _mb),
        AutoDownload.now,
      );
    });

    test('pins the rows', () {
      expect(
        presets.fallback.unmetered,
        const AutoDownloadLimits(
          still: AutoDownloadLimit.any(),
          video: AutoDownloadLimit.upTo(15 * _mb, prefixBeyondLimit: true),
          animatedImage: AutoDownloadLimit.upTo(15 * _mb),
        ),
      );
      expect(
        presets.fallback.metered,
        const AutoDownloadLimits(
          still: AutoDownloadLimit.any(),
          video: AutoDownloadLimit.upTo(10 * _mb, prefixBeyondLimit: true),
          animatedImage: AutoDownloadLimit.upTo(10 * _mb),
        ),
      );
      expect(
        presets.fallback.roaming,
        const AutoDownloadLimits(
          still: AutoDownloadLimit.any(),
          video: AutoDownloadLimit.off(),
          animatedImage: AutoDownloadLimit.off(),
        ),
      );
    });
  });

  group(r'$IOS', () {
    final presets = AutoDownloadPresets.$IOS;

    test('stills download at any size; 2.5 MB videos download on metered', () {
      const metered = NetworkClass.metered;
      expect(
        decide(presets, metered, MediaKind.still, 30 * _mb),
        AutoDownload.now,
      );
      expect(
        decide(presets, NetworkClass.unmetered, MediaKind.still, 30 * _mb),
        AutoDownload.now,
      );
      expect(presets.fallback.metered.still, const AutoDownloadLimit.any());
      expect(
        decide(presets, metered, MediaKind.video, 5 * _mb ~/ 2),
        AutoDownload.now,
      );
      expect(
        decide(presets, metered, MediaKind.video, 3 * _mb),
        AutoDownload.manual,
      );
    });

    test('unmetered: videos up to 10 MB, a prefix beyond', () {
      const wifi = NetworkClass.unmetered;
      expect(
        decide(presets, wifi, MediaKind.video, 10 * _mb),
        AutoDownload.now,
      );
      expect(
        decide(presets, wifi, MediaKind.video, 11 * _mb),
        AutoDownload.prefix,
      );
      expect(decide(presets, wifi, MediaKind.still, _mb), AutoDownload.now);
    });

    test('roaming reads as metered', () {
      expect(presets.fallback.roaming, presets.fallback.metered);
    });
  });

  group(r'$Desktop', () {
    final presets = AutoDownloadPresets.$Desktop;

    test('stills up to 8 MB, video and animations up to 50 MB, any '
        'network', () {
      for (final network in [
        NetworkClass.unmetered,
        NetworkClass.metered,
        NetworkClass.roaming,
      ]) {
        expect(
          decide(presets, network, MediaKind.still, 8 * _mb),
          AutoDownload.now,
        );
        expect(
          decide(presets, network, MediaKind.still, 9 * _mb),
          AutoDownload.manual,
        );
        expect(
          decide(presets, network, MediaKind.video, 50 * _mb),
          AutoDownload.now,
        );
        expect(
          decide(presets, network, MediaKind.animatedImage, 51 * _mb),
          AutoDownload.manual,
        );
      }
    });
  });

  test('the well-known tags carry the fallback row on every platform', () {
    for (final presets in [
      AutoDownloadPresets.$Android,
      AutoDownloadPresets.$IOS,
      AutoDownloadPresets.$Desktop,
    ]) {
      for (final tag in [
        AutoDownloadContext.contacts,
        AutoDownloadContext.privateChats,
        AutoDownloadContext.groups,
        AutoDownloadContext.channels,
      ]) {
        expect(presets.byContext[tag], presets.fallback);
      }
    }
  });

  test('a tag the presets do not list uses the fallback row', () {
    final presets = AutoDownloadPresets.$Android.withContext(
      AutoDownloadContext.channels,
      const AutoDownloadNetworkLimits.all(
        AutoDownloadLimits(
          still: AutoDownloadLimit.off(),
          video: AutoDownloadLimit.off(),
          animatedImage: AutoDownloadLimit.off(),
        ),
      ),
    );
    const mine = AutoDownloadContext('saved');

    expect(
      decide(
        presets,
        NetworkClass.metered,
        MediaKind.still,
        100,
        AutoDownloadContext.channels,
      ),
      AutoDownload.manual,
    );
    expect(
      decide(presets, NetworkClass.metered, MediaKind.still, 100, mine),
      AutoDownload.now,
    );
  });

  test('an unknown size waits for a tap for video and animations, and '
      'downloads for stills, on every platform', () {
    for (final presets in [
      AutoDownloadPresets.$Android,
      AutoDownloadPresets.$IOS,
      AutoDownloadPresets.$Desktop,
    ]) {
      for (final network in [NetworkClass.unmetered, NetworkClass.metered]) {
        expect(
          decide(presets, network, MediaKind.video, null),
          AutoDownload.manual,
        );
        expect(
          decide(presets, network, MediaKind.animatedImage, null),
          AutoDownload.manual,
        );
        expect(
          decide(presets, network, MediaKind.still, null),
          AutoDownload.now,
        );
      }
    }
  });

  test('vector animations always download', () {
    final presets = AutoDownloadPresets.$Android;
    expect(
      decide(presets, NetworkClass.roaming, MediaKind.vectorAnimation, _mb),
      AutoDownload.now,
    );
  });

  test('without a network it answers for the last connected class', () {
    final policy = policyOf(AutoDownloadPresets.$Android, NetworkClass.roaming);
    var changes = 0;
    policy.changes.addListener(() => changes++);

    signals.network.value = NetworkClass.none;

    expect(policy.network, NetworkClass.roaming);
    expect(changes, 0);
    expect(
      policy.decide(_media(MediaKind.video, 100), null),
      AutoDownload.manual,
    );
  });

  test('a network change signals changes', () {
    final policy = policyOf(AutoDownloadPresets.$Android, NetworkClass.metered);
    var changes = 0;
    policy.changes.addListener(() => changes++);

    signals.network.value = NetworkClass.unmetered;

    expect(changes, 1);
    expect(
      policy.decide(_media(MediaKind.video, 12 * _mb), null),
      AutoDownload.now,
    );
  });

  test('new presets signal changes', () {
    final policy = policyOf(AutoDownloadPresets.$Android, NetworkClass.metered);
    var changes = 0;
    policy.changes.addListener(() => changes++);

    policy.presets = AutoDownloadPresets.$Desktop;

    expect(changes, 1);
  });

  test('forPlatform picks each reference', () {
    expect(
      AutoDownloadPresets.forPlatform(TargetPlatform.android),
      same(AutoDownloadPresets.$Android),
    );
    expect(
      AutoDownloadPresets.forPlatform(TargetPlatform.iOS),
      same(AutoDownloadPresets.$IOS),
    );
    expect(
      AutoDownloadPresets.forPlatform(TargetPlatform.macOS),
      same(AutoDownloadPresets.$Desktop),
    );
  });
}
