import 'package:flutter/foundation.dart';
import 'package:mpx_player/src/pool/player_pool.dart';

/// One video decoder of the device, as the platform lists it.
@immutable
final class PlayerDecoder {
  /// Creates a decoder entry.
  const PlayerDecoder({
    required this.mimeType,
    required this.hardware,
    this.maxInstances = 0,
  });

  /// The video MIME type it decodes (`video/avc`, `video/hevc`,
  /// `video/av01`, `video/x-vnd.on2.vp9`).
  final String mimeType;

  /// Whether it decodes in hardware. Software decoders play, but a feed
  /// that keeps several of them prepared stutters.
  final bool hardware;

  /// How many instances the platform says can run at once; 0 when it does
  /// not say. The platform's number is an upper bound, not a promise.
  final int maxInstances;

  @override
  bool operator ==(Object other) =>
      other is PlayerDecoder &&
      other.mimeType == mimeType &&
      other.hardware == hardware &&
      other.maxInstances == maxInstances;

  @override
  int get hashCode => Object.hash(mimeType, hardware, maxInstances);

  @override
  String toString() =>
      'PlayerDecoder($mimeType, hardware: $hardware, '
      'maxInstances: $maxInstances)';
}

/// What this device can decode, from the platform backend's hardware probe:
/// the input to the prepared-player budget and to the choice of a quality.
///
/// The gate is the reference client's: players are kept prepared only on a
/// high-class device that can run at least [minHevcInstances] HEVC decoders
/// at once; elsewhere every player but the one that plays is released, and
/// the neighbours stay warm as bytes only. A platform that names no instance
/// count (Apple) gates on the device class alone.
@immutable
final class PlayerDevice {
  /// Creates a device description.
  const PlayerDevice({
    this.decoders = const [],
    this.lowRam = false,
    this.totalMemoryBytes = 0,
    this.cpuCount = 0,
    this.memoryClassMb = 0,
    this.performanceClass,
    this.failedCodecs = const {},
    this.instanceCountsKnown = true,
    this.containers = const {},
  });

  /// HEVC decoder instances a high-class device needs before players are
  /// kept prepared.
  static const int minHevcInstances = 8;

  /// Android's media performance class that counts as high (API 31, "S").
  static const int highPerformanceClass = 31;

  /// The device's video decoders.
  final List<PlayerDecoder> decoders;

  /// Whether the platform calls the device low on memory.
  final bool lowRam;

  /// Physical memory in bytes; 0 when unknown.
  final int totalMemoryBytes;

  /// Processor cores; 0 when unknown.
  final int cpuCount;

  /// The per-app memory class in MB (Android); 0 elsewhere.
  final int memoryClassMb;

  /// Android's media performance class, when the device declares one.
  final int? performanceClass;

  /// Video MIME types whose decoder failed on this device before: they are
  /// not chosen again, whatever the decoder list claims.
  final Set<String> failedCodecs;

  /// Whether [PlayerDecoder.maxInstances] means anything on this platform.
  final bool instanceCountsKnown;

  /// Container MIME types the platform player opens; empty when it opens
  /// any it recognises (Android). Apple's players open progressive MP4 only.
  final Set<String> containers;

  /// Whether the platform player opens [mimeType] containers.
  bool opensContainer(String mimeType) =>
      containers.isEmpty || containers.contains(mimeType);

  /// Whether the device counts as high class: a declared media performance
  /// class of S or above, eight cores with a large memory class, or 6 GiB of
  /// memory; never a low-RAM device.
  bool get isHighClass {
    if (lowRam) return false;
    final declared = performanceClass;
    if (declared != null && declared >= highPerformanceClass) return true;
    if (cpuCount >= 8 && memoryClassMb >= 160) return true;
    return totalMemoryBytes >= 6 << 30;
  }

  /// The most instances any decoder of [mimeType] allows; 0 when none says.
  int maxInstancesOf(String mimeType) {
    var most = 0;
    for (final decoder in decoders) {
      if (decoder.mimeType == mimeType && decoder.maxInstances > most) {
        most = decoder.maxInstances;
      }
    }
    return most;
  }

  /// Whether [mimeType] has a hardware decoder that has not failed here.
  bool canDecode(String mimeType) =>
      !failedCodecs.contains(mimeType) &&
      decoders.any(
        (decoder) => decoder.mimeType == mimeType && decoder.hardware,
      );

  /// Whether players besides the one that plays may be kept prepared.
  bool get allowsPreparedPlayers =>
      isHighClass &&
      (!instanceCountsKnown ||
          maxInstancesOf('video/hevc') >= minHevcInstances);

  /// The budget for a pager: one playing player, and two prepared where
  /// [allowsPreparedPlayers], else none.
  PlayerBudget get budget =>
      PlayerBudget(prepared: allowsPreparedPlayers ? 2 : 0);

  @override
  bool operator ==(Object other) =>
      other is PlayerDevice &&
      listEquals(other.decoders, decoders) &&
      other.lowRam == lowRam &&
      other.totalMemoryBytes == totalMemoryBytes &&
      other.cpuCount == cpuCount &&
      other.memoryClassMb == memoryClassMb &&
      other.performanceClass == performanceClass &&
      setEquals(other.failedCodecs, failedCodecs) &&
      other.instanceCountsKnown == instanceCountsKnown &&
      setEquals(other.containers, containers);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(decoders),
    lowRam,
    totalMemoryBytes,
    cpuCount,
    memoryClassMb,
    performanceClass,
    Object.hashAllUnordered(failedCodecs),
    instanceCountsKnown,
    Object.hashAllUnordered(containers),
  );

  @override
  String toString() =>
      'PlayerDevice(highClass: $isHighClass, decoders: $decoders, '
      'failedCodecs: $failedCodecs)';
}
