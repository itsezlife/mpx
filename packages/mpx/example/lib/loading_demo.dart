import 'package:flutter/foundation.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';

/// What the example does to show loading stages on a device: a context tag
/// whose media never downloads by itself, and a set of keys that wait for a
/// tap wherever they show, so the download control and the size badge are
/// there to try on a fresh install (clear the app's data to see them again).
abstract final class LoadingDemo {
  /// The tag of tiles whose media waits for a tap: the network policy's
  /// presets with an "everything manual" row for it.
  static const AutoDownloadContext manual = AutoDownloadContext(
    'example-manual',
  );

  /// Keys that wait for a tap on every surface (the stress feed's clips
  /// carry no tag of their own).
  static final Set<MediaKey> manualKeys = {};

  static const AutoDownloadLimits _manualRow = AutoDownloadLimits(
    still: AutoDownloadLimit.off(),
    video: AutoDownloadLimit.off(),
    animatedImage: AutoDownloadLimit.off(),
  );

  /// The stack's auto-download policy: the platform's standard presets
  /// over [signals], with [manual] and [manualKeys] held back.
  static AutoDownloadPolicy policy(IDeviceSignals signals) => _DemoPolicy(
    NetworkAutoDownloadPolicy(
      signals,
      presets: AutoDownloadPresets.forPlatform(
        defaultTargetPlatform,
      ).withContext(manual, const AutoDownloadNetworkLimits.all(_manualRow)),
    ),
  );
}

final class _DemoPolicy implements AutoDownloadPolicy {
  _DemoPolicy(this._network);

  final NetworkAutoDownloadPolicy _network;

  @override
  AutoDownload decide(
    MediaDescriptor descriptor,
    AutoDownloadContext? context,
  ) =>
      LoadingDemo.manualKeys.contains(descriptor.key) &&
          descriptor.kind != MediaKind.vectorAnimation
      ? AutoDownload.manual
      : _network.decide(descriptor, context);

  @override
  AutoDownloadContext? get defaultContext => _network.defaultContext;

  @override
  Listenable get changes => _network.changes;
}
