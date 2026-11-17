import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';

/// Whether content missing from every cache is fetched without a user
/// action, most restrictive first, so the most permissive of several answers
/// is the one with the highest [index].
enum AutoDownload {
  /// Only the stand-ins (preview, thumbnail) are fetched; the surface shows
  /// a download control with the content's size.
  manual,

  /// The stand-ins and a playable head of the content (a staged prefix, not
  /// decoded) are fetched; the rest waits for the user.
  prefix,

  /// The content downloads now.
  now;

  /// The more permissive of this and [other].
  AutoDownload or(AutoDownload other) => other.index > index ? other : this;
}

/// The host's tag for where a surface shows content, passed per attach
/// (`AssetCacheScope.attach`), which an [AutoDownloadPolicy] weighs: the
/// kind of conversation, a feed, a section of the host's own.
///
/// Opaque to the core: it is compared with `==` and never read, and it is
/// never part of the cache key, so two surfaces of one content share one
/// entry whatever their tags. The well-known tags name the peer classes most
/// hosts have; a host may pass any value of its own.
@immutable
final class AutoDownloadContext {
  /// A tag carrying [value], equal to another tag of an equal value.
  const AutoDownloadContext(this.value);

  /// Content from a contact of the user.
  static const AutoDownloadContext contacts = AutoDownloadContext(
    _WellKnown.contacts,
  );

  /// Content from a one-to-one conversation with someone not in the
  /// contacts.
  static const AutoDownloadContext privateChats = AutoDownloadContext(
    _WellKnown.privateChats,
  );

  /// Content from a group conversation.
  static const AutoDownloadContext groups = AutoDownloadContext(
    _WellKnown.groups,
  );

  /// Content from a broadcast channel.
  static const AutoDownloadContext channels = AutoDownloadContext(
    _WellKnown.channels,
  );

  /// What the host tagged with. A private type backs the well-known tags,
  /// so a host's own string never equals one of them.
  final Object value;

  @override
  bool operator ==(Object other) =>
      other is AutoDownloadContext && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => switch (value) {
    final _WellKnown known => 'AutoDownloadContext.${known.name}',
    final other => 'AutoDownloadContext($other)',
  };
}

enum _WellKnown { contacts, privateChats, groups, channels }

/// The host's rule for which missing content downloads by itself.
///
/// The scope asks it for content that is missing from every cache (the
/// fetcher's `needsDownload`) once the content's descriptor is known, with
/// the tag of each attached surface; the most permissive answer wins, so
/// content shown in two places downloads when either allows it. Content held
/// in a cache is never asked about. A user's download (`AssetBinding.
/// download`) and cancel (`AssetBinding.cancelDownload`) override it.
abstract interface class AutoDownloadPolicy {
  /// Everything downloads at once, as with no policy: the default of a bare
  /// `AssetCacheScope`.
  static const AutoDownloadPolicy always = _Always();

  /// Whether the content of [descriptor], shown in [context], downloads.
  AutoDownload decide(MediaDescriptor descriptor, AutoDownloadContext? context);

  /// The tag of a surface that attached with none.
  AutoDownloadContext? get defaultContext;

  /// Fires when an answer of [decide] may have changed (the network class
  /// changed, the host's settings did); the scope then starts the waiting
  /// content that may download now.
  Listenable get changes;
}

final class _Always implements AutoDownloadPolicy {
  const _Always();

  @override
  AutoDownload decide(
    MediaDescriptor descriptor,
    AutoDownloadContext? context,
  ) => AutoDownload.now;

  @override
  AutoDownloadContext? get defaultContext => null;

  @override
  Listenable get changes => const _Silent();
}

final class _Silent implements Listenable {
  const _Silent();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
