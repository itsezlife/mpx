import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/viewer/viewer_loading.dart';
import 'package:mpx_ui/src/viewer/viewer_policy_scope.dart';

/// The media of the closest `FeedSlot`'s item, drawn the way the slot's
/// `FeedController` decided.
///
/// While the item holds a player (a pager's page and its warm neighbours) it
/// shows a `PlayerView` over [poster], which the player fades in over once
/// it has its first frame, for the viewer policy's
/// `ViewerLoadingRules.playerFadeIn` (`ViewerPolicyScope.resolve`); with
/// [showsBuffering] the policy's buffering spinner shows over a player that
/// waits for its media past the delay. Otherwise, when the controller gives the item a clip profile (list
/// mode: looping, advancing only above the advance floor, held on its frame
/// while it does not play), it attaches the item through the asset cache
/// with it and its visible fraction; else it shows its [poster]. A released
/// item (far from view) shows only the [poster], holding no decoder.
///
/// The default poster is the item's staged view: clear, then its preview,
/// then its thumbnail, then its first frame, attached with the item's
/// `FeedItem.downloadContext`.
///
/// The preset comes from [preset], else the controller's `presetOf`; the
/// cache from [scope], else the controller's, else the closest
/// `AssetCacheProvider`. Without a preset or a cache it shows the poster.
///
/// [status] and [badge] lay the item's status control and media badge over
/// it as a `ContentView` does (download, the arc and cancel, nothing once
/// downloaded; duration, "GIF", the bytes), whatever draws the picture: the
/// staged view, the clip, or a player over them. They follow the content's
/// one transfer, so a download a viewer or a player runs shows on the tile.
class FeedClip extends StatelessWidget {
  /// Shows the closest slot's item.
  const FeedClip({
    this.preset,
    this.poster,
    this.fit = BoxFit.contain,
    this.scope,
    this.showsBuffering = false,
    this.status = MediaStatusMode.none,
    this.badge = false,
    super.key,
  });

  /// The status control over the item (`ContentView.status`).
  final MediaStatusMode status;

  /// Whether the media badge shows over the item (`ContentView.badge`).
  final bool badge;

  /// The size and decode of the item's media under a profile.
  final AssetPreset Function(AssetProfile profile)? preset;

  /// What shows while there is no picture: the item's still from the cache
  /// when null (with a preset), else nothing.
  final Widget? poster;

  /// How the player's picture fills the clip.
  final BoxFit fit;

  /// The cache the item's media attaches to.
  final AssetCacheScope? scope;

  /// Whether the buffering spinner shows over the player (a pager's page);
  /// a list shows none.
  final bool showsBuffering;

  @override
  Widget build(BuildContext context) {
    final slot = FeedSlot.of(context);
    final controller = slot.controller;
    final index = slot.index;
    final item = slot.item ?? controller.itemAt(index);
    return ValueListenableBuilder<FeedItemState>(
      valueListenable: slot.state,
      builder: (context, state, _) {
        final presetOf = _presetOf(controller, index);
        final scope =
            this.scope ??
            controller.scope ??
            AssetCacheProvider.maybeOf(context);
        Widget still() {
          final poster = this.poster;
          if (poster != null) return poster;
          if (state.released ||
              item == null ||
              presetOf == null ||
              scope == null) {
            return const SizedBox.expand();
          }
          return ContentView(
            content: item.key,
            preset: presetOf(const AssetProfile()),
            scope: scope,
            downloadContext: item.downloadContext,
          );
        }

        Widget picture() {
          final lease = state.lease;
          if (lease != null) {
            final loading = ViewerPolicyScope.resolve(context).loading;
            final player = PlayerOverStandIn(
              lease: lease,
              standIn: still(),
              fit: fit,
              fadeIn: loading.playerFadeIn,
              handedOverFadeIn: loading.playerFadeInHandedOver,
            );
            if (!showsBuffering) return player;
            return Stack(
              fit: StackFit.expand,
              children: [
                player,
                ViewerBufferingSpinner(lease: lease, rules: loading),
              ],
            );
          }
          final clip = state.clip;
          if (clip == null ||
              item == null ||
              presetOf == null ||
              scope == null) {
            return still();
          }
          return ContentView(
            content: item.key,
            preset: presetOf(clip),
            scope: scope,
            visibleFraction: state.fraction,
            downloadContext: item.downloadContext,
          );
        }

        final overlays = status is! MediaStatusMode$None || badge;
        if (!overlays ||
            state.released ||
            item == null ||
            presetOf == null ||
            scope == null) {
          return picture();
        }
        // The controls over whatever draws the picture: a view of the
        // still's entry that paints nothing of its own, so the staged view,
        // the clip and a player all get the same control and badge, and
        // the control's taps download or cancel the content.
        return Stack(
          fit: StackFit.expand,
          children: [
            // The picture a viewer opens from: the player's frame or the
            // view's, never the controls over them.
            ContentPicture(child: picture()),
            ContentView(
              key: const ValueKey('mpx-feed-overlays'),
              content: item.key,
              preset: presetOf(const AssetProfile()),
              scope: scope,
              downloadContext: item.downloadContext,
              opacity: 0,
              status: status,
              badge: badge,
            ),
          ],
        );
      },
    );
  }

  AssetPreset Function(AssetProfile profile)? _presetOf(
    FeedController controller,
    int index,
  ) {
    final own = preset;
    if (own != null) return own;
    final shared = controller.presetOf;
    if (shared == null) return null;
    return (profile) => shared(index, profile);
  }
}
