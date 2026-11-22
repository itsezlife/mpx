import 'package:flutter/widgets.dart';

/// Where a viewer tells the scale the surfaces behind it are drawn at
/// (`ViewerPolicy.backdropScale`), for every [ViewerBackdropZoom] below.
///
/// A host puts it above its navigator (an app's builder), so a viewer pushed
/// as a route and the pages under it share it; a viewer given its own
/// `onBackdropScale` reports there instead.
class ViewerBackdropScope extends StatefulWidget {
  /// Shares a backdrop scale with [child].
  const ViewerBackdropScope({required this.child, super.key});

  /// The app, or the part that holds the viewer and the surfaces it covers.
  final Widget child;

  /// The scale of the nearest scope above [context], or null.
  static ValueNotifier<double>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ViewerBackdropInherited>()?.scale;

  @override
  State<ViewerBackdropScope> createState() => _ViewerBackdropScopeState();
}

class _ViewerBackdropScopeState extends State<ViewerBackdropScope> {
  final _Scale _scale = _Scale();

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _ViewerBackdropInherited(scale: _scale, child: widget.child);
}

class _ViewerBackdropInherited extends InheritedWidget {
  const _ViewerBackdropInherited({required this.scale, required super.child});

  final ValueNotifier<double> scale;

  @override
  bool updateShouldNotify(_ViewerBackdropInherited oldWidget) =>
      !identical(scale, oldWidget.scale);
}

/// A surface a viewer covers, drawn at the scale the viewer reports through
/// the nearest [ViewerBackdropScope]: it grows a little about its centre as
/// the viewer opens and settles back as a dismiss drag pulls the picture
/// away. Without a scope it is drawn as it is.
class ViewerBackdropZoom extends StatelessWidget {
  /// Zooms [child] with the viewer above it.
  const ViewerBackdropZoom({required this.child, super.key});

  /// The surface.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = ViewerBackdropScope.maybeOf(context);
    if (scale == null) return child;
    // Always the same transform, at 1 too: a wrapper that came and went
    // with the scale would rebuild the surface's whole subtree, its state
    // with it, each time a viewer opened.
    return ValueListenableBuilder<double>(
      valueListenable: scale,
      child: child,
      builder: (context, value, child) =>
          Transform.scale(scale: value, child: child),
    );
  }
}

// A scale a viewer may still set after the scope went (its reset after the
// frame it was removed in): ignored then.
final class _Scale extends ValueNotifier<double> {
  _Scale() : super(1);

  bool _gone = false;

  @override
  set value(double value) {
    if (!_gone) super.value = value;
  }

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }
}
