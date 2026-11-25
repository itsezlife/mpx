import 'package:flutter/widgets.dart';

/// What a [ViewerChangeTransition] does with a change.
enum ViewerChangeKind {
  /// The old widget fades out and the new one fades in, sliding by the
  /// direction of the change.
  crossfade,

  /// A text, by words from the start: the words that stayed stay.
  words,

  /// A text, by characters from the end: the digits that stayed stay.
  digits,
}

/// How a part of the viewer's chrome changes when the item does: how long it
/// takes, the curve, and how far the old and the new slide (the old goes one
/// way, the new comes from the other, by the direction the items change in).
///
/// The reference animates its title and its counter this way (320 ms,
/// ease-out-quint, an 8 px slide that follows the swipe) and crossfades its
/// caption (200 ms, no slide). A host gives any of them its own transition,
/// or [none].
@immutable
class ViewerChangeTransition {
  /// Creates a transition.
  const ViewerChangeTransition({
    required this.duration,
    this.curve = Curves.linear,
    this.distance = 0,
    this.kind = ViewerChangeKind.crossfade,
    this.amplitude = 0.3,
  });

  /// The title's and the counter's: 320 ms, ease-out-quint, 8 px.
  static const ViewerChangeTransition slide = ViewerChangeTransition(
    duration: Duration(milliseconds: 320),
    curve: Curves.easeOutQuint,
    distance: 8,
  );

  /// The date line's: the words that stayed stay, from the first that differs
  /// the rest is swapped, the old falling out and the new falling in, over
  /// 320 ms.
  static const ViewerChangeTransition words = ViewerChangeTransition(
    duration: Duration(milliseconds: 320),
    curve: Curves.easeOutQuint,
    kind: ViewerChangeKind.words,
    amplitude: 0.4,
  );

  /// The counter's: the digits that stayed stay, the ones that changed are
  /// swapped, over 320 ms.
  static const ViewerChangeTransition digits = ViewerChangeTransition(
    duration: Duration(milliseconds: 320),
    curve: Curves.easeOutQuint,
    kind: ViewerChangeKind.digits,
  );

  /// The caption's: a crossfade over 200 ms, in place.
  static const ViewerChangeTransition fade = ViewerChangeTransition(
    duration: Duration(milliseconds: 200),
    curve: Curves.easeInOut,
  );

  /// No transition: the new child is there at once.
  static const ViewerChangeTransition none = ViewerChangeTransition(
    duration: Duration.zero,
  );

  /// How long the change takes.
  final Duration duration;

  /// How it eases.
  final Curve curve;

  /// How far, in logical pixels, the old child leaves and the new comes in
  /// ([ViewerChangeKind.crossfade]).
  final double distance;

  /// What kind of change it is: a crossfade of two widgets, or an animated
  /// text that swaps the runs that differ.
  final ViewerChangeKind kind;

  /// How far a swapped run moves as it comes and goes, in text sizes
  /// ([ViewerChangeKind.words], [ViewerChangeKind.digits]).
  final double amplitude;

  @override
  bool operator ==(Object other) =>
      other is ViewerChangeTransition &&
      other.duration == duration &&
      other.curve == curve &&
      other.distance == distance &&
      other.kind == kind &&
      other.amplitude == amplitude;

  @override
  int get hashCode => Object.hash(duration, curve, distance, kind, amplitude);
}

/// Shows [child] and, when it is replaced by a child of another key, fades
/// the old one out and the new one in by [transition], sliding them by
/// [direction] (1 when the item moves to a later one, -1 to an earlier one).
///
/// What the viewer's chrome does for its own parts when the item changes; a
/// host with a widget of its own over the viewer (a badge, a label) uses it
/// for the same feel.
class ViewerChangeSwitcher extends StatefulWidget {
  /// Switches to [child] with [transition].
  const ViewerChangeSwitcher({
    required this.child,
    this.transition = ViewerChangeTransition.fade,
    this.direction = 1,
    this.alignment = AlignmentDirectional.centerStart,
    super.key,
  });

  /// What shows now; a changed key makes a change.
  final Widget child;

  /// How a change looks.
  final ViewerChangeTransition transition;

  /// 1 toward a later item, -1 toward an earlier one.
  final int direction;

  /// Where the old and the new sit in the room the larger takes.
  final AlignmentGeometry alignment;

  @override
  State<ViewerChangeSwitcher> createState() => _ViewerChangeSwitcherState();
}

class _ViewerChangeSwitcherState extends State<ViewerChangeSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Widget? _leaving;
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, value: 1)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && _leaving != null) {
          setState(() => _leaving = null);
        }
      });
  }

  @override
  void didUpdateWidget(ViewerChangeSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.child.key == oldWidget.child.key) return;
    final transition = widget.transition;
    if (transition.duration == Duration.zero) {
      _leaving = null;
      _controller.value = 1;
      return;
    }
    _leaving = oldWidget.child;
    _direction = widget.direction >= 0 ? 1 : -1;
    _controller
      ..duration = transition.duration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transition = widget.transition;
    final leaving = _leaving;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = transition.curve.transform(_controller.value);
        final slide = transition.distance * _direction;
        return Stack(
          alignment: widget.alignment,
          children: [
            if (leaving != null)
              Opacity(
                opacity: 1 - t,
                child: Transform.translate(
                  offset: Offset(-slide * t, 0),
                  child: leaving,
                ),
              ),
            Opacity(
              opacity: leaving == null ? 1 : t,
              child: Transform.translate(
                offset: Offset(leaving == null ? 0 : slide * (1 - t), 0),
                child: widget.child,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// What tells that a part of the chrome has changed: the host's widget, by
/// what it shows.
///
/// A plain [Text] is the same while its text is, so a title that two items
/// share does not animate when the item changes; a widget with a key is the
/// same while its key is; any other widget is taken to change with the item
/// ([fallback]).
abstract final class ViewerChangeKey {
  /// The key that [widget] has for a change of items, [fallback] when it has
  /// no content to tell by.
  static Key of(Widget? widget, Object fallback) {
    if (widget == null) return ValueKey<Object>(fallback);
    if (widget.key case final key?) return key;
    if (widget is Text) {
      final text = widget.data ?? widget.textSpan?.toPlainText();
      if (text != null) return ValueKey<String>('text:$text');
    }
    return ValueKey<Object>(fallback);
  }
}
