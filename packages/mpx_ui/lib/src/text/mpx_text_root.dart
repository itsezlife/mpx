import 'package:flutter/material.dart';

/// The text root of every surface mpx_ui builds or pushes: a route, an
/// overlay, a popup, and the picker's own widgets.
///
/// A pushed route sits outside the widget that pushed it, so the text style
/// around that widget does not reach it; a Material app then draws its text
/// in the framework's fallback (red, monospace, a yellow double underline).
/// The root takes the ambient [DefaultTextStyle] of the context it is given
/// (the pusher's, captured before the push), or the theme's body style when
/// that is a fallback, and never underlines. Widget text styles from the
/// tokens merge over it, so the host's font family carries through.
abstract final class MpxTextRoot {
  /// The style a surface over [context] starts from.
  static TextStyle styleOf(BuildContext context) {
    final ambient = DefaultTextStyle.of(context).style;
    final base = isFallback(ambient)
        ? Theme.of(context).textTheme.bodyMedium ?? const TextStyle()
        : ambient;
    return base.copyWith(
      decoration: TextDecoration.none,
      fontSize: base.fontSize ?? 14,
    );
  }

  /// Whether [style] is a fallback no text root set: underlined,
  /// monospace, or without a size.
  static bool isFallback(TextStyle style) {
    final decoration = style.decoration;
    return (decoration != null && decoration != TextDecoration.none) ||
        style.fontFamily == 'monospace' ||
        style.fontSize == null;
  }

  /// [child] under the root of [context].
  static Widget wrap(BuildContext context, Widget child) =>
      DefaultTextStyle(style: styleOf(context), child: child);

  /// [child] under a root of [style], captured from the pusher's context
  /// ([styleOf]) before a route is pushed.
  static Widget over(TextStyle style, Widget child) =>
      DefaultTextStyle(style: style, child: child);
}
