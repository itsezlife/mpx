import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/src/text/mpx_text_root.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/viewer_actions.dart';
import 'package:mpx_ui/src/viewer/viewer_caption.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';
import 'package:mpx_ui/src/viewer/viewer_tokens.dart';

/// The chrome the viewer draws over its pages: the top bar (back, title and
/// subtitle, bar actions, the overflow button), the "N of M" counter, the
/// caption and the thumbnail strip, and the overflow menu. It shows and
/// hides with [controls], sliding the top up and the bottom down.
class ViewerChromeOverlay extends StatefulWidget {
  /// Creates the chrome of the item at [index].
  const ViewerChromeOverlay({
    required this.chrome,
    required this.index,
    required this.source,
    required this.controls,
    required this.tokens,
    required this.policy,
    required this.onBack,
    required this.onSelectIndex,
    required this.onAction,
    super.key,
    this.scope,
    this.bottomInset = 0,
    this.settingsOpen,
    this.settingsLabel = 'Settings',
    this.onMenuChanged,
  });

  /// What the host fills in.
  final ViewerChrome chrome;

  /// The item shown.
  final int index;

  /// The gallery.
  final GallerySource source;

  /// Whether the chrome shows.
  final ValueListenable<bool> controls;

  /// Colours and type.
  final ViewerTokens tokens;

  /// Timings and layout.
  final ViewerPolicy policy;

  /// The back button.
  final VoidCallback onBack;

  /// A thumbnail was tapped.
  final ValueChanged<int> onSelectIndex;

  /// An action was chosen for [index].
  final void Function(ViewerAction action, int index) onAction;

  /// The cache the thumbnails attach to.
  final AssetCacheScope? scope;

  /// Room left at the bottom for the video controls.
  final double bottomInset;

  /// Whether the video's settings are open: when given, the top bar has the
  /// button that opens them, before the overflow button.
  final ValueNotifier<bool>? settingsOpen;

  /// The settings button's semantic label.
  final String settingsLabel;

  /// Told when the overflow menu opens or closes, so the viewer keeps its
  /// controls while it is open.
  final ValueChanged<bool>? onMenuChanged;

  @override
  State<ViewerChromeOverlay> createState() => _ViewerChromeOverlayState();
}

class _ViewerChromeOverlayState extends State<ViewerChromeOverlay> {
  bool _menuState = false;

  bool get _menuOpen => _menuState;
  set _menuOpen(bool value) {
    if (value == _menuState) return;
    _menuState = value;
    // Told after the frame: a close from a rebuild must not rebuild the
    // viewer that is building it.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.onMenuChanged?.call(_menuState),
    );
  }

  @override
  void initState() {
    super.initState();
    widget.controls.addListener(_controlsChanged);
  }

  @override
  void didUpdateWidget(ViewerChromeOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controls, widget.controls)) {
      oldWidget.controls.removeListener(_controlsChanged);
      widget.controls.addListener(_controlsChanged);
    }
    if (oldWidget.index != widget.index) _menuOpen = false;
  }

  @override
  void dispose() {
    widget.controls.removeListener(_controlsChanged);
    super.dispose();
  }

  void _controlsChanged() {
    if (!mounted) return;
    setState(() {
      if (!widget.controls.value) _menuOpen = false;
    });
  }

  List<ViewerAction> _actions(GalleryItem item) =>
      widget.chrome.actions?.call(widget.index, item) ?? const [];

  @override
  Widget build(BuildContext context) => MpxTextRoot.wrap(
    context,
    DefaultTextStyle.merge(
      style: widget.tokens.subtitle,
      child: _build(context),
    ),
  );

  Widget _build(BuildContext context) {
    final item = widget.source.itemAt(widget.index);
    final visible = widget.controls.value;
    final padding = MediaQuery.paddingOf(context);
    final metrics = widget.policy.chrome;
    final actions = item == null ? const <ViewerAction>[] : _actions(item);
    final menu = [
      for (final action in actions)
        if (!action.inBar) action,
    ];
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: _Shown(
            visible: visible,
            slide: -widget.policy.controlsSlide,
            duration: widget.policy.controlsDuration,
            hideDuration: widget.policy.controlsHideDuration,
            child: Column(
              key: const ValueKey('mpx-viewer-top'),
              mainAxisSize: MainAxisSize.min,
              children: [
                _topBar(context, item, actions, menu, padding.top),
                if (widget.source.count > 1) _counter(metrics),
              ],
            ),
          ),
        ),
        if (item != null)
          if (_caption(context, item, metrics, padding) case final caption?)
            Positioned(
              left: 0,
              right: 0,
              // Under the top bar and its counter, over the strip, the video
              // controls and the navigation bar: the room a drag grows it in.
              top:
                  padding.top +
                  metrics.topBarHeight +
                  (widget.source.count > 1
                      ? metrics.counterGap + metrics.counterHeight
                      : 0),
              bottom:
                  padding.bottom +
                  widget.bottomInset +
                  (widget.chrome.thumbnails && widget.source.count > 1
                      ? metrics.stripHeight
                      : 0),
              child: _Shown(
                visible: visible,
                slide: widget.policy.controlsSlide,
                duration: widget.policy.controlsDuration,
                hideDuration: widget.policy.controlsHideDuration,
                child: caption,
              ),
            ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _Shown(
            visible: visible,
            slide: widget.policy.controlsSlide,
            duration: widget.policy.controlsDuration,
            hideDuration: widget.policy.controlsHideDuration,
            child: Column(
              key: const ValueKey('mpx-viewer-bottom'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.chrome.thumbnails && widget.source.count > 1)
                  _strip(metrics),
                SizedBox(height: widget.bottomInset),
                // The navigation bar's scrim, the bars' fill, as the top
                // bar's covers the status bar: the system bar itself is
                // clear and the picture runs on under it.
                ColoredBox(
                  key: const ValueKey('mpx-viewer-navigation-scrim'),
                  color: widget.tokens.barFill,
                  child: SizedBox(
                    width: double.infinity,
                    height: padding.bottom,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_menuOpen && visible) ..._menu(menu, padding.top, metrics),
      ],
    );
  }

  Widget _topBar(
    BuildContext context,
    GalleryItem? item,
    List<ViewerAction> actions,
    List<ViewerAction> menu,
    double top,
  ) {
    final tokens = widget.tokens;
    final metrics = widget.policy.chrome;
    final chrome = widget.chrome;
    final title = item == null
        ? null
        : chrome.title?.call(context, widget.index, item);
    final subtitle = item == null
        ? null
        : chrome.subtitle?.call(context, widget.index, item);
    return ColoredBox(
      color: tokens.barFill,
      child: Padding(
        padding: EdgeInsets.only(top: top),
        child: SizedBox(
          height: metrics.topBarHeight,
          child: Row(
            children: [
              _button(
                key: const ValueKey('mpx-viewer-back'),
                label: chrome.strings.back,
                icon: chrome.backIcon ?? _Glyph.back(tokens.foreground),
                onTap: widget.onBack,
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      DefaultTextStyle.merge(
                        style: tokens.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: title,
                      ),
                    if (subtitle != null)
                      DefaultTextStyle.merge(
                        style: tokens.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        child: subtitle,
                      ),
                  ],
                ),
              ),
              for (final action in actions)
                if (action.inBar)
                  _button(
                    label: action.label,
                    icon: action.icon!,
                    onTap: () => widget.onAction(action, widget.index),
                  ),
              if (widget.settingsOpen case final open?)
                _button(
                  key: const ValueKey('mpx-viewer-settings'),
                  label: widget.settingsLabel,
                  icon:
                      chrome.settingsIcon ?? _Glyph.settings(tokens.foreground),
                  onTap: () => open.value = !open.value,
                ),
              if (menu.isNotEmpty)
                _button(
                  key: const ValueKey('mpx-viewer-more'),
                  label: chrome.strings.more,
                  icon: chrome.moreIcon ?? _Glyph.more(tokens.foreground),
                  onTap: () => setState(() => _menuOpen = !_menuOpen),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button({
    required String label,
    required Widget icon,
    required VoidCallback onTap,
    Key? key,
  }) {
    final extent = widget.policy.chrome.topBarHeight;
    return Semantics(
      key: key,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox.square(
          dimension: extent,
          child: Center(
            child: IconTheme(
              data: IconThemeData(color: widget.tokens.foreground, size: 24),
              child: icon,
            ),
          ),
        ),
      ),
    );
  }

  Widget _counter(ViewerChromeMetrics metrics) {
    final text = widget.chrome.strings.counter(
      widget.index + 1,
      widget.source.count,
    );
    return Padding(
      padding: EdgeInsets.only(top: metrics.counterGap),
      child: Container(
        key: const ValueKey('mpx-viewer-counter'),
        height: metrics.counterHeight,
        padding: EdgeInsets.symmetric(horizontal: metrics.counterPadding),
        decoration: BoxDecoration(
          color: widget.tokens.barFill,
          borderRadius: BorderRadius.circular(metrics.counterRadius),
        ),
        // As wide as its text: an alignment on the box itself would stretch
        // the pill across the column, a bar that shows once a zoomed
        // picture lies under it.
        child: Align(
          widthFactor: 1,
          child: Text(text, style: widget.tokens.counter),
        ),
      ),
    );
  }

  Widget? _caption(
    BuildContext context,
    GalleryItem item,
    ViewerChromeMetrics metrics,
    EdgeInsets padding,
  ) {
    final caption = widget.chrome.caption?.call(context, widget.index, item);
    if (caption == null) return null;
    final style = widget.tokens.caption;
    final line = (style.fontSize ?? 16) * (style.height ?? 1.2);
    // The first height is the metric's lines (two in landscape, as the
    // reference); a longer caption grows from it under a drag.
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final lines = landscape
        ? math.min(2, metrics.captionMaxLines)
        : metrics.captionMaxLines;
    return ViewerCaptionSheet(
      boxKey: const ValueKey('mpx-viewer-caption'),
      fill: widget.tokens.barFill,
      padding: metrics.captionPadding,
      collapsedHeight: line * lines + metrics.captionPadding.vertical,
      child: DefaultTextStyle.merge(style: style, child: caption),
    );
  }

  Widget _strip(ViewerChromeMetrics metrics) {
    final thumb = metrics.thumbSize;
    return SizedBox(
      key: const ValueKey('mpx-viewer-strip'),
      height: metrics.stripHeight,
      child: ColoredBox(
        color: widget.tokens.barFill,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          itemCount: widget.source.count,
          padding: EdgeInsets.only(top: metrics.thumbTop),
          itemBuilder: (context, index) {
            final item = widget.source.itemAt(index);
            final current = index == widget.index;
            final aspect = switch (item?.size) {
              final size? when !size.isEmpty => size.width / size.height,
              _ => thumb.width / thumb.height,
            };
            final width = current
                ? math.min(metrics.currentThumbMaxWidth, thumb.height * aspect)
                : thumb.width;
            final gap = current
                ? metrics.currentThumbPadding
                : metrics.thumbSpacing / 2;
            return GestureDetector(
              key: ValueKey(('mpx-viewer-thumb', index)),
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onSelectIndex(index),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: gap),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(metrics.thumbRadius),
                    child: SizedBox(
                      width: width,
                      height: thumb.height,
                      child: item == null
                          ? ColoredBox(color: widget.tokens.placeholder)
                          : AssetView(
                              content: item.key,
                              scope: widget.scope,
                              preset: AssetPresets.media(
                                size: Size(width, thumb.height),
                                devicePixelRatio:
                                    MediaQuery.maybeDevicePixelRatioOf(
                                      context,
                                    ) ??
                                    1,
                                profile: const AssetProfile(
                                  fit: AssetFit.cover,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _menu(
    List<ViewerAction> menu,
    double top,
    ViewerChromeMetrics metrics,
  ) {
    final tokens = widget.tokens;
    return [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _menuOpen = false),
        ),
      ),
      Positioned(
        top: top + 4,
        right: 4,
        child: Container(
          key: const ValueKey('mpx-viewer-menu'),
          constraints: BoxConstraints(minWidth: metrics.menuMinWidth),
          color: tokens.menuBackground,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final action in menu)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() => _menuOpen = false);
                      widget.onAction(action, widget.index);
                    },
                    child: SizedBox(
                      height: metrics.menuItemHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            if (action.icon != null) ...[
                              IconTheme(
                                data: IconThemeData(
                                  color: tokens.menuForeground,
                                  size: 24,
                                ),
                                child: action.icon!,
                              ),
                              const SizedBox(width: 16),
                            ],
                            Text(
                              action.label,
                              style: tokens.subtitle.copyWith(
                                color: tokens.menuForeground,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

// Slides [child] by [slide] and fades it out when not [visible], and stops it
// taking touches.
class _Shown extends StatelessWidget {
  const _Shown({
    required this.visible,
    required this.slide,
    required this.duration,
    required this.hideDuration,
    required this.child,
  });

  final bool visible;
  final double slide;
  final Duration duration;
  final Duration hideDuration;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: TweenAnimationBuilder<double>(
      tween: Tween(end: visible ? 1 : 0),
      duration: visible ? duration : hideDuration,
      builder: (context, t, child) => Transform.translate(
        offset: Offset(0, slide * (1 - t)),
        child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
      ),
      child: child,
    ),
  );
}

// A plain glyph for a host that brings no icons: a back arrow or three dots.
class _Glyph extends StatelessWidget {
  const _Glyph.back(this.color) : _kind = _GlyphKind.back;

  const _Glyph.more(this.color) : _kind = _GlyphKind.more;

  const _Glyph.settings(this.color) : _kind = _GlyphKind.settings;

  final Color color;
  final _GlyphKind _kind;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(24),
    painter: _GlyphPainter(color, _kind),
  );
}

enum _GlyphKind { back, more, settings }

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.color, this.kind);

  final Color color;
  final _GlyphKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final w = size.width;
    final h = size.height;
    switch (kind) {
      case _GlyphKind.back:
        canvas
          ..drawLine(Offset(w * 0.2, h / 2), Offset(w * 0.8, h / 2), paint)
          ..drawLine(Offset(w * 0.2, h / 2), Offset(w * 0.45, h * 0.25), paint)
          ..drawLine(Offset(w * 0.2, h / 2), Offset(w * 0.45, h * 0.75), paint);
      case _GlyphKind.more:
        paint.style = PaintingStyle.fill;
        for (final y in [0.25, 0.5, 0.75]) {
          canvas.drawCircle(Offset(w / 2, h * y), 2, paint);
        }
      case _GlyphKind.settings:
        // Two sliders: a line each, with a knob.
        canvas
          ..drawLine(
            Offset(w * 0.1, h * 0.32),
            Offset(w * 0.9, h * 0.32),
            paint,
          )
          ..drawLine(
            Offset(w * 0.1, h * 0.68),
            Offset(w * 0.9, h * 0.68),
            paint,
          );
        paint
          ..style = PaintingStyle.fill
          ..strokeWidth = 0;
        canvas
          ..drawCircle(Offset(w * 0.68, h * 0.32), 3.2, paint)
          ..drawCircle(Offset(w * 0.32, h * 0.68), 3.2, paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.kind != kind;
}
