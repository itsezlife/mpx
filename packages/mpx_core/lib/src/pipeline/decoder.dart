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
///   Data this build cannot read at all (a codec it was built without) fails
///   with a [DecodeFailure.unsupported], after which the pipeline tries the
///   kind's fallback decoder (`DecoderRegistry.registerFallback`).
/// - A fallback decoder may draw less than the spec asks: a decoder that
///   only draws stills ends every content request at
///   `AssetStage.firstFrame`, and the pipeline makes that stage final for
///   the entry.
/// - It reports nothing after the returned task is cancelled, and a paintable
///   passed to `advance` belongs to the cache from that call on.
/// - The content is the decoder's from [decode] on: it calls
///   `FetchedContent.release` once it no longer reads it, whether the decode
///   succeeds, fails or is cancelled. A decoder that reads the whole file at
///   once releases it after the read; one that keeps reading (a clip that
///   plays) when the last thing reading it closes.
abstract interface class Decoder {
  /// Starts decoding [request], reporting to [progress].
  AssetTask decode(DecodeRequest request, AssetProgress progress);
}

/// Why a [Decoder] failed, when the pipeline acts on the cause.
///
/// A decoder reports it as the error of `AssetProgress.fail`. Any other error
/// is an ordinary decode failure.
final class DecodeFailure implements Exception {
  /// The data is in a format this build cannot read (a codec it was built
  /// without), not damaged: a decoder of another kind may still read it.
  /// [cause] is what the decoder saw, for diagnostics.
  const DecodeFailure.unsupported([this.cause]);

  /// What the decoder saw, or null.
  final Object? cause;

  @override
  String toString() =>
      'DecodeFailure.unsupported${cause == null ? '' : ': $cause'}';
}

/// The decoders of a host, one per `MediaKind`, and a fallback per kind.
///
/// The pipeline looks the decoder of a descriptor's kind up here; a
/// kind with none leaves its entries at `AssetStage.none`. A fallback is
/// asked only for content the kind's decoder reported as
/// [DecodeFailure.unsupported]: a platform still extractor for video codecs
/// the software path was built without, for instance. A later backend (a
/// still drawn by another platform library) plugs in the same way.
final class DecoderRegistry {
  /// Creates an empty registry.
  DecoderRegistry();

  final Map<MediaKind, Decoder> _decoders = {};
  final Map<MediaKind, Decoder> _fallbacks = {};

  /// Registers [decoder] for [kind].
  ///
  /// Throws an [ArgumentError] for [MediaKind.unknown], which has nothing to
  /// decode, and a [StateError] if [kind] already has a decoder: two adapters
  /// claiming one kind is a wiring bug to see.
  void register(MediaKind kind, Decoder decoder) =>
      _add(_decoders, 'decoder', kind, decoder);

  /// Registers [decoder] as the fallback of [kind]: it decodes the content
  /// [kind]'s decoder reports as [DecodeFailure.unsupported].
  ///
  /// Throws as [register] does, for the unknown kind and for a second
  /// fallback of one kind.
  void registerFallback(MediaKind kind, Decoder decoder) =>
      _add(_fallbacks, 'fallback decoder', kind, decoder);

  /// The decoder registered for [kind], or null.
  Decoder? decoderFor(MediaKind kind) => _decoders[kind];

  /// The fallback registered for [kind], or null.
  Decoder? fallbackFor(MediaKind kind) => _fallbacks[kind];

  static void _add(
    Map<MediaKind, Decoder> into,
    String what,
    MediaKind kind,
    Decoder decoder,
  ) {
    if (kind == MediaKind.unknown) {
      throw ArgumentError.value(
        kind,
        'kind',
        'is not decoded: an unknown kind has nothing to decode',
      );
    }
    if (into.containsKey(kind)) {
      throw StateError('A $what is already registered for ${kind.name}.');
    }
    into[kind] = decoder;
  }
}
