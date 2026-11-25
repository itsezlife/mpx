import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show kMinInteractiveDimension;
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/text/mpx_text_root.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';
import 'package:mpx_ui/src/viewer/viewer_seek.dart';
import 'package:mpx_ui/src/viewer/viewer_tokens.dart';

/// One quality of a video the host offers: a label ("720p", "Auto") and the
/// media that plays it. Choosing one moves the player to [key] at the same
/// position.
@immutable
final class ViewerQuality {
  /// Creates a quality.
  const ViewerQuality({required this.label, required this.key});

  /// What the quality list shows.
  final String label;

  /// The media of this quality.
  final MediaKey key;

  @override
  bool operator ==(Object other) =>
      other is ViewerQuality && other.label == label && other.key == key;

  @override
  int get hashCode => Object.hash(label, key);
}

/// Gives the frame of [key] at [position] for the seek preview, or null when
/// there is none (no storyboard, not decoded yet).
typedef ViewerPreviewFrame =
    Future<ui.Image?> Function(MediaKey key, Duration position);

/// The playback speeds chosen in viewers, kept as the policy's
/// [ViewerSpeedMemory] says: per item, for one viewer, or for the session.
///
/// A viewer makes its own when the host passes none; a host that wants the
/// session-wide speed to outlive one viewer keeps one instance and passes it
/// to every viewer.
final class ViewerSpeeds {
  final Map<MediaKey, double> _perItem = {};
  double _shared = 1;
  double _global = 1;

  /// The speed [key] starts at under [memory].
  double speedFor(MediaKey key, ViewerSpeedMemory memory) => switch (memory) {
    ViewerSpeedMemory.perItem => _perItem[key] ?? 1,
    ViewerSpeedMemory.shared => _shared,
    ViewerSpeedMemory.global => _global,
  };

  /// Records [speed] chosen for [key] under [memory].
  void remember(MediaKey key, double speed, ViewerSpeedMemory memory) {
    switch (memory) {
      case ViewerSpeedMemory.perItem:
        if (speed == 1) {
          _perItem.remove(key);
        } else {
          _perItem[key] = speed;
        }
      case ViewerSpeedMemory.shared:
        _shared = speed;
      case ViewerSpeedMemory.global:
        _global = speed;
    }
  }

  /// Starts a viewer: the speed shared by its items starts at normal again.
  void beginViewer() => _shared = 1;
}

/// The texts of the video controls.
@immutable
final class ViewerVideoStrings {
  /// Creates strings; the defaults are English.
  const ViewerVideoStrings({
    this.play = 'Play',
    this.pause = 'Pause',
    this.speed = 'Speed',
    this.quality = 'Quality',
    this.settings = 'Settings',
    this.failed = 'This video could not be played',
    this.retry = 'Retry',
    this.openElsewhere = 'Open',
    this.cancel = 'Cancel',
  });

  /// The play button's semantic label.
  final String play;

  /// The pause button's semantic label.
  final String pause;

  /// The speed button's semantic label.
  final String speed;

  /// The quality button's semantic label, and the heading of its list.
  final String quality;

  /// The settings button's semantic label.
  final String settings;

  /// The heading of the speed list in the settings.
  String get speedHeading => speed;

  /// What a video that failed to play says over its picture.
  final String failed;

  /// The button that tries a failed video again.
  final String retry;

  /// The alert's button that opens a video that cannot be played in another
  /// app.
  final String openElsewhere;

  /// The alert's button that leaves it.
  final String cancel;
}

/// A tap target of at least [kMinInteractiveDimension] on each side around
/// [child], with a highlight while pressed: the viewer's buttons that are no
/// more than a word.
class ViewerTapTarget extends StatefulWidget {
  /// Calls [onTap] for a tap anywhere in the target.
  const ViewerTapTarget({
    required this.onTap,
    required this.child,
    this.highlight = const Color(0x33FFFFFF),
    this.selected = false,
    this.selectedFill = const Color(0x1FFFFFFF),
    super.key,
  });

  /// Called on a tap.
  final VoidCallback onTap;

  /// What the target shows.
  final Widget child;

  /// The fill while pressed.
  final Color highlight;

  /// Whether the target is the one chosen: it keeps [selectedFill].
  final bool selected;

  /// The fill of a chosen target.
  final Color selectedFill;

  @override
  State<ViewerTapTarget> createState() => _ViewerTapTargetState();
}

class _ViewerTapTargetState extends State<ViewerTapTarget> {
  bool _pressed = false;

  void _press(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: widget.onTap,
    onTapDown: (_) => _press(true),
    onTapUp: (_) => _press(false),
    onTapCancel: () => _press(false),
    child: ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: kMinInteractiveDimension,
        minHeight: kMinInteractiveDimension,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _pressed
              ? widget.highlight
              : widget.selected
              ? widget.selectedFill
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(child: widget.child),
      ),
    ),
  );
}

/// What a video that failed to play shows over its picture under
/// `ViewerVideoFailure.card` (an alert without another app to open it in
/// too): [ViewerVideoStrings.failed] and a retry.
class ViewerVideoFailureCard extends StatelessWidget {
  /// Shows the failure, calling [onRetry] for the retry.
  const ViewerVideoFailureCard({
    required this.strings,
    required this.tokens,
    required this.onRetry,
    super.key,
  });

  /// The texts.
  final ViewerVideoStrings strings;

  /// The colours and type.
  final ViewerTokens tokens;

  /// Called by the retry.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('mpx-viewer-video-failed'),
    decoration: BoxDecoration(
      color: tokens.menuBackground,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            strings.failed,
            style: tokens.subtitle,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Semantics(
            button: true,
            child: ViewerTapTarget(
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  strings.retry,
                  style: tokens.subtitle.copyWith(color: tokens.link),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The alert of `ViewerVideoFailure.alert`: [ViewerVideoStrings.failed]
/// and the choice to open the video in another app ([onOpen]) or leave it
/// ([onCancel]), which dismisses it for [session] (the page keeps its
/// picture; play tries again).
class ViewerVideoFailureAlert extends StatelessWidget {
  /// Shows the alert of [session] until [dismissed] names it.
  const ViewerVideoFailureAlert({
    required this.strings,
    required this.tokens,
    required this.onOpen,
    required this.onCancel,
    required this.dismissed,
    required this.session,
    super.key,
  });

  /// The texts.
  final ViewerVideoStrings strings;

  /// The colours and type.
  final ViewerTokens tokens;

  /// Opens the video elsewhere.
  final VoidCallback onOpen;

  /// Leaves the alert.
  final VoidCallback onCancel;

  /// The session whose alert was left, if any.
  final ValueListenable<Object?> dismissed;

  /// The session the alert is for.
  final Object session;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Object?>(
    valueListenable: dismissed,
    builder: (context, left, _) => identical(left, session)
        ? const SizedBox.shrink()
        : DecoratedBox(
            key: const ValueKey('mpx-viewer-video-failed-alert'),
            decoration: BoxDecoration(
              color: tokens.menuBackground,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(strings.failed, style: tokens.subtitle),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (label, onTap, key) in [
                        (strings.cancel, onCancel, 'cancel'),
                        (strings.openElsewhere, onOpen, 'open'),
                      ])
                        Semantics(
                          button: true,
                          child: ViewerTapTarget(
                            key: ValueKey('mpx-viewer-video-failed-$key'),
                            onTap: onTap,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Text(
                                label,
                                style: tokens.subtitle.copyWith(
                                  color: tokens.link,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
  );
}

/// The controls over a video in the viewer: the play button in the middle,
/// and at the bottom the seek bar, the time, the speed and the quality.
///
/// Dragging the seek bar moves a preview (the time and, with
/// [previewFrame], the frame there); the seek happens on release. Every
/// touch is reported to [onInteraction], so the viewer restarts its
/// auto-hide.
class ViewerVideoControls extends StatefulWidget {
  /// Creates the controls of [lease].
  const ViewerVideoControls({
    required this.lease,
    required this.rules,
    required this.tokens,
    required this.visible,
    required this.showDuration,
    required this.hideDuration,
    required this.onInteraction,
    required this.onSpeed,
    super.key,
    this.slide = 0,
    this.settingsTop = 0,
    this.settingsOpen,
    this.settingsButton = true,
    this.qualities = const [],
    this.quality,
    this.onQuality,
    this.previewFrame,
    this.strings = const ViewerVideoStrings(),
    this.centreTaken,
    this.captionTop,
    this.knownDuration,
  });

  /// The item's length as its descriptor gives it, which the time and the
  /// seek bar read until the player reports one: a video still downloading
  /// reads "0:00 / 0:52", not "0:00 / 0:00".
  final Duration? knownDuration;

  /// How much of the centre another control takes, 0 to 1: the buffering
  /// spinner as it fades in ([ViewerBufferingSpinner.presence]). The play
  /// button fades out by as much and takes no taps while any is taken, so
  /// the centre shows one control. Null leaves the button alone.
  final ValueListenable<double>? centreTaken;

  /// Where the viewer's caption starts on the screen (its top edge's y): the
  /// play button fades while the caption is over it and comes back when it
  /// is not.
  final ValueListenable<double>? captionTop;

  /// The player.
  final PlayerLease lease;

  /// The policy's video rules: speeds and seek preview.
  final ViewerVideoRules rules;

  /// Colours and type.
  final ViewerTokens tokens;

  /// Whether the controls show.
  final bool visible;

  /// How long the controls take to show.
  final Duration showDuration;

  /// How long the controls take to hide.
  final Duration hideDuration;

  /// How far the bottom bar slides down as it hides.
  final double slide;

  /// Where the settings panel sits from the top of the controls: under the
  /// viewer's own top bar, which is the host's to measure.
  final double settingsTop;

  /// Whether the settings panel is open. The host owns it, so a button in
  /// its own bar can open it; the controls close it on a choice, on a tap
  /// outside and when they hide. Their own state when null.
  final ValueNotifier<bool>? settingsOpen;

  /// Whether the controls draw the button that opens the settings: not when
  /// the host's bar has it.
  final bool settingsButton;

  /// Any touch on the controls.
  final VoidCallback onInteraction;

  /// A speed was chosen.
  final ValueChanged<double> onSpeed;

  /// The qualities offered; no quality button when there are fewer than
  /// two.
  final List<ViewerQuality> qualities;

  /// The quality playing.
  final ViewerQuality? quality;

  /// A quality was chosen.
  final ValueChanged<ViewerQuality>? onQuality;

  /// The seek preview's frames; the preview shows the time only when null.
  final ViewerPreviewFrame? previewFrame;

  /// The texts.
  final ViewerVideoStrings strings;

  /// The height of the bottom bar.
  static const double barHeight = 48;

  /// The diameter of the play button.
  static const double playButtonSize = 64;

  @override
  State<ViewerVideoControls> createState() => ViewerVideoControlsState();
}

/// The state of [ViewerVideoControls]; the preview position is readable for
/// tests.
class ViewerVideoControlsState extends State<ViewerVideoControls>
    with SingleTickerProviderStateMixin {
  // The playhead and the seek: read every frame, never pushed (the player's
  // rule), and the bar's drag only moves a preview until the finger leaves.
  late final ViewerSeekController _seek;
  ui.Image? _previewImage;
  int _previewRequest = 0;
  // The preview the frame was asked for last.
  Duration? _previewed;
  late final ValueNotifier<bool> _ownSettings = ValueNotifier(false);
  ValueNotifier<bool> get _settings => widget.settingsOpen ?? _ownSettings;

  /// Where a seek-bar drag would seek; null while none is in progress.
  Duration? get preview => _seek.preview;

  @override
  void initState() {
    super.initState();
    _seek = ViewerSeekController(
      vsync: this,
      lease: widget.lease,
      knownDuration: widget.knownDuration,
      onInteraction: widget.onInteraction,
    )..addListener(_onSeek);
    widget.lease.state.addListener(_onState);
    _settings.addListener(_onState);
  }

  @override
  void didUpdateWidget(ViewerVideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    _seek
      ..knownDuration = widget.knownDuration
      ..onInteraction = widget.onInteraction
      ..lease = widget.lease;
    if (!identical(oldWidget.lease, widget.lease)) {
      oldWidget.lease.state.removeListener(_onState);
      widget.lease.state.addListener(_onState);
      _onState();
    }
    if (!identical(oldWidget.settingsOpen, widget.settingsOpen)) {
      (oldWidget.settingsOpen ?? _ownSettings).removeListener(_onState);
      _settings.addListener(_onState);
    }
    if (!widget.visible) _settings.value = false;
  }

  @override
  void dispose() {
    widget.lease.state.removeListener(_onState);
    _settings.removeListener(_onState);
    _ownSettings.dispose();
    _seek
      ..removeListener(_onSeek)
      ..dispose();
    _previewImage?.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {});
  }

  // The seek controller tells of every frame of the playhead; the controls
  // act on the preview alone: the frame at it, and the box that shows it.
  void _onSeek() {
    final preview = _seek.preview;
    if (preview == _previewed) return;
    _previewed = preview;
    setState(() {});
    if (preview == null) {
      _previewRequest++;
      _previewImage?.dispose();
      _previewImage = null;
      return;
    }
    final frames = widget.previewFrame;
    if (frames == null || widget.rules.seekPreviewBox == null) return;
    final request = ++_previewRequest;
    unawaited(
      frames(widget.lease.key, preview).then((image) {
        if (!mounted || request != _previewRequest || _seek.preview == null) {
          image?.dispose();
          return;
        }
        setState(() {
          _previewImage?.dispose();
          _previewImage = image;
        });
      }),
    );
  }

  void _togglePlay() {
    widget.onInteraction();
    final lease = widget.lease;
    if (lease.state.value.playing) {
      lease.pause();
    } else {
      lease.play();
    }
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = widget.lease.state.value;
    final tokens = widget.tokens;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return MpxTextRoot.wrap(
      context,
      DefaultTextStyle.merge(
        style: tokens.subtitle,
        child: IgnorePointer(
          ignoring: !widget.visible,
          child: Stack(
            fit: StackFit.expand,
            children: [_controls(state, bottom), _settingsLayer(state)],
          ),
        ),
      ),
    );
  }

  // The play button, faded out by as much as another control takes the
  // centre: the one centre control is either the spinner or
  // play / pause, never both over each other. Before the player's first
  // frame there is no play / pause at all: the page's download radial or
  // the spinner is the centre, never a pause over a picture not playing.
  Widget _centre(Widget button, PlayerState state, double centreY) {
    // A policy without a centre while playing leaves it empty over a
    // playing video: the button stands for play only.
    // A video that failed keeps play in the centre: a tap tries again
    // (`ViewerVideoFailure.silent` says nothing else).
    final failed = state.phase == PlayerPhase.failed;
    final unplayed =
        !failed &&
            (!state.firstFrameRendered ||
                (state.playing && !widget.rules.centreWhilePlaying))
        ? 1.0
        : 0.0;
    Widget faded(double spinner, double overlap) {
      final taken = math.max(math.max(spinner, overlap), unplayed);
      return IgnorePointer(
        ignoring: taken > 0,
        child: Opacity(
          key: const ValueKey('mpx-viewer-play-fade'),
          opacity: (1 - taken).clamp(0.0, 1.0),
          child: button,
        ),
      );
    }

    // The caption over the button takes it, and gives it back when it goes:
    // the button's alpha animates as the caption's top edge
    // crosses its foot.
    Widget overlapped(double spinner) {
      final top = widget.captionTop;
      if (top == null) return faded(spinner, 0);
      return ValueListenableBuilder<double>(
        valueListenable: top,
        builder: (context, captionTop, _) {
          final foot = centreY + ViewerVideoControls.playButtonSize / 2;
          return TweenAnimationBuilder<double>(
            tween: Tween(end: captionTop < foot ? 1 : 0),
            duration: const Duration(milliseconds: 150),
            builder: (context, overlap, _) => faded(spinner, overlap),
          );
        },
      );
    }

    final taken = widget.centreTaken;
    if (taken == null) return overlapped(0);
    return ValueListenableBuilder<double>(
      valueListenable: taken,
      builder: (context, value, _) => overlapped(value),
    );
  }

  Widget _controls(PlayerState state, double bottom) {
    final tokens = widget.tokens;
    return IgnorePointer(
      ignoring: !widget.visible,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: widget.visible ? 1 : 0),
        duration: widget.visible ? widget.showDuration : widget.hideDuration,
        builder: (context, t, child) => Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Stack(
            children: [
              ?child,
              // The bar goes down by the same slide, over the same time, as
              // the viewer's caption above it: one block, not two.
              Positioned(
                left: 0,
                right: 0,
                bottom: bottom,
                child: Transform.translate(
                  offset: Offset(0, widget.slide * (1 - t)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_seek.preview case final preview?)
                        _previewBox(preview),
                      _bar(state),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Center(
            child: _centre(
              _RoundButton(
                key: const ValueKey('mpx-viewer-play'),
                label: state.playing
                    ? widget.strings.pause
                    : widget.strings.play,
                size: ViewerVideoControls.playButtonSize,
                fill: tokens.barFill,
                onTap: _togglePlay,
                child: CustomPaint(
                  size: const Size.square(24),
                  painter: _PlayGlyph(
                    tokens.foreground,
                    paused: !state.playing,
                  ),
                ),
              ),
              state,
              constraints.maxHeight / 2,
            ),
          ),
        ),
      ),
    );
  }

  // The settings: a tap outside closes them, the button (when the controls
  // draw it) opens them.
  Widget _settingsLayer(PlayerState state) {
    final tokens = widget.tokens;
    final open = _settings.value;
    return Stack(
      children: [
        if (open)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                widget.onInteraction();
                _settings.value = false;
              },
            ),
          ),
        Positioned(
          top: widget.settingsTop,
          right: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.settingsButton)
                _RoundButton(
                  key: const ValueKey('mpx-viewer-settings'),
                  label: widget.strings.settings,
                  size: 40,
                  fill: tokens.barFill,
                  onTap: _toggleSettings,
                  child: CustomPaint(
                    size: const Size.square(20),
                    painter: _SettingsGlyph(tokens.foreground),
                  ),
                ),
              if (open) _settingsPanel(state.speed),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bar(PlayerState state) {
    final tokens = widget.tokens;
    final duration = _seek.durationOf(state);
    return ColoredBox(
      key: const ValueKey('mpx-viewer-video-bar'),
      color: tokens.barFill,
      child: SizedBox(
        height: ViewerVideoControls.barHeight,
        child: Row(
          children: [
            const SizedBox(width: 14),
            Expanded(
              child: ViewerSeekBar(
                key: const ValueKey('mpx-viewer-seek-bar'),
                controller: _seek,
                foreground: tokens.foreground,
                height: ViewerVideoControls.barHeight,
              ),
            ),
            const SizedBox(width: 8),
            // The time and the speed keep one width each, whatever they
            // say, so the seek bar's track never changes length under the
            // thumb.
            SizedBox(
              width: _widthOf(
                context,
                '${_digitsOf(duration)} / ${_digitsOf(duration)}',
              ),
              child: ListenableBuilder(
                listenable: _seek,
                builder: (context, _) => Text(
                  '${formatViewerTime(_seek.shown)} / '
                  '${formatViewerTime(duration)}',
                  key: const ValueKey('mpx-viewer-time'),
                  style: _figures,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                ),
              ),
            ),
            _textButton(
              key: const ValueKey('mpx-viewer-speed'),
              label: widget.strings.speed,
              text: '${_speedText(state.speed)}x',
              width: _speedWidth(context),
              onTap: () => _cycleSpeed(state.speed),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  void _toggleSettings() {
    widget.onInteraction();
    _settings.value = !_settings.value;
  }

  Widget _textButton({
    required Key key,
    required String label,
    required String text,
    required VoidCallback onTap,
    double? width,
  }) => Semantics(
    key: key,
    button: true,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: SizedBox(
          width: width,
          child: Center(child: Text(text, style: _figures, maxLines: 1)),
        ),
      ),
    ),
  );

  // The subtitle with digits of one width, so a time keeps its width as it
  // counts.
  TextStyle get _figures => widget.tokens.subtitle.copyWith(
    fontFeatures: const [ui.FontFeature.tabularFigures()],
  );

  // [duration]'s time with every digit a zero: as wide as any time up to it.
  static String _digitsOf(Duration duration) =>
      formatViewerTime(duration).replaceAll(RegExp('[0-9]'), '0');

  // [text]'s width as the controls draw it: in the style the host's text
  // root gives (its letter spacing and family included) with the tokens'
  // over it. Measured with the tokens' alone, a time was a few pixels
  // narrower than its text under a Material text root, wrapped at the slash,
  // and lost its total.
  double _widthOf(BuildContext context, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.merge(_figures),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble() + 1;
    painter.dispose();
    return width;
  }

  // As wide as the widest speed the rule allows.
  double _speedWidth(BuildContext context) {
    final rule = widget.rules.speed;
    var widest = 0.0;
    for (final speed in {1.0, ...rule.cycle, ...rule.presets}) {
      widest = math.max(widest, _widthOf(context, '${_speedText(speed)}x'));
    }
    // A speed between two tenths shows one decimal, as wide as 0.0.
    return math.max(widest, _widthOf(context, '0.0x'));
  }

  static String _speedText(double speed) => speed == speed.roundToDouble()
      ? speed.toStringAsFixed(0)
      : speed.toStringAsFixed(1);

  Widget _previewBox(Duration position) {
    final box = widget.rules.seekPreviewBox;
    final image = _previewImage;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        key: const ValueKey('mpx-viewer-seek-preview'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (box != null && image != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox.fromSize(
                size: _fit(Size(image.width / 1, image.height / 1), box),
                child: RawImage(image: image, fit: BoxFit.contain),
              ),
            ),
          Text(formatViewerTime(position), style: widget.tokens.subtitle),
        ],
      ),
    );
  }

  static Size _fit(Size size, Size box) {
    if (size.isEmpty) return box;
    final scale = math.min(box.width / size.width, box.height / size.height);
    return size * scale;
  }

  // The next of the policy's cycle after [speed]: the first when [speed] is
  // not in it (a speed chosen from the settings) or is its last.
  void _cycleSpeed(double speed) {
    widget.onInteraction();
    final cycle = widget.rules.speed.cycle;
    if (cycle.isEmpty) return;
    final at = cycle.indexOf(speed);
    widget.onSpeed(cycle[(at + 1) % cycle.length]);
  }

  // The settings: every speed the policy offers, and the qualities when
  // there is a choice. A choice closes it.
  Widget _settingsPanel(double speed) {
    final rule = widget.rules.speed;
    final tokens = widget.tokens;
    Widget row(
      Key key,
      String text, {
      required bool selected,
      required void Function() onTap,
    }) => ViewerTapTarget(
      key: key,
      onTap: () {
        _settings.value = false;
        widget.onInteraction();
        onTap();
      },
      selected: selected,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            text,
            maxLines: 1,
            style: tokens.subtitle.copyWith(
              color: selected ? tokens.link : tokens.menuForeground,
              fontWeight: selected ? FontWeight.w600 : null,
            ),
          ),
        ),
      ),
    );
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Text(
        text,
        maxLines: 1,
        style: tokens.subtitle.copyWith(
          color: tokens.menuForeground.withValues(alpha: 0.6),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: DecoratedBox(
        key: const ValueKey('mpx-viewer-settings-panel'),
        decoration: BoxDecoration(
          color: tokens.menuBackground,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SizedBox(
          width: 200,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading(widget.strings.speedHeading),
                for (final preset in rule.presets)
                  row(
                    ValueKey(('mpx-viewer-speed-preset', preset)),
                    preset == 1 ? '1x' : '${_speedText(preset)}x',
                    selected: preset == speed,
                    onTap: () => widget.onSpeed(preset),
                  ),
                if (widget.qualities.length > 1) ...[
                  heading(widget.strings.quality),
                  for (final quality in widget.qualities)
                    row(
                      ValueKey(('mpx-viewer-quality-item', quality.label)),
                      quality.label,
                      selected: quality == widget.quality,
                      onTap: () => widget.onQuality?.call(quality),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [position] as m:ss, or h:mm:ss from an hour on.
String formatViewerTime(Duration position) {
  final total = position.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total ~/ 60) % 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.label,
    required this.size,
    required this.fill,
    required this.onTap,
    required this.child,
    super.key,
  });

  final String label;
  final double size;
  final Color fill;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: child,
      ),
    ),
  );
}

class _PlayGlyph extends CustomPainter {
  const _PlayGlyph(this.color, {required this.paused});

  final Color color;
  final bool paused;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final w = size.width;
    final h = size.height;
    if (paused) {
      canvas.drawPath(
        Path()
          ..moveTo(w * 0.25, h * 0.15)
          ..lineTo(w * 0.85, h / 2)
          ..lineTo(w * 0.25, h * 0.85)
          ..close(),
        paint,
      );
    } else {
      canvas
        ..drawRect(Rect.fromLTWH(w * 0.22, h * 0.15, w * 0.2, h * 0.7), paint)
        ..drawRect(Rect.fromLTWH(w * 0.58, h * 0.15, w * 0.2, h * 0.7), paint);
    }
  }

  @override
  bool shouldRepaint(_PlayGlyph oldDelegate) =>
      oldDelegate.color != color || oldDelegate.paused != paused;
}

/// The settings glyph: two sliders, each a line with a knob.
class _SettingsGlyph extends CustomPainter {
  const _SettingsGlyph(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final knob = Paint()..color = color;
    final w = size.width;
    final h = size.height;
    canvas
      ..drawLine(Offset(1, h * 0.3), Offset(w - 1, h * 0.3), line)
      ..drawLine(Offset(1, h * 0.7), Offset(w - 1, h * 0.7), line)
      ..drawCircle(Offset(w * 0.68, h * 0.3), 3.2, knob)
      ..drawCircle(Offset(w * 0.32, h * 0.7), 3.2, knob);
  }

  @override
  bool shouldRepaint(_SettingsGlyph oldDelegate) => oldDelegate.color != color;
}
