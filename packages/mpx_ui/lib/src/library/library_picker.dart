import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/library/library_album_switcher.dart';
import 'package:mpx_ui/src/library/library_grid.dart';
import 'package:mpx_ui/src/library/library_grid_policy.dart';
import 'package:mpx_ui/src/library/library_grid_tokens.dart';
import 'package:mpx_ui/src/library/library_pages.dart';
import 'package:mpx_ui/src/library/picker_selection.dart';
import 'package:mpx_ui/src/library/picker_viewer.dart';
import 'package:mpx_ui/src/text/mpx_text_root.dart';
import 'package:mpx_ui/src/viewer/viewer_origin.dart';

/// The library picker: the album switcher, the library grid and the
/// picker-mode viewer over a [MediaLibrary], in every library access
/// state.
///
/// | Access | Shows |
/// | --- | --- |
/// | not determined | a spinner; access is asked on the first show |
/// | denied | `$Android`: an empty view with camera and access buttons; `$IOS`: a placeholder with Open Settings and a camera tile |
/// | restricted | the host's text |
/// | limited (iOS) | the grid under a Manage banner (Select more, Change settings) |
/// | partial (Android 14) | the chosen items under a banner that asks again |
/// | full | the grid |
///
/// Without [mediaAllowed] the grid is hidden behind the host's
/// [notAllowedText]. With [cameraDenied] `$IOS` shows a banner instead of
/// the camera slot; `$Android` keeps the slot and tells its builder.
/// Access and albums are read again when the app resumes. Strings,
/// colours and the switcher's place ([headerBuilder]) come from the host.
class LibraryPicker extends StatefulWidget {
  /// Creates the picker.
  const LibraryPicker({
    required this.library,
    required this.selection,
    required this.labels,
    required this.stateLabels,
    this.policy = LibraryGridPolicy.$Android,
    this.tokens = const LibraryGridTokens(),
    this.mediaAllowed = true,
    this.notAllowedText,
    this.cameraDenied = false,
    this.cameraSlotBuilder,
    this.onCameraTap,
    this.onCameraLongPress,
    this.onCamera,
    this.onRefused,
    this.onReorder,
    this.viewerTitle,
    this.viewerSubtitleOf,
    this.onOpen,
    this.viewerBottomBuilder,
    this.players,
    this.headerBuilder,
    this.decorationBuilder,
    this.physics,
    this.controller,
    this.lookup,
    this.gridBuilder,
    this.active = true,
    super.key,
  });

  /// The library read.
  final MediaLibrary library;

  /// The selection the checks change.
  final PickerSelection selection;

  /// The grid's words.
  final LibraryGridLabels labels;

  /// The states', banners' and switcher's words.
  final LibraryPickerLabels stateLabels;

  /// The platform values.
  final LibraryGridPolicy policy;

  /// Colours and text styles.
  final LibraryGridTokens tokens;

  /// Whether the host lets media be picked here at all.
  final bool mediaAllowed;

  /// What shows instead of the grid without [mediaAllowed].
  final String? notAllowedText;

  /// Whether camera access is denied.
  final bool cameraDenied;

  /// Fills the camera slot.
  final CameraSlotBuilder? cameraSlotBuilder;

  /// Called by a tap on the camera slot.
  final VoidCallback? onCameraTap;

  /// Called by a long press on the camera slot.
  final VoidCallback? onCameraLongPress;

  /// Called by the denied states' camera button or tile.
  final VoidCallback? onCamera;

  /// Called when the selection refused a key.
  final void Function(MediaKey key, PickerRefusal reason)? onRefused;

  /// A selected item the picker-mode viewer's strip lifted was dragged to
  /// the place [to] (0-based) of the selection: `OrderedPickerSelection.move`
  /// for the default selection; no reorder when null.
  final void Function(MediaKey key, int to)? onReorder;

  /// The picker-mode viewer's title: where the media goes (a chat's name);
  /// none when null.
  final String? viewerTitle;

  /// The picker-mode viewer's info line for an item; by default a video's
  /// size, duration and approximate bytes (`PickerViewer.videoInfo`), and
  /// nothing for a photo.
  final String? Function(LibraryAsset asset)? viewerSubtitleOf;

  /// Called by a tap on a picture instead of the picker-mode viewer.
  final void Function(LibraryAsset asset, int index)? onOpen;

  /// Fills the picker-mode viewer's bottom slot.
  final Widget Function(BuildContext context, PickerViewerItem item)?
  viewerBottomBuilder;

  /// The players the viewer's videos play on.
  final PlayerPool? players;

  /// Places the album switcher (a header, a title); the switcher alone at
  /// the top when null.
  final Widget Function(BuildContext context, Widget switcher)? headerBuilder;

  /// Builds a host mark over a cell's picture.
  final Widget? Function(BuildContext context, LibraryAsset asset)?
  decorationBuilder;

  /// The grid's scroll physics.
  final ScrollPhysics? physics;

  /// The grid's scroll controller, or null for the grid's own (or the
  /// ambient primary one).
  final ScrollController? controller;

  /// Answers what the grid holds at a scroll offset ([LibraryGrid.lookup]).
  final LibraryGridLookup? lookup;

  /// Wraps the grid in the host's widgets over its area only (a scroll
  /// thumb, say), below the header and banners; null shows the grid as is.
  final Widget Function(BuildContext context, Widget grid)? gridBuilder;

  /// Whether the host's page holding the picker is active and uncovered.
  final bool active;

  @override
  State<LibraryPicker> createState() => LibraryPickerState();
}

/// The state of a [LibraryPicker]; public for tests.
class LibraryPickerState extends State<LibraryPicker> {
  List<LibraryAlbum>? _albums;
  LibraryAlbum? _album;
  LibraryPages? _pages;
  LibraryGallerySource? _gallery;
  AppLifecycleListener? _lifecycle;
  bool _asked = false;
  bool _viewerOpen = false;
  final GlobalKey<ViewerOriginScopeState> _origins = GlobalKey();

  /// The album shown, or null before the albums load.
  LibraryAlbum? get album => _album;

  @override
  void initState() {
    super.initState();
    widget.library.access.addListener(_onAccess);
    _lifecycle = AppLifecycleListener(onResume: reload);
    _onAccess();
  }

  @override
  void didUpdateWidget(LibraryPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.library, widget.library)) {
      oldWidget.library.access.removeListener(_onAccess);
      widget.library.access.addListener(_onAccess);
      _bind(null);
      _albums = null;
      _onAccess();
    }
  }

  @override
  void dispose() {
    widget.library.access.removeListener(_onAccess);
    _lifecycle?.dispose();
    _gallery?.dispose();
    _pages?.dispose();
    super.dispose();
  }

  void _onAccess() {
    final access = widget.library.access.value;
    if (access == LibraryAccess.notDetermined && !_asked) {
      _asked = true;
      unawaited(widget.library.requestAccess());
    }
    if (access.canRead) {
      unawaited(reload());
    } else if (mounted) {
      setState(() {});
    }
  }

  /// Reads the albums again and rebinds the grid's pages (the app resumed,
  /// or access changed).
  Future<void> reload() async {
    final albums = await widget.library.albums();
    if (!mounted) return;
    final keep = _album == null
        ? null
        : albums.where((a) => a.id == _album!.id).firstOrNull;
    setState(() {
      _albums = albums;
      if (keep != null && _pages != null) {
        // The album shown is still there: its pages read again in place,
        // so a resume that changed nothing changes nothing on screen.
        _album = keep;
        _pages!.reload();
      } else {
        _bind(albums.firstOrNull);
      }
    });
  }

  void _bind(LibraryAlbum? album) {
    _gallery?.dispose();
    _pages?.dispose();
    _album = album;
    _pages = album == null
        ? null
        : LibraryPages(library: widget.library, album: album);
    _gallery = _pages == null ? null : LibraryGallerySource(_pages!);
  }

  void _choose(LibraryAlbum album) => setState(() => _bind(album));

  Future<void> _open(LibraryAsset asset, int index) async {
    if (widget.onOpen case final open?) return open(asset, index);
    final gallery = _gallery;
    if (gallery == null) return;
    setState(() => _viewerOpen = true);
    await PickerViewer.show(
      context,
      source: gallery,
      initialIndex: index,
      selection: widget.selection,
      labels: widget.labels,
      gridPolicy: widget.policy,
      tokens: widget.tokens,
      players: widget.players,
      bottomBuilder: widget.viewerBottomBuilder,
      onRefused: widget.onRefused,
      onReorder: widget.onReorder,
      title: widget.viewerTitle,
      subtitleOf: widget.viewerSubtitleOf,
      bridge: _origins.currentState?.bridgeFor(gallery),
    );
    if (mounted) setState(() => _viewerOpen = false);
  }

  // The text root: the grid and its states draw text of their own, and a
  // host that pushed them without one would draw it in the fallback style.
  @override
  Widget build(BuildContext context) =>
      MpxTextRoot.wrap(context, _content(context));

  Widget _content(BuildContext context) {
    final tokens = widget.tokens;
    final labels = widget.stateLabels;
    final ios = identical(widget.policy, LibraryGridPolicy.$IOS);
    if (!widget.mediaAllowed) {
      return _Message(text: widget.notAllowedText ?? '', tokens: tokens);
    }
    final access = widget.library.access.value;
    switch (access) {
      case LibraryAccess.notDetermined:
        return _Loading(tokens: tokens);
      case LibraryAccess.restricted:
        return _Message(text: labels.restricted, tokens: tokens);
      case LibraryAccess.denied:
        return _Denied(
          ios: ios,
          labels: labels,
          tokens: tokens,
          onCamera: widget.onCamera,
          onAccess: ios
              ? widget.library.openSettings
              : () async {
                  await widget.library.requestAccess();
                  if (widget.library.access.value == LibraryAccess.denied) {
                    await widget.library.openSettings();
                  }
                },
        );
      case LibraryAccess.limited || LibraryAccess.partial || LibraryAccess.full:
        break;
    }
    final albums = _albums;
    final album = _album;
    final pages = _pages;
    final banners = <Widget>[
      if (access == LibraryAccess.limited)
        _Banner(
          key: const ValueKey('mpx-limited-banner'),
          text: labels.limitedText,
          action: labels.manage,
          tokens: tokens,
          onTap: () => unawaited(_manage(context)),
        ),
      if (access == LibraryAccess.partial)
        _Banner(
          key: const ValueKey('mpx-partial-banner'),
          text: labels.partialText,
          action: labels.manage,
          tokens: tokens,
          onTap: () => unawaited(widget.library.manageSelected()),
        ),
      if (ios && widget.cameraDenied)
        _Banner(
          key: const ValueKey('mpx-camera-denied-banner'),
          text: labels.cameraDeniedText,
          action: labels.openSettings,
          tokens: tokens,
          onTap: () => unawaited(widget.library.openSettings()),
        ),
    ];
    if (albums == null || album == null || pages == null) {
      return Column(
        children: [
          ...banners,
          Expanded(child: _Loading(tokens: tokens)),
        ],
      );
    }
    final switcher = LibraryAlbumSwitcher(
      albums: albums,
      selected: album,
      onSelected: _choose,
      labels: labels,
      policy: widget.policy,
      tokens: tokens,
    );
    final header =
        widget.headerBuilder?.call(context, switcher) ??
        Align(alignment: AlignmentDirectional.centerStart, child: switcher);
    final grid = LibraryGrid(
      key: ValueKey('mpx-grid-${album.id.value}'),
      library: widget.library,
      album: album,
      pages: pages,
      selection: widget.selection,
      labels: widget.labels,
      policy: widget.policy,
      tokens: tokens,
      onOpen: (asset, index) => unawaited(_open(asset, index)),
      onRefused: widget.onRefused,
      cameraSlotBuilder: widget.cameraSlotBuilder,
      cameraDenied: widget.cameraDenied,
      onCameraTap: widget.onCameraTap,
      onCameraLongPress: widget.onCameraLongPress,
      decorationBuilder: widget.decorationBuilder,
      physics: widget.physics,
      controller: widget.controller,
      lookup: widget.lookup,
      viewerOpen: _viewerOpen,
      active: widget.active,
    );
    return ColoredBox(
      color: tokens.background,
      child: Column(
        children: [
          header,
          ...banners,
          Expanded(
            child: album.count == 0 && pages.total == 0
                ? _Message(text: labels.empty, tokens: tokens)
                : ViewerOriginScope(
                    key: _origins,
                    source: _gallery,
                    child: widget.gridBuilder?.call(context, grid) ?? grid,
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _manage(BuildContext context) async {
    final labels = widget.stateLabels;
    final text = MpxTextRoot.styleOf(context);
    final choice = await Navigator.of(context).push<int>(
      PageRouteBuilder<int>(
        opaque: false,
        barrierDismissible: true,
        barrierColor: const Color(0x55000000),
        pageBuilder: (context, _, _) => MpxTextRoot.over(
          text,
          _ManageMenu(labels: labels, tokens: widget.tokens),
        ),
      ),
    );
    switch (choice) {
      case 0:
        await widget.library.manageSelected();
      case 1:
        await widget.library.openSettings();
    }
  }
}

class _Loading extends StatefulWidget {
  const _Loading({required this.tokens});

  final LibraryGridTokens tokens;

  @override
  State<_Loading> createState() => _LoadingState();
}

class _LoadingState extends State<_Loading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: widget.tokens.background,
    child: Center(
      child: RotationTransition(
        key: const ValueKey('mpx-picker-loading'),
        turns: _spin,
        child: CustomPaint(
          size: const Size.square(28),
          painter: _Arc(widget.tokens.accent),
        ),
      ),
    ),
  );
}

class _Arc extends CustomPainter {
  const _Arc(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawArc(
    Offset.zero & size,
    0,
    math.pi * 1.4,
    false,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round,
  );

  @override
  bool shouldRepaint(_Arc old) => old.color != color;
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.tokens});

  final String text;
  final LibraryGridTokens tokens;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: tokens.background,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          style: tokens.secondaryText,
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}

class _Button extends StatelessWidget {
  const _Button({
    required this.label,
    required this.tokens,
    this.onTap,
    super.key,
  });

  final String label;
  final LibraryGridTokens tokens;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    onTap: onTap,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: tokens.accent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: tokens.text),
      ),
    ),
  );
}

class _Denied extends StatelessWidget {
  const _Denied({
    required this.ios,
    required this.labels,
    required this.tokens,
    required this.onAccess,
    this.onCamera,
  });

  final bool ios;
  final LibraryPickerLabels labels;
  final LibraryGridTokens tokens;
  final Future<void> Function() onAccess;
  final VoidCallback? onCamera;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          labels.deniedTitle,
          style: tokens.title,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          labels.deniedText,
          style: tokens.secondaryText,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
      ],
    );
    if (ios) {
      // A placeholder with Open Settings, beside a camera tile.
      return ColoredBox(
        color: tokens.background,
        child: Column(
          children: [
            if (onCamera != null)
              Align(
                alignment: AlignmentDirectional.topStart,
                child: GestureDetector(
                  key: const ValueKey('mpx-denied-camera-tile'),
                  onTap: onCamera,
                  child: Container(
                    width: 120,
                    height: 120,
                    margin: const EdgeInsets.all(1),
                    color: tokens.cameraSlotBackground,
                    alignment: Alignment.center,
                    child: Text(labels.camera, style: tokens.text),
                  ),
                ),
              ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      text,
                      _Button(
                        key: const ValueKey('mpx-denied-settings'),
                        label: labels.openSettings,
                        tokens: tokens,
                        onTap: () => unawaited(onAccess()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return ColoredBox(
      color: tokens.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              text,
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (onCamera != null)
                    _Button(
                      key: const ValueKey('mpx-denied-camera'),
                      label: labels.camera,
                      tokens: tokens,
                      onTap: onCamera,
                    ),
                  _Button(
                    key: const ValueKey('mpx-denied-access'),
                    label: labels.allowAccess,
                    tokens: tokens,
                    onTap: () => unawaited(onAccess()),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.text,
    required this.action,
    required this.tokens,
    required this.onTap,
    super.key,
  });

  final String text;
  final String action;
  final LibraryGridTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$text, $action',
    onTap: onTap,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ColoredBox(
        color: tokens.bannerFill,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(child: Text(text, style: tokens.secondaryText)),
              const SizedBox(width: 12),
              Text(
                action.toUpperCase(),
                style: tokens.text.copyWith(color: tokens.accent),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ManageMenu extends StatelessWidget {
  const _ManageMenu({required this.labels, required this.tokens});

  final LibraryPickerLabels labels;
  final LibraryGridTokens tokens;

  @override
  Widget build(BuildContext context) {
    Widget item(int value, String label) => GestureDetector(
      key: ValueKey('mpx-manage-$value'),
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Text(label, style: tokens.text),
      ),
    );
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Container(
          margin: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: tokens.menuFill,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              item(0, labels.selectMore),
              item(1, labels.changeSettings),
            ],
          ),
        ),
      ),
    );
  }
}
