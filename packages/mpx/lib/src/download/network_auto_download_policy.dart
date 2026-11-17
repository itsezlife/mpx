import 'package:flutter/foundation.dart';
import 'package:mpx/src/signals/device_signals.dart';
import 'package:mpx_core/mpx_core.dart';

const int _mib = 1024 * 1024;

// 2.5 MiB.
const int _twoAndAHalfMib = 5 * _mib ~/ 2;

// --- Limits ---

/// Whether one media kind downloads by itself on one network, by size.
@immutable
final class AutoDownloadLimit {
  /// Never downloads by itself.
  const AutoDownloadLimit.off()
    : enabled = false,
      maxBytes = null,
      prefixBeyondLimit = false,
      unknownSizeDownloads = false;

  /// Downloads whatever its size, a size nobody knows included.
  const AutoDownloadLimit.any()
    : enabled = true,
      maxBytes = null,
      prefixBeyondLimit = false,
      unknownSizeDownloads = true;

  /// Downloads up to [maxBytes]; larger content waits for the user, after
  /// fetching a playable head when [prefixBeyondLimit] is set. Content whose
  /// size is unknown waits for the user too, unless [unknownSizeDownloads].
  const AutoDownloadLimit.upTo(
    int this.maxBytes, {
    this.prefixBeyondLimit = false,
    this.unknownSizeDownloads = false,
  }) : enabled = true;

  /// Whether the kind downloads by itself at all.
  final bool enabled;

  /// The largest content that downloads by itself, or null for no limit.
  final int? maxBytes;

  /// Whether content over [maxBytes] still fetches a playable head.
  final bool prefixBeyondLimit;

  /// Whether content whose size is unknown downloads by itself. A limit
  /// cannot be checked against an unknown size, so it waits for the user
  /// unless the kind downloads whatever its size.
  final bool unknownSizeDownloads;

  /// The answer for content of [byteSize] bytes, or of an unknown size.
  AutoDownload decide(int? byteSize) {
    if (!enabled) return AutoDownload.manual;
    if (byteSize == null) {
      return unknownSizeDownloads ? AutoDownload.now : AutoDownload.manual;
    }
    final max = maxBytes;
    if (max == null || byteSize <= max) return AutoDownload.now;
    return prefixBeyondLimit ? AutoDownload.prefix : AutoDownload.manual;
  }

  @override
  bool operator ==(Object other) =>
      other is AutoDownloadLimit &&
      other.enabled == enabled &&
      other.maxBytes == maxBytes &&
      other.prefixBeyondLimit == prefixBeyondLimit &&
      other.unknownSizeDownloads == unknownSizeDownloads;

  @override
  int get hashCode =>
      Object.hash(enabled, maxBytes, prefixBeyondLimit, unknownSizeDownloads);

  @override
  String toString() => !enabled
      ? 'AutoDownloadLimit.off()'
      : maxBytes == null
      ? 'AutoDownloadLimit.any()'
      : 'AutoDownloadLimit.upTo($maxBytes'
            '${prefixBeyondLimit ? ', prefixBeyondLimit: true' : ''}'
            '${unknownSizeDownloads ? ', unknownSizeDownloads: true' : ''})';
}

/// The [AutoDownloadLimit] of each media kind on one network.
///
/// Vector animations (stickers) always download: they are small and drawn
/// nowhere else. A kind no decoder reads ([MediaKind.unknown]) follows
/// [still].
@immutable
final class AutoDownloadLimits {
  /// Creates the limits of one network.
  const AutoDownloadLimits({
    required this.still,
    required this.video,
    required this.animatedImage,
  });

  /// Photos and other still images.
  final AutoDownloadLimit still;

  /// Video-coded media.
  final AutoDownloadLimit video;

  /// Animated images (GIF, animated WebP).
  final AutoDownloadLimit animatedImage;

  /// The answer for the content of [descriptor].
  AutoDownload decide(MediaDescriptor descriptor) => switch (descriptor.kind) {
    MediaKind.vectorAnimation => AutoDownload.now,
    MediaKind.video => video.decide(descriptor.byteSize),
    MediaKind.animatedImage => animatedImage.decide(descriptor.byteSize),
    MediaKind.still || MediaKind.unknown => still.decide(descriptor.byteSize),
  };

  /// These limits with the given fields replaced.
  AutoDownloadLimits copyWith({
    AutoDownloadLimit? still,
    AutoDownloadLimit? video,
    AutoDownloadLimit? animatedImage,
  }) => AutoDownloadLimits(
    still: still ?? this.still,
    video: video ?? this.video,
    animatedImage: animatedImage ?? this.animatedImage,
  );

  @override
  bool operator ==(Object other) =>
      other is AutoDownloadLimits &&
      other.still == still &&
      other.video == video &&
      other.animatedImage == animatedImage;

  @override
  int get hashCode => Object.hash(still, video, animatedImage);

  @override
  String toString() =>
      'AutoDownloadLimits(still: $still, video: $video, '
      'animatedImage: $animatedImage)';
}

/// The [AutoDownloadLimits] of each network class a device reports.
@immutable
final class AutoDownloadNetworkLimits {
  /// Creates the limits of each class; [roaming] defaults to [metered].
  const AutoDownloadNetworkLimits({
    required this.unmetered,
    required this.metered,
    AutoDownloadLimits? roaming,
  }) : roaming = roaming ?? metered;

  /// The same limits on every network.
  const AutoDownloadNetworkLimits.all(AutoDownloadLimits limits)
    : unmetered = limits,
      metered = limits,
      roaming = limits;

  /// On a network the user does not pay for by the byte.
  final AutoDownloadLimits unmetered;

  /// On a network the user may pay for by the byte, or asked to spare.
  final AutoDownloadLimits metered;

  /// On a metered network outside the home carrier.
  final AutoDownloadLimits roaming;

  /// The limits on [network]; [NetworkClass.none] reads [unmetered], since
  /// the policy never asks with it (it keeps the last connected class).
  AutoDownloadLimits of(NetworkClass network) => switch (network) {
    NetworkClass.unmetered || NetworkClass.none => unmetered,
    NetworkClass.metered => metered,
    NetworkClass.roaming => roaming,
  };

  @override
  bool operator ==(Object other) =>
      other is AutoDownloadNetworkLimits &&
      other.unmetered == unmetered &&
      other.metered == metered &&
      other.roaming == roaming;

  @override
  int get hashCode => Object.hash(unmetered, metered, roaming);
}

// --- Presets ---

/// The auto-download limits per context tag and network class: a row per
/// [AutoDownloadContext] the host lists, and a [fallback] row for every
/// other tag and for none.
///
/// [$Android], [$IOS] and [$Desktop] are each platform's reference
/// defaults. Their rows for the well-known peer classes
/// ([AutoDownloadContext.contacts], `privateChats`, `groups`, `channels`)
/// are listed, and equal the fallback: no reference splits these classes for
/// photos, videos or animations by default.
@immutable
final class AutoDownloadPresets {
  /// Creates presets.
  const AutoDownloadPresets({
    required this.fallback,
    this.byContext = const {},
  });

  // The same row for the well-known classes as for every other tag.
  AutoDownloadPresets._everyClass(AutoDownloadNetworkLimits row)
    : fallback = row,
      byContext = {
        AutoDownloadContext.contacts: row,
        AutoDownloadContext.privateChats: row,
        AutoDownloadContext.groups: row,
        AutoDownloadContext.channels: row,
      };

  /// The reference presets of [platform]: [$IOS] on iOS, [$Desktop] on
  /// macOS, Windows and Linux, [$Android] elsewhere. On the web the platform
  /// is the one the browser runs on.
  factory AutoDownloadPresets.forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS => $IOS,
        TargetPlatform.macOS ||
        TargetPlatform.windows ||
        TargetPlatform.linux => $Desktop,
        TargetPlatform.android || TargetPlatform.fuchsia => $Android,
      };

  /// The rows the host lists, by tag.
  final Map<AutoDownloadContext, AutoDownloadNetworkLimits> byContext;

  /// The row of a tag [byContext] does not list, and of none.
  final AutoDownloadNetworkLimits fallback;

  /// The limits for content shown in [context] on [network].
  AutoDownloadLimits limitsFor(
    AutoDownloadContext? context,
    NetworkClass network,
  ) => (byContext[context] ?? fallback).of(network);

  /// These presets with [limits] for [context].
  AutoDownloadPresets withContext(
    AutoDownloadContext context,
    AutoDownloadNetworkLimits limits,
  ) => AutoDownloadPresets(
    fallback: fallback,
    byContext: {...byContext, context: limits},
  );

  /// The Android reference: stills always download; videos up to 15 MB on
  /// unmetered and 10 MB on metered networks, a 4 s head beyond that;
  /// animations up to the same sizes; on roaming only stills.
  static final AutoDownloadPresets $Android = AutoDownloadPresets._everyClass(
    const AutoDownloadNetworkLimits(
      unmetered: AutoDownloadLimits(
        still: AutoDownloadLimit.any(),
        video: AutoDownloadLimit.upTo(15 * _mib, prefixBeyondLimit: true),
        animatedImage: AutoDownloadLimit.upTo(15 * _mib),
      ),
      metered: AutoDownloadLimits(
        still: AutoDownloadLimit.any(),
        video: AutoDownloadLimit.upTo(10 * _mib, prefixBeyondLimit: true),
        animatedImage: AutoDownloadLimit.upTo(10 * _mib),
      ),
      roaming: AutoDownloadLimits(
        still: AutoDownloadLimit.any(),
        video: AutoDownloadLimit.off(),
        animatedImage: AutoDownloadLimit.off(),
      ),
    ),
  );

  /// The iOS reference: stills always download (photos are not weighed by
  /// size); on unmetered networks videos up to 10 MB with a 4 s head beyond
  /// and animations up to 10 MB; on metered networks (a low-data mode
  /// included) videos and animations up to 2.5 MB. The platform reports no
  /// roaming, which reads as metered.
  static final AutoDownloadPresets $IOS = AutoDownloadPresets._everyClass(
    const AutoDownloadNetworkLimits(
      unmetered: AutoDownloadLimits(
        still: AutoDownloadLimit.any(),
        video: AutoDownloadLimit.upTo(10 * _mib, prefixBeyondLimit: true),
        animatedImage: AutoDownloadLimit.upTo(10 * _mib),
      ),
      metered: AutoDownloadLimits(
        still: AutoDownloadLimit.any(),
        video: AutoDownloadLimit.upTo(_twoAndAHalfMib),
        animatedImage: AutoDownloadLimit.upTo(_twoAndAHalfMib),
      ),
    ),
  );

  /// The desktop reference: stills up to 8 MB (one of unknown size too),
  /// videos and animations up to 50 MB, on every network (it does not split
  /// them).
  static final AutoDownloadPresets $Desktop = AutoDownloadPresets._everyClass(
    const AutoDownloadNetworkLimits.all(
      AutoDownloadLimits(
        still: AutoDownloadLimit.upTo(8 * _mib, unknownSizeDownloads: true),
        video: AutoDownloadLimit.upTo(50 * _mib),
        animatedImage: AutoDownloadLimit.upTo(50 * _mib),
      ),
    ),
  );
}

// --- Policy ---

/// The composition root's [AutoDownloadPolicy]: [presets] weighed by the
/// network class the device reports ([IDeviceSignals.network]).
///
/// While the device has no network ([NetworkClass.none]) it keeps answering
/// for the last class it was connected to, so a short loss of signal does
/// not turn every item into a download button. [changes] fires when the
/// class it answers for changes, or the [presets] do; the scope then starts
/// the content that may download now. Stop it with [dispose]; the signals
/// stay the host's.
final class NetworkAutoDownloadPolicy implements AutoDownloadPolicy {
  /// Answers from [presets] on the network [signals] reports. A binding
  /// attached with no tag reads [defaultContext].
  NetworkAutoDownloadPolicy(
    this._signals, {
    required AutoDownloadPresets presets,
    this.defaultContext,
  }) : _presets = presets,
       _network = _connected(_signals.network.value, NetworkClass.unmetered) {
    _signals.network.addListener(_onNetwork);
  }

  final IDeviceSignals _signals;
  final _Changes _changes = _Changes();
  AutoDownloadPresets _presets;
  NetworkClass _network;
  bool _disposed = false;

  @override
  final AutoDownloadContext? defaultContext;

  /// The network class the answers are for: the device's, or the last one
  /// it was connected to.
  NetworkClass get network => _network;

  /// The limits the policy answers from. Setting other ones (the user's
  /// settings) fires [changes].
  AutoDownloadPresets get presets => _presets;
  set presets(AutoDownloadPresets value) {
    if (identical(value, _presets)) return;
    _presets = value;
    _changes.fire();
  }

  @override
  Listenable get changes => _changes;

  @override
  AutoDownload decide(
    MediaDescriptor descriptor,
    AutoDownloadContext? context,
  ) => _presets.limitsFor(context, _network).decide(descriptor);

  static NetworkClass _connected(NetworkClass reported, NetworkClass last) =>
      reported == NetworkClass.none ? last : reported;

  void _onNetwork() {
    final next = _connected(_signals.network.value, _network);
    if (next == _network) return;
    _network = next;
    _changes.fire();
  }

  /// Stops following the signals. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _signals.network.removeListener(_onNetwork);
    _changes.dispose();
  }
}

final class _Changes extends ChangeNotifier {
  void fire() => notifyListeners();
}
