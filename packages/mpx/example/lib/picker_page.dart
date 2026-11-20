import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_capture/mpx_capture.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_ui/mpx_ui.dart';

/// The media picker of the set: the device library in a `LibraryPicker`, a
/// live camera in its camera slot (`mpx_capture`'s `CameraSlotPreview`,
/// expanding into the capture surface on a tap), the system camera on a
/// long press or when the session is unavailable, and captured items first
/// in the selection.
class PickerPage extends StatefulWidget {
  /// Creates the page; captures land in [store] under local keys.
  const PickerPage({required this.store, required this.clock, super.key});

  /// The bytes store captures move into.
  final IBytesStore store;

  /// The stack's playback clock.
  final PlaybackClock clock;

  @override
  State<PickerPage> createState() => _PickerPageState();
}

class _PickerPageState extends State<PickerPage> {
  final PlatformMediaLibrary _library = PlatformMediaLibrary();
  final OrderedPickerSelection _selection = OrderedPickerSelection(cap: 10);
  late final CaptureCache _cache = CaptureCache(store: widget.store);
  late final AssetPipeline _pipeline = AssetPipeline(
    fetcher: LibraryFetcher(_library),
    decoders: DecoderRegistry()
      ..register(MediaKind.still, const ImageCodecDecoder())
      ..register(MediaKind.animatedImage, const ImageCodecDecoder()),
  );
  late final AssetCacheScope _scope = AssetCacheScope(
    producer: _pipeline,
    clock: widget.clock,
  );
  CameraSession? _camera;
  FileIntake? _intake;
  final GlobalKey _slot = GlobalKey();

  static const _gridLabels = LibraryGridLabels(
    photo: 'Photo',
    video: 'Video',
    open: 'Open',
    select: 'Select',
    gif: 'GIF',
    camera: 'Camera',
  );

  static const _stateLabels = LibraryPickerLabels(
    allMedia: 'Recents',
    allPhotos: 'All photos',
    allVideos: 'All videos',
    cameraAlbum: 'Camera',
    favourites: 'Favourites',
    empty: 'No photos or videos yet',
    deniedTitle: 'Access to media',
    deniedText: 'Allow access to your photos and videos to pick them.',
    allowAccess: 'Allow access',
    openSettings: 'Open Settings',
    camera: 'Camera',
    restricted: 'Access to photos is restricted on this device.',
    limitedText: 'You allowed access to some photos.',
    manage: 'Manage',
    selectMore: 'Select more photos',
    changeSettings: 'Change settings',
    partialText: 'You allowed access to some photos and videos.',
    cameraDeniedText: 'Allow camera access to take photos here.',
  );

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final camera = await const PlatformCameraSessions().open(frameRateCap: 30);
    final intake = await PlatformIntake.fileIntake();
    if (!mounted) return unawaited(camera.dispose());
    setState(() {
      _camera = camera;
      _intake = intake;
    });
  }

  @override
  void dispose() {
    unawaited(_camera?.dispose());
    _scope.dispose();
    _pipeline.dispose();
    unawaited(_library.dispose());
    _selection.dispose();
    super.dispose();
  }

  Future<void> _openCamera() async {
    final camera = _camera;
    if (camera == null || !camera.value.value.isAvailable) {
      return _systemCamera();
    }
    final box = _slot.currentContext?.findRenderObject() as RenderBox?;
    await CameraCaptureSurface.show(
      context,
      session: camera,
      labels: const CaptureSurfaceLabels(
        close: 'Close',
        shutter: 'Take a photo, hold for a video',
        switchCamera: 'Switch camera',
        flash: 'Flash',
      ),
      outputDirectory: Directory.systemTemp.path,
      cache: _cache,
      from: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      onCaptured: (shot) {
        if (shot.key case final key?) _selection.toggle(key);
      },
    );
  }

  Future<void> _systemCamera() async {
    final intake = _intake;
    if (intake == null || !intake.canCaptureWithSystemCamera) return;
    final file = await intake.captureWithSystemCamera(IntakeCaptureKind.photo);
    if (file == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Took ${file.name}')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: ListenableBuilder(
        listenable: _selection,
        builder: (context, _) =>
            Text('Media picker (${_selection.keys.length})'),
      ),
    ),
    body: AssetCacheProvider(
      scope: _scope,
      child: LibraryPicker(
        library: _library,
        selection: _selection,
        labels: _gridLabels,
        stateLabels: _stateLabels,
        policy: LibraryGridPolicy.forPlatform(Theme.of(context).platform),
        cameraDenied: _camera?.value.value.state == CameraSessionState.denied,
        onCameraTap: () => unawaited(_openCamera()),
        onCameraLongPress: () => unawaited(_systemCamera()),
        onCamera: () => unawaited(_openCamera()),
        onRefused: (key, reason) => ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Not picked: ${reason.name}'))),
        cameraSlotBuilder: (context, signals) {
          final camera = _camera;
          if (camera == null) return const SizedBox.expand();
          return ValueListenableBuilder<CameraSlotSignals>(
            key: _slot,
            valueListenable: signals,
            builder: (context, value, _) => CameraSlotPreview(
              session: camera,
              paused: value.shouldPause,
              onUnavailable: (_) => setState(() {}),
              deniedBuilder: (_) => const Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Allow access to camera',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),
          );
        },
        viewerBottomBuilder: (context, item) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text('Pick ${item.keys.length}'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
