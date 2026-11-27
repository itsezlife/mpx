/// Where an upload job waits for its turn: each lane runs one job at a
/// time, and the two run beside each other, so a long video never holds
/// up a photo.
enum UploadLane {
  /// Photos, thumbnails and files up to [defaultSplit].
  small,

  /// Video, and files over [defaultSplit].
  big;

  /// The largest file the small lane takes by default: 10 MiB.
  static const int defaultSplit = 10 * 1024 * 1024;

  /// The lane of a file of [size] bytes, by [split]: video goes [big]
  /// whatever its size, which is the caller's to say.
  static UploadLane forSize(int size, {int split = defaultSplit}) =>
      size <= split ? small : big;
}
