import 'package:meta/meta.dart';
import 'package:mpx_core/src/asset/asset_producer.dart';
import 'package:mpx_core/src/asset/asset_spec.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/pipeline/content_fetcher.dart';

/// What a [Decoder] is asked to decode.
@immutable
final class DecodeRequest {
  /// Creates a request to decode [content] as [spec].
  const DecodeRequest({
    required this.descriptor,
    required this.spec,
    required this.part,
    required this.content,
  });

  /// What is known about the content.
  final MediaDescriptor descriptor;

  /// The pixels wanted.
  final AssetSpec spec;

  /// Whether [content] is the thumbnail or the content itself.
  final FetchPart part;

  /// The encoded data.
  final FetchedContent content;
}

/// Turns fetched data into paintables, for one media kind.
///
/// Adapter packages provide decoders (a still image, a vector animation, a
/// video clip) and the host registers each in a `DecoderRegistry` under the
/// `MediaKind` it decodes. A decoder neither fetches nor caches: it gets bytes
/// and a spec and reports stages.
///
/// ## Contract
///
/// - [decode] runs on the UI isolate and returns at once. The work may use
///   isolates or native threads; results are reported on the UI isolate, and
///   synchronously from [decode] if they are already at hand.
/// - A [FetchPart.thumbnail] request ends with one `AssetStage.placeholder`.
/// - A [FetchPart.content] request reports `AssetStage.firstFrame` as soon as
///   the first frame is drawable, if it can do so earlier than the whole,
///   and ends with the stage that is final for the spec: `full`, or
///   `firstFrame` when `AssetSpec.variant` asks for the first frame only.
///   Each paintable is sized to the spec and its `bytes` is what it costs.
/// - Data it cannot decode ends the request with `AssetProgress.fail`; the
///   pipeline treats every decode failure as permanent. It never throws.
/// - It reports nothing after the returned task is cancelled, and a paintable
///   passed to `advance` belongs to the cache from that call on.
abstract interface class Decoder {
  /// Starts decoding [request], reporting to [progress].
  AssetTask decode(DecodeRequest request, AssetProgress progress);
}

/// The decoders of a host, one per `MediaKind`.
///
/// The pipeline looks the decoder of a descriptor's kind up here; a
/// kind with none leaves its entries at `AssetStage.none`.
final class DecoderRegistry {
  /// Creates an empty registry.
  DecoderRegistry();

  final Map<MediaKind, Decoder> _decoders = {};

  /// Registers [decoder] for [kind].
  ///
  /// Throws an [ArgumentError] for [MediaKind.unknown], which has nothing to
  /// decode, and a [StateError] if [kind] already has a decoder: two adapters
  /// claiming one kind is a wiring bug to see.
  void register(MediaKind kind, Decoder decoder) {
    if (kind == MediaKind.unknown) {
      throw ArgumentError.value(
        kind,
        'kind',
        'is not decoded: an unknown kind has nothing to decode',
      );
    }
    if (_decoders.containsKey(kind)) {
      throw StateError('A decoder is already registered for ${kind.name}.');
    }
    _decoders[kind] = decoder;
  }

  /// The decoder registered for [kind], or null.
  Decoder? decoderFor(MediaKind kind) => _decoders[kind];
}
