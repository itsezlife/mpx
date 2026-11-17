import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';

/// The core's [PreviewStore] over the bytes cache: derived previews are rows
/// of the store under [BytesQuota.previews], with a memory tier in front.
///
/// - Keys: `preview-` and the media key's stable form (`MediaKey.encoded`),
///   which no other row of the stack starts with; a form longer than the
///   store takes as a file name is hashed.
/// - Memory: the last [memoryEntries] previews read or written, answered by
///   [peek] without IO.
/// - Writes go to memory at once and to the store after the frame, one at a
///   time in order, so a write never blocks a frame. [flush] waits for them.
/// - A store that knows its rows without IO (`IBytesStore.contains`) is
///   read only for the previews it holds.
/// - A row the store cannot read answers null: the content shows without a
///   preview and derives it again.
final class BytesCachePreviewStore implements PreviewStore {
  /// Creates a store over [store].
  BytesCachePreviewStore(this._store, {this.memoryEntries = 512})
    : assert(memoryEntries > 0, 'The memory tier holds at least one.');

  final IBytesCache _store;

  /// How many previews the memory tier keeps.
  final int memoryEntries;

  final LinkedHashMap<MediaKey, Uint8List> _memory = LinkedHashMap();
  final List<(MediaKey, Uint8List)> _pending = [];
  Future<void>? _writing;

  /// The store row of the preview of [key].
  static BytesCacheKey cacheKeyOf(MediaKey key) {
    final form = 'preview-${key.encoded}';
    if (form.length <= _maxKeyLength) return BytesCacheKey(form);
    return BytesCacheKey('preview-hashed-${sha1.convert(utf8.encode(form))}');
  }

  // The longest key the stores take as a file name and a web cache key.
  static const int _maxKeyLength = 180;

  @override
  Uint8List? peek(MediaKey key) {
    final png = _memory.remove(key);
    if (png != null) _memory[key] = png;
    return png;
  }

  @override
  Future<Uint8List?> read(MediaKey key) async {
    if (peek(key) case final png?) return png;
    // Out of memory but not yet in the store: the write is still queued.
    for (final (pending, png) in _pending.reversed) {
      if (pending == key) return png;
    }
    // A store that answers from memory whether it holds a row spares the
    // read of a preview that was never derived, which most content is not.
    final store = _store;
    if (store is IBytesStore && !store.contains(cacheKeyOf(key))) return null;
    try {
      final png = await _store.read(cacheKeyOf(key));
      if (png != null) _remember(key, png);
      return png;
    } on Object {
      return null;
    }
  }

  @override
  void write(MediaKey key, Uint8List png) {
    _remember(key, png);
    _pending.add((key, png));
    _writing ??= Future<void>(_drain);
  }

  /// Completes when every write so far has reached the store.
  Future<void> flush() async {
    for (var writing = _writing; writing != null; writing = _writing) {
      await writing;
    }
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      // Dequeued once written, so a read meanwhile still finds it.
      final (key, png) = _pending.first;
      try {
        await _store.write(cacheKeyOf(key), png, quota: BytesQuota.previews);
      } on Object {
        // A preview that cannot be written stays in memory for this process;
        // the next one derives it again.
      }
      _pending.removeAt(0);
    }
    _writing = null;
  }

  void _remember(MediaKey key, Uint8List png) {
    _memory
      ..remove(key)
      ..[key] = png;
    while (_memory.length > memoryEntries) {
      _memory.remove(_memory.keys.first);
    }
  }
}
