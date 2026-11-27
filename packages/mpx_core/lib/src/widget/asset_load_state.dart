import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/src/asset/asset_binding.dart';
import 'package:mpx_core/src/asset/asset_cache_scope.dart';
import 'package:mpx_core/src/asset/asset_preset.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/pipeline/auto_download.dart';
import 'package:mpx_core/src/widget/asset_cache_provider.dart';
import 'package:mpx_core/src/widget/media_status.dart';

/// What a download's arc shows while its measure is not known yet (no byte
/// has arrived, or no total).
enum MediaProgressLook {
  /// The measured arc, from nothing: the GIF cell, whose arc
  /// stands at its least sweep and turns until the bytes come.
  measured,

  /// The indeterminate spinner: a video's loading.
  spinner;

  /// The stock choice for [media]: a GIF (an animated image, or a GIF sent
  /// as a silent video loop) keeps its measured arc; anything else spins.
  static MediaProgressLook stockFor(MediaDescriptor? media) =>
      media != null &&
          (media.kind == MediaKind.animatedImage || media.silentLoop)
      ? measured
      : spinner;
}

/// Where one piece of media is in its loading, as a value: the best stage it
/// shows and its download. What the stock chrome of an [AssetView] reads, for
/// a host that draws its own: a skin's builders get it, and an
/// [AssetLoadStateBuilder] hands it to any widget.
///
/// A failure is a [transfer] state ([AssetTransfer$Failed]), never a stage:
/// the media keeps the best stage it reached.
@immutable
final class AssetLoadState {
  /// Describes media at [stage] with [transfer].
  const AssetLoadState({
    required this.stage,
    this.transfer = AssetTransfer.none,
    this.standsStill = false,
  });

  /// The state of [binding] now.
  factory AssetLoadState.of(AssetBinding binding) => AssetLoadState(
    stage: binding.readiness.stage,
    transfer: binding.transfer,
    standsStill:
        binding.profile.animate &&
        binding.readiness.isFinal &&
        binding.readiness.stage.index >= AssetStage.firstFrame.index &&
        !binding.paintable.isAnimated,
  );

  /// The best stage the media shows.
  final AssetStage stage;

  /// Its download.
  final AssetTransfer transfer;

  /// Whether the binding asked for motion and settled on a picture that does
  /// not move: a video its decoder could not play, shown by its first frame.
  /// It reads as a picture, so a surface offers play over it.
  final bool standsStill;

  /// Whether bytes are on their way while the media shows no frame yet: what
  /// a progress indicator stands for.
  bool get loading =>
      transfer.isActive && stage.index < AssetStage.firstFrame.index;

  /// How much has arrived, 0 to 1, or null when the total is not known.
  double? get fraction => transfer.fraction;

  /// Whether the last download failed (the stock control offers download,
  /// which is the retry).
  bool get failed => transfer is AssetTransfer$Failed;

  /// Whether the media shows its content (its first frame or more).
  bool get shown => stage.index >= AssetStage.firstFrame.index;

  /// What the stock status control shows for it; with [look]
  /// [MediaProgressLook.measured], a download not measured yet shows its arc
  /// at nothing rather than the spinner.
  MediaStatus status({
    bool playAction = false,
    MediaProgressLook look = MediaProgressLook.spinner,
  }) {
    final status = MediaStatus.forTransfer(
      transfer,
      stage,
      playAction: playAction,
    );
    return look == MediaProgressLook.measured &&
            transfer.isActive &&
            status.arc &&
            status.progress == null
        ? MediaStatus(
            icon: status.icon,
            arc: true,
            progress: 0,
            upload: status.upload,
          )
        : status;
  }

  @override
  bool operator ==(Object other) =>
      other is AssetLoadState &&
      other.stage == stage &&
      other.transfer == transfer &&
      other.standsStill == standsStill;

  @override
  int get hashCode => Object.hash(stage, transfer, standsStill);

  @override
  String toString() => 'AssetLoadState(${stage.name}, $transfer)';
}

/// Builds a part of a view from media's [state] and the [stock] widget the
/// view would show there (a skin wraps, replaces or keeps it).
typedef AssetSkinBuilder =
    Widget Function(BuildContext context, AssetLoadState state, Widget stock);

/// The look of an [AssetView] around its loading state, each part
/// replaceable: the status control, the badge, and the reveal of the
/// picture. A null builder keeps the stock part, so [AssetViewSkin.stock]
/// is the standard look of the platform's `MediaLoadingStyle`.
///
/// A [reveal] gets the picture itself as its stock: a host that brings its
/// own entrance sets the style's stage fades to zero and animates the
/// picture as [AssetLoadState.shown] turns true. It must keep the picture in
/// the same place of its tree, or the picture reattaches each time.
@immutable
final class AssetViewSkin {
  /// Creates a skin; null builders keep the stock parts.
  const AssetViewSkin({
    this.status,
    this.badge,
    this.reveal,
    this.progress,
    this.failure,
  });

  /// The standard look: every part stock.
  static const AssetViewSkin stock = AssetViewSkin();

  /// Builds the status control (download, progress, play, the retry).
  final AssetSkinBuilder? status;

  /// Builds the media badge (a duration, "GIF", the bytes while they
  /// arrive).
  final AssetSkinBuilder? badge;

  /// Builds the picture's entrance over the stock fades.
  final AssetSkinBuilder? reveal;

  /// Builds what a view shows over its picture while its media failed
  /// ([AssetLoadState.failed]); its stock part is nothing: the picture
  /// stays (no visible failed stage), and the status control
  /// offers download, which is the retry. A host that wants a mark of its
  /// own (an icon, a word) builds it here.
  final AssetSkinBuilder? failure;

  /// Per kind of media, what its download arc shows before its measure is
  /// known; null for [MediaProgressLook.stockFor] (a GIF's measured arc, a
  /// video's spinner).
  final MediaProgressLook Function(MediaDescriptor? media)? progress;

  /// The progress look of [media] under this skin.
  MediaProgressLook progressOf(MediaDescriptor? media) =>
      (progress ?? MediaProgressLook.stockFor)(media);

  /// This skin, with [other]'s builders where it has none.
  AssetViewSkin over(AssetViewSkin? other) => other == null
      ? this
      : AssetViewSkin(
          status: status ?? other.status,
          badge: badge ?? other.badge,
          reveal: reveal ?? other.reveal,
          progress: progress ?? other.progress,
          failure: failure ?? other.failure,
        );

  /// Whether every part is stock.
  bool get isStock =>
      status == null &&
      badge == null &&
      reveal == null &&
      progress == null &&
      failure == null;
}

/// Rebuilds with the [AssetLoadState] of [content] decoded as [preset]: a
/// host's own loading UI around media, over the same cache entry every view
/// of it shares (it attaches a binding of its own, which holds the entry,
/// not a second download).
class AssetLoadStateBuilder extends StatefulWidget {
  /// Builds from the state of [content] at [preset].
  const AssetLoadStateBuilder({
    required MediaKey this.content,
    required AssetPreset this.preset,
    required this.builder,
    this.scope,
    this.downloadContext,
    this.child,
    super.key,
  }) : binding = null;

  /// Builds from the state of a [binding] the caller holds (a view's own).
  const AssetLoadStateBuilder.binding(
    AssetBinding this.binding, {
    required this.builder,
    this.child,
    super.key,
  }) : content = null,
       preset = null,
       scope = null,
       downloadContext = null;

  /// The media; null with [binding].
  final MediaKey? content;

  /// Its size and decode, as the view showing it is given; null with
  /// [binding].
  final AssetPreset? preset;

  /// A binding the caller holds and keeps; null to attach one.
  final AssetBinding? binding;

  /// The cache, instead of the one an [AssetCacheProvider] provides.
  final AssetCacheScope? scope;

  /// The surface's tag for the auto-download policy.
  final AutoDownloadContext? downloadContext;

  /// Builds from the state; [child] is passed through.
  final Widget Function(
    BuildContext context,
    AssetLoadState state,
    Widget? child,
  )
  builder;

  /// A part that does not depend on the state.
  final Widget? child;

  @override
  State<AssetLoadStateBuilder> createState() => _AssetLoadStateBuilderState();
}

class _AssetLoadStateBuilderState extends State<AssetLoadStateBuilder> {
  AssetBinding? _binding;
  AssetCacheScope? _scope;
  AssetLoadState _state = const AssetLoadState(stage: AssetStage.none);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attach();
  }

  @override
  void didUpdateWidget(AssetLoadStateBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.binding, oldWidget.binding) ||
        widget.content != oldWidget.content ||
        widget.preset?.spec != oldWidget.preset?.spec ||
        widget.downloadContext != oldWidget.downloadContext ||
        !identical(widget.scope, oldWidget.scope)) {
      _detach();
    }
    _attach();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _attach() {
    if (widget.binding case final held?) {
      if (identical(held, _binding)) return;
      _detach();
      _binding = held..addListener(_changed);
      _state = AssetLoadState.of(held);
      return;
    }
    final scope = widget.scope ?? AssetCacheProvider.maybeOf(context);
    if (identical(scope, _scope) && _binding != null) return;
    _detach();
    _scope = scope;
    if (scope == null) return;
    final preset = widget.preset!;
    final binding = scope.attach(
      widget.content!,
      preset.spec,
      preset.profile,
      downloadContext: widget.downloadContext,
    )..addListener(_changed);
    _binding = binding;
    _state = AssetLoadState.of(binding);
  }

  void _detach() {
    final binding = _binding;
    _binding = null;
    _scope = null;
    if (binding == null) return;
    binding.removeListener(_changed);
    // Only a binding this builder attached is its to let go.
    if (!identical(binding, widget.binding)) binding.detach();
  }

  // A binding may change while a frame builds (a tile of the same content
  // mounting): the state is taken after it.
  void _changed() {
    final binding = _binding;
    if (!mounted || binding == null) return;
    final next = AssetLoadState.of(binding);
    if (next == _state) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _changed());
      return;
    }
    setState(() => _state = next);
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _state, widget.child);
}
