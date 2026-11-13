import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';

/// The media of the closest `FeedSlot`'s item, drawn the way the slot's
/// `FeedController` decided.
///
/// While the item holds a player (a pager's page and its warm neighbours) it
/// shows a `PlayerView`, with [poster] as the stand-in until the first
/// frame. Otherwise it shows the item through the asset cache: a list clip
/// that plays attaches with the policy's clip profile (looping, advancing
/// only above the advance floor) and its visible fraction; one that does not
/// shows its first frame; a pager page without a player shows its [poster].
///
/// The preset comes from [preset], else the controller's `presetOf`; the
/// cache from [scope], else the controller's, else the closest
/// `AssetCacheProvider`. Without a preset or a cache it shows the poster.
class FeedClip extends StatelessWidget {
  /// Shows the closest slot's item.
  const FeedClip({
    this.preset,
    this.poster,
    this.fit = BoxFit.contain,
    this.scope,
    super.key,
  });

  /// The size and decode of the item's media under a profile.
  final AssetPreset Function(AssetProfile profile)? preset;

  /// What shows while there is no picture: the item's still from the cache
  /// when null (with a preset), else nothing.
  final Widget? poster;

  /// How the player's picture fills the clip.
  final BoxFit fit;

  /// The cache the item's media attaches to.
  final AssetCacheScope? scope;

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
          if (item == null || presetOf == null || scope == null) {
            return const SizedBox.expand();
          }
          return ContentView(
            content: item.key,
            preset: presetOf(const AssetProfile()),
            scope: scope,
          );
        }

        final lease = state.lease;
        if (lease != null) {
          return PlayerView(lease: lease, fit: fit, standIn: still());
        }
        if (controller.policy.mode == FeedMode.pager ||
            item == null ||
            presetOf == null ||
            scope == null) {
          return still();
        }
        final clip = controller.policy.clipProfile();
        return ContentView(
          content: item.key,
          preset: presetOf(
            state.playing
                ? clip
                : AssetProfile(
                    loop: clip.loop,
                    cornerRadius: clip.cornerRadius,
                    fit: clip.fit,
                    advanceFloor: clip.advanceFloor,
                  ),
          ),
          scope: scope,
          visibleFraction: state.fraction,
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
