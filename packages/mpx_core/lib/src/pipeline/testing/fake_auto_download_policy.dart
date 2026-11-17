import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/pipeline/auto_download.dart';

/// An [AutoDownloadPolicy] a test sets by hand: [answer] for every tag not in
/// [byContext], and [changed] to tell the scope.
final class FakeAutoDownloadPolicy implements AutoDownloadPolicy {
  /// A policy answering [answer] until told otherwise.
  FakeAutoDownloadPolicy({
    this.answer = AutoDownload.manual,
    this.defaultContext,
  });

  /// The answer for a tag [byContext] does not list.
  AutoDownload answer;

  /// Answers per tag.
  final Map<AutoDownloadContext?, AutoDownload> byContext = {};

  @override
  AutoDownloadContext? defaultContext;

  /// Every question asked, oldest first.
  final List<(MediaDescriptor, AutoDownloadContext?)> asked = [];

  final _Changes _changes = _Changes();

  /// Tells the listeners of [changes] that answers may differ now.
  void changed() => _changes.fire();

  @override
  AutoDownload decide(
    MediaDescriptor descriptor,
    AutoDownloadContext? context,
  ) {
    asked.add((descriptor, context));
    return byContext[context] ?? answer;
  }

  @override
  Listenable get changes => _changes;
}

final class _Changes extends ChangeNotifier {
  void fire() => notifyListeners();
}
