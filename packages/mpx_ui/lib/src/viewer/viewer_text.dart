import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// One run of a text change: a run that stayed ([previous] is null), or one
/// that is swapped ([previous] leaves, [next] comes; either may be empty).
@immutable
class ViewerTextSegment {
  /// Creates a segment.
  const ViewerTextSegment(this.next, [this.previous]);

  /// What the text has here now.
  final String next;

  /// What it had here, when this run changed; null when it stayed.
  final String? previous;

  /// Whether the run is the same in both texts.
  bool get stayed => previous == null;

  @override
  String toString() => stayed ? 'stayed($next)' : 'swapped($previous -> $next)';
}

/// What a text change keeps and what it swaps: the runs that are the same in
/// the old and the new text stay (and slide to their new place), and the rest
/// leaves and comes.
///
/// Two ways to tell, as a messenger's animated text has them: by words, from
/// the start (what the two texts start with stays, from the first word that
/// differs the rest is swapped), and by characters from the end (right-aligned
/// digits stay where they are, the digits that changed are swapped).
abstract final class ViewerTextDiff {
  /// The change from [previous] to [next] by words, from the start. Each word
  /// carries the space after it, so "hours" and "hours " are two words.
  static List<ViewerTextSegment> byWords(String next, String previous) =>
      _fromStart(_words(next), _words(previous));

  /// The change from [previous] to [next] by characters, from the end.
  static List<ViewerTextSegment> fromEnd(String next, String previous) {
    final n = next.split('');
    final o = previous.split('');
    final same = math.min(n.length, o.length);
    final nextFrom = n.length - same;
    final previousFrom = o.length - same;
    final segments = <ViewerTextSegment>[];
    var swappedNext = n.sublist(0, nextFrom).join();
    var swappedPrevious = o.sublist(0, previousFrom).join();
    var stayed = StringBuffer();

    void flushSwap() {
      if (swappedNext.isEmpty && swappedPrevious.isEmpty) return;
      segments.add(ViewerTextSegment(swappedNext, swappedPrevious));
      swappedNext = '';
      swappedPrevious = '';
    }

    void flushStay() {
      if (stayed.isEmpty) return;
      segments.add(ViewerTextSegment(stayed.toString()));
      stayed = StringBuffer();
    }

    for (var i = 0; i < same; i++) {
      final a = n[nextFrom + i];
      final b = o[previousFrom + i];
      if (a == b) {
        flushSwap();
        stayed.write(a);
      } else {
        flushStay();
        swappedNext += a;
        swappedPrevious += b;
      }
    }
    flushSwap();
    flushStay();
    return segments;
  }

  static List<String> _words(String text) {
    final words = <String>[];
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == ' ') {
        words.add(text.substring(start, i + 1));
        start = i + 1;
      }
    }
    if (start < text.length) words.add(text.substring(start));
    return words;
  }

  // The scan in step: two cursors walk the two lists; the old one moves only
  // while the units are the same, so after the first difference the new one
  // goes on alone, and the tail is one swapped run.
  static List<ViewerTextSegment> _fromStart(List<String> n, List<String> o) {
    final segments = <ViewerTextSegment>[];
    final smaller = math.min(n.length, o.length);
    var a = 0;
    var b = 0;
    var nextFrom = 0;
    var previousFrom = 0;
    var equal = true;
    void close(int nextTo, int previousTo) {
      final nextLength = nextTo - nextFrom;
      final previousLength = previousTo - previousFrom;
      if (nextLength == previousLength && equal) {
        final text = n.sublist(nextFrom, nextTo).join();
        if (text.isNotEmpty) segments.add(ViewerTextSegment(text));
      } else {
        final text = n.sublist(nextFrom, nextTo).join();
        final was = o.sublist(previousFrom, previousTo).join();
        if (text.isNotEmpty || was.isNotEmpty) {
          segments.add(ViewerTextSegment(text, was));
        }
      }
    }

    while (true) {
      final thisEqual = a < smaller && n[a] == o[b];
      if (equal != thisEqual || a == smaller) {
        if (a == smaller) {
          close(n.length, o.length);
          break;
        }
        close(a, b);
        equal = thisEqual;
        nextFrom = a;
        previousFrom = b;
      }
      if (thisEqual) b++;
      a++;
    }
    return segments;
  }
}

/// A single line of text whose changes are animated part by part, as a
/// messenger's animated text does: the runs the old and the new text share
/// stay and slide to their new place, the old run that goes fades out moving
/// down by a share of the text size, the new one fades in from above, from the
/// left to the right in a wave, and the width follows.
///
/// Used for the viewer's date line and its "N of M" counter; a host with a
/// text of its own over the viewer may use it too.
class ViewerAnimatedText extends StatefulWidget {
  /// Shows [text], animating a change of it.
  const ViewerAnimatedText(
    this.text, {
    required this.style,
    this.byWords = false,
    this.moveAmplitude = 0.3,
    this.duration = const Duration(milliseconds: 320),
    this.curve = Curves.easeOutQuint,
    this.textAlign = TextAlign.start,
    super.key,
  });

  /// The text.
  final String text;

  /// How it is drawn, over the ambient text style.
  final TextStyle style;

  /// Whether a change is told by words, from the start, instead of by
  /// characters from the end.
  final bool byWords;

  /// How far a run moves as it comes and goes, in text sizes.
  final double moveAmplitude;

  /// How long a change takes; zero does not animate.
  final Duration duration;

  /// How it eases.
  final Curve curve;

  /// Where the text sits while it is narrower than the room it is given.
  final TextAlign textAlign;

  @override
  State<ViewerAnimatedText> createState() => _ViewerAnimatedTextState();
}

class _Part {
  _Part(this.painter, this.offset, {this.partner});

  final TextPainter painter;

  /// Where it starts on its own side, from the left.
  final double offset;

  /// For a part that stayed, where it starts on the other side.
  final double? partner;
}

class _ViewerAnimatedTextState extends State<ViewerAnimatedText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  String _text = '';
  String? _previous;
  TextStyle? _resolved;
  TextScaler? _scaler;
  List<_Part> _stayed = const [];
  List<_Part> _added = const [];
  List<_Part> _removed = const [];
  double _widthNow = 0;
  double _widthBefore = 0;
  double _height = 0;

  @override
  void initState() {
    super.initState();
    _text = widget.text;
    _controller = AnimationController(vsync: this)
      ..addListener(() => setState(() {}))
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          setState(() => _previous = null);
        }
      });
  }

  @override
  void didUpdateWidget(ViewerAnimatedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == _text) return;
    _previous = _text;
    _text = widget.text;
    if (widget.duration == Duration.zero) {
      _previous = null;
      return;
    }
    _controller
      ..duration = widget.duration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    _disposeParts();
    super.dispose();
  }

  void _disposeParts() {
    for (final part in [..._stayed, ..._added, ..._removed]) {
      part.painter.dispose();
    }
    _stayed = const [];
    _added = const [];
    _removed = const [];
  }

  TextPainter _paint(String text, TextStyle style, TextScaler scaler) =>
      TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();

  // Parts of the text as it stands, and, while it changes, of the change.
  void _layout(TextStyle style, TextScaler scaler) {
    _disposeParts();
    final previous = _previous;
    final segments = previous == null
        ? [ViewerTextSegment(_text)]
        : widget.byWords
        ? ViewerTextDiff.byWords(_text, previous)
        : ViewerTextDiff.fromEnd(_text, previous);
    final stayed = <_Part>[];
    final added = <_Part>[];
    final removed = <_Part>[];
    var now = 0.0;
    var before = 0.0;
    for (final segment in segments) {
      if (segment.stayed) {
        final painter = _paint(segment.next, style, scaler);
        stayed.add(_Part(painter, now, partner: before));
        now += painter.width;
        before += painter.width;
        continue;
      }
      if (segment.next.isNotEmpty) {
        final painter = _paint(segment.next, style, scaler);
        added.add(_Part(painter, now));
        now += painter.width;
      }
      if (segment.previous!.isNotEmpty) {
        final painter = _paint(segment.previous!, style, scaler);
        removed.add(_Part(painter, before));
        before += painter.width;
      }
    }
    _stayed = stayed;
    _added = added;
    _removed = removed;
    _widthNow = now;
    _widthBefore = before;
    _height = [
      ...stayed,
      ...added,
      ...removed,
    ].fold<double>(0, (value, part) => math.max(value, part.painter.height));
    if (_height == 0) _height = _paint(' ', style, scaler).height;
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final scaler = MediaQuery.textScalerOf(context);
    if (_resolved != style ||
        _scaler != scaler ||
        _layoutFor != (_text, _previous)) {
      _resolved = style;
      _scaler = scaler;
      _layoutFor = (_text, _previous);
      _layout(style, scaler);
    }
    final raw = _previous == null ? 1.0 : _controller.value;
    final eased = widget.curve.transform(raw);
    final width = _previous == null
        ? _widthNow
        : _widthBefore + (_widthNow - _widthBefore) * eased;
    return Semantics(
      label: _text,
      child: ExcludeSemantics(
        child: CustomPaint(
          size: Size(width, _height),
          painter: _AnimatedTextPainter(
            stayed: _stayed,
            added: _added,
            removed: _removed,
            widthNow: _widthNow,
            widthBefore: _widthBefore,
            raw: raw,
            curve: widget.curve,
            amplitude: widget.moveAmplitude,
            textSize: style.fontSize ?? 14,
            animating: _previous != null,
          ),
        ),
      ),
    );
  }

  (String, String?)? _layoutFor;
}

class _AnimatedTextPainter extends CustomPainter {
  const _AnimatedTextPainter({
    required this.stayed,
    required this.added,
    required this.removed,
    required this.widthNow,
    required this.widthBefore,
    required this.raw,
    required this.curve,
    required this.amplitude,
    required this.textSize,
    required this.animating,
  });

  final List<_Part> stayed;
  final List<_Part> added;
  final List<_Part> removed;
  final double widthNow;
  final double widthBefore;
  final double raw;
  final Curve curve;
  final double amplitude;
  final double textSize;
  final bool animating;

  // Each run that comes or goes has its own window of the change, from the
  // left to the right: as long as the text is tall, in the width of the
  // longer of the two texts.
  double _local(double offset) {
    final total = math.max(widthNow, widthBefore);
    if (total <= 0) return curve.transform(raw);
    final window = math.min(textSize, total) / total;
    final start = offset / total * (1 - window);
    return curve.transform(((raw - start) / window).clamp(0.0, 1.0));
  }

  void _draw(Canvas canvas, _Part part, double x, double y, double alpha) {
    if (alpha <= 0) return;
    if (alpha >= 1) {
      part.painter.paint(canvas, Offset(x, y));
      return;
    }
    canvas.saveLayer(
      Offset(x, y) & Size(part.painter.width, part.painter.height),
      Paint()..color = Color.fromRGBO(0, 0, 0, alpha),
    );
    part.painter.paint(canvas, Offset(x, y));
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final eased = curve.transform(raw);
    for (final part in stayed) {
      final x = animating
          ? part.partner! + (part.offset - part.partner!) * eased
          : part.offset;
      _draw(canvas, part, x, 0, 1);
    }
    final shift = textSize * amplitude;
    for (final part in added) {
      final local = animating ? _local(part.offset) : 1.0;
      _draw(canvas, part, part.offset, -shift * (1 - local), local);
    }
    if (!animating) return;
    for (final part in removed) {
      final local = _local(part.offset);
      _draw(canvas, part, part.offset, shift * local, 1 - local);
    }
  }

  @override
  bool shouldRepaint(_AnimatedTextPainter old) => true;
}
