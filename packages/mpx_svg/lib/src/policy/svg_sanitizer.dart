import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:mpx_svg/src/policy/svg_limits.dart';
import 'package:xml/xml.dart' show XmlException;
import 'package:xml/xml_events.dart';

/// Why an SVG was not drawn.
enum SvgRejectionReason {
  /// Not a well-formed XML document with an `svg` root, or not UTF-8 text.
  notSvg,

  /// An element that runs code, embeds another document or animates
  /// (`script`, `foreignObject`, `iframe`, `animate`, `set`, ...).
  element,

  /// An event-handler attribute (`onload`, `onclick`, ...).
  eventHandler,

  /// A reference outside the document: an `href` or a `url(...)` that is not
  /// `#id`, or a stylesheet processing instruction.
  externalReference,

  /// An image embedded as a `data:` URI while the limits do not allow them
  /// (`SvgLimits.allowEmbeddedImages`).
  embeddedImage,

  /// A stylesheet rule that imports or animates (`@import`, `@keyframes`,
  /// `animation`).
  stylesheet,

  /// A document type that declares entities.
  doctype,

  /// More elements than `SvgLimits.maxElements`.
  tooManyElements,

  /// Nested deeper than `SvgLimits.maxDepth`.
  tooDeep,

  /// More elements than `SvgLimits.maxUseExpansion` once every `<use>` is
  /// expanded, or a `<use>` that references itself through others.
  useExpansion,

  /// A file larger than `SvgLimits.maxInputBytes`.
  tooLarge,

  /// Sanitizing and compiling took longer than `SvgLimits.maxCompileTime`.
  tooSlow,

  /// The document passed the sanitizer, but the compiler could not read it,
  /// or it declares no size to draw at.
  unreadable,
}

/// An SVG that was not drawn, and why. The error a decode fails with.
@immutable
final class SvgRejection implements Exception {
  /// Creates a rejection for [reason], with [detail] for logs.
  const SvgRejection(this.reason, [this.detail = '']);

  /// Why.
  final SvgRejectionReason reason;

  /// What was seen (an element name, a count), for logs only.
  final String detail;

  @override
  bool operator ==(Object other) =>
      other is SvgRejection && other.reason == reason && other.detail == detail;

  @override
  int get hashCode => Object.hash(reason, detail);

  @override
  String toString() =>
      'SvgRejection(${reason.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// Decides whether an SVG document from anywhere may be drawn, before the
/// compiler sees it.
///
/// A pure pass over the document's XML events, so it costs one tokenization
/// and holds no tree. It **rejects** a document rather than stripping what it
/// dislikes: a stripped document draws something its author did not draw,
/// and a rejection keeps the surface at its placeholder, which is the
/// failure rule of every other media kind.
///
/// What it rejects, and why each matters even though the compiler ignores
/// much of it today: the compiler's coverage grows, and a rule here keeps a
/// new feature from turning into a hole.
///
/// - Elements that run code, embed documents or animate (scripts,
///   `foreignObject`, frames, media, SMIL animation).
/// - Event-handler attributes.
/// - References out of the document: any `href` or `url(...)` not `#id`
///   (embedded `data:` images only when the limits allow them), and
///   stylesheet processing instructions.
/// - Stylesheet rules that import or animate.
/// - Document types that declare entities (the entity-expansion bomb). An
///   external one is let through: nothing here or in the compiler fetches
///   it, and most exported SVG names the public one.
/// - Documents larger than the limits: elements, depth, and the element
///   count after `<use>` expansion, computed per referenced subtree so a
///   chain of uses that doubles at each step is caught without expanding it.
final class SvgSanitizer {
  /// Creates a sanitizer holding documents to [limits].
  const SvgSanitizer(this.limits);

  /// The caps documents are held to.
  final SvgLimits limits;

  static const Set<String> _forbiddenElements = {
    'script',
    'foreignobject',
    'iframe',
    'object',
    'embed',
    'audio',
    'video',
    'animate',
    'animatemotion',
    'animatetransform',
    'animatecolor',
    'set',
    'handler',
    'listener',
  };

  static final RegExp _url = RegExp(r'''url\(\s*['"]?([^'")]*)''');
  static final RegExp _animatingCss = RegExp(
    r'@import|@keyframes|\banimation',
    caseSensitive: false,
  );
  static final RegExp _embeddedImage = RegExp(
    '^data:image/(png|jpeg|jpg|webp|gif|bmp)[;,]',
    caseSensitive: false,
  );

  /// Null when [xml] may be drawn, otherwise why not.
  SvgRejection? check(String xml) {
    try {
      return _check(xml);
    } on XmlException catch (error) {
      return SvgRejection(SvgRejectionReason.notSvg, error.message);
    }
  }

  SvgRejection? _check(String xml) {
    // The document itself is the bottom frame: what is outside any element.
    final frames = <_Frame>[_Frame(null, inStyle: false)];
    final subtrees = <String, _Frame>{};
    var elements = 0;
    var sawRoot = false;
    for (final event in parseEvents(
      xml,
      validateNesting: true,
      validateDocument: true,
    )) {
      switch (event) {
        // An external document type (the public SVG one most exporters
        // write) is never fetched by this parser or the compiler's, so it
        // is harmless; declaring entities is how an expansion bomb starts.
        case XmlDoctypeEvent(:final internalSubset):
          if (internalSubset != null && internalSubset.contains('<!ENTITY')) {
            return const SvgRejection(SvgRejectionReason.doctype, 'ENTITY');
          }
        case XmlProcessingEvent(:final target)
            when target.toLowerCase() == 'xml-stylesheet':
          return const SvgRejection(
            SvgRejectionReason.externalReference,
            'xml-stylesheet',
          );
        case XmlStartElementEvent(
          :final name,
          :final attributes,
          :final isSelfClosing,
        ):
          final local = _local(name).toLowerCase();
          if (!sawRoot) {
            if (local != 'svg') {
              return SvgRejection(SvgRejectionReason.notSvg, 'root $name');
            }
            sawRoot = true;
          }
          if (_forbiddenElements.contains(local)) {
            return SvgRejection(SvgRejectionReason.element, name);
          }
          elements++;
          if (elements > limits.maxElements) {
            return SvgRejection(
              SvgRejectionReason.tooManyElements,
              '> ${limits.maxElements}',
            );
          }
          // The document frame does not count as a level.
          if (frames.length > limits.maxDepth) {
            return SvgRejection(
              SvgRejectionReason.tooDeep,
              '> ${limits.maxDepth}',
            );
          }
          String? id;
          String? useTarget;
          for (final attribute in attributes) {
            final attributeName = _local(attribute.name).toLowerCase();
            final value = attribute.value.trim();
            if (attributeName.startsWith('on')) {
              return SvgRejection(
                SvgRejectionReason.eventHandler,
                attribute.name,
              );
            }
            if (attributeName == 'href') {
              if (_reference(value) case final rejection?) return rejection;
              if (local == 'use' && value.startsWith('#')) {
                useTarget = value.substring(1);
              }
            }
            if (attributeName == 'id') id = value;
            if (_urls(value) case final rejection?) return rejection;
            if (attributeName == 'style') {
              if (_css(value) case final rejection?) return rejection;
            }
          }
          final frame = _Frame(id, inStyle: local == 'style');
          if (useTarget != null) frame.uses.add(useTarget);
          frames.add(frame);
          if (isSelfClosing) _close(frames, subtrees);
        case XmlEndElementEvent():
          _close(frames, subtrees);
        case XmlTextEvent(:final value) when frames.last.inStyle:
          if (_css(value) case final rejection?) return rejection;
        case XmlCDATAEvent(:final value) when frames.last.inStyle:
          if (_css(value) case final rejection?) return rejection;
        default:
      }
    }
    if (!sawRoot) {
      return const SvgRejection(SvgRejectionReason.notSvg, 'no root');
    }
    return _expansion(frames.single, subtrees);
  }

  // Ends the innermost element: its counts join its parent's, and an element
  // with an id is remembered as a subtree a `<use>` may expand.
  static void _close(List<_Frame> frames, Map<String, _Frame> subtrees) {
    final frame = frames.removeLast();
    if (frame.id case final id?) subtrees[id] = frame;
    frames.last
      ..elements += frame.elements
      ..uses.addAll(frame.uses);
  }

  // The element count with every use expanded: each subtree's expanded size
  // is computed once, so a chain that doubles at every step costs one pass
  // per link, and sums stop growing past the cap so they never overflow.
  SvgRejection? _expansion(_Frame document, Map<String, _Frame> subtrees) {
    final cap = limits.maxUseExpansion;
    final expanded = <String, int>{};
    final visiting = <String>{};
    var cycle = false;

    int sizeOf(String id) {
      if (expanded[id] case final known?) return known;
      final subtree = subtrees[id];
      // A use of nothing draws nothing.
      if (subtree == null) return 0;
      if (!visiting.add(id)) {
        cycle = true;
        return cap + 1;
      }
      var total = subtree.elements;
      for (final target in subtree.uses) {
        total = math.min(cap + 1, total + sizeOf(target));
        if (cycle || total > cap) break;
      }
      visiting.remove(id);
      return expanded[id] = total;
    }

    var total = document.elements - 1;
    for (final target in document.uses) {
      total = math.min(cap + 1, total + sizeOf(target));
      if (cycle) {
        return SvgRejection(
          SvgRejectionReason.useExpansion,
          'cycle at $target',
        );
      }
      if (total > cap) break;
    }
    if (total > cap) {
      return SvgRejection(SvgRejectionReason.useExpansion, '> $cap');
    }
    return null;
  }

  SvgRejection? _reference(String value) {
    if (value.isEmpty || value.startsWith('#')) return null;
    if (_embeddedImage.hasMatch(value)) {
      return limits.allowEmbeddedImages
          ? null
          : const SvgRejection(SvgRejectionReason.embeddedImage);
    }
    return SvgRejection(
      SvgRejectionReason.externalReference,
      value.length > 64 ? '${value.substring(0, 64)}...' : value,
    );
  }

  static SvgRejection? _urls(String value) {
    for (final match in _url.allMatches(value)) {
      final target = match.group(1)!.trim();
      if (!target.startsWith('#')) {
        return SvgRejection(
          SvgRejectionReason.externalReference,
          'url($target)',
        );
      }
    }
    return null;
  }

  static SvgRejection? _css(String css) {
    if (_animatingCss.firstMatch(css) case final match?) {
      return SvgRejection(SvgRejectionReason.stylesheet, match.group(0)!);
    }
    return _urls(css);
  }

  static String _local(String name) {
    final colon = name.indexOf(':');
    return colon < 0 ? name : name.substring(colon + 1);
  }
}

// One open element (or the document): its own and its descendants' element
// count, and the ids its subtree's uses reference.
final class _Frame {
  _Frame(this.id, {required this.inStyle});

  final String? id;
  final bool inStyle;
  int elements = 1;
  final List<String> uses = [];
}
