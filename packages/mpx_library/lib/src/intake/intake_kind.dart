/// What an intake file is sent as, decided from its MIME type, its
/// extension and what a probe found.
enum IntakeKind {
  /// A still picture.
  photo,

  /// A video with sound.
  video,

  /// A picture that moves without sound: a GIF, an animated WebP, a silent
  /// video that loops.
  animation,

  /// Sound only.
  audio,

  /// Anything else, sent as a file.
  file;

  /// Classifies a file of [mimeType] and [name]: the MIME type first, the
  /// extension when the MIME type is missing or generic.
  ///
  /// [animated] (more than one frame) and [hasAudio] are what a probe
  /// found, when one ran: an animated picture and a video with no sound
  /// track are [animation].
  static IntakeKind classify({
    String? mimeType,
    String? name,
    bool? animated,
    bool? hasAudio,
  }) {
    final mime = _known(mimeType) ?? _byExtension(name);
    if (mime == null) return file;
    if (mime == 'image/gif') return animation;
    if (mime.startsWith('image/')) {
      return animated == true
          ? animation
          : (_stills.contains(mime) ? photo : file);
    }
    if (mime.startsWith('video/')) return hasAudio == false ? animation : video;
    if (mime.startsWith('audio/')) return audio;
    return file;
  }

  // The picture formats the engine and the servers take as photos; other
  // pictures (TIFF, PSD, RAW) are sent as files.
  static const Set<String> _stills = {
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/heic',
    'image/heif',
    'image/bmp',
    'image/avif',
  };

  static String? _known(String? mime) {
    if (mime == null || mime.isEmpty) return null;
    final lower = mime.toLowerCase();
    if (lower == 'application/octet-stream') return null;
    return lower == 'image/jpg' ? 'image/jpeg' : lower;
  }

  static String? _byExtension(String? name) {
    if (name == null) return null;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return _extensions[name.substring(dot + 1).toLowerCase()];
  }

  static const Map<String, String> _extensions = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'heif': 'image/heif',
    'bmp': 'image/bmp',
    'avif': 'image/avif',
    'tif': 'image/tiff',
    'tiff': 'image/tiff',
    'mp4': 'video/mp4',
    'm4v': 'video/mp4',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'mkv': 'video/x-matroska',
    '3gp': 'video/3gpp',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'ogg': 'audio/ogg',
    'opus': 'audio/opus',
    'wav': 'audio/wav',
    'flac': 'audio/flac',
  };

  /// The MIME type a file [name] most likely has, from its extension.
  static String? mimeOf(String name) => _byExtension(name);
}
