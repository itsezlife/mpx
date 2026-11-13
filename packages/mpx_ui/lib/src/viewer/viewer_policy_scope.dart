import 'package:flutter/material.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';

/// Sets the policy of every viewer below that is given none, as a change to
/// the platform's reference: [policy] receives that reference and returns
/// the policy to use.
///
/// One function serves both needs: `(platform) => platform.copyWith(...)`
/// changes a field and keeps the platform's other values, `(_) => mine`
/// replaces the policy whole. Whatever the host does not set stays the
/// platform's.
///
/// ```dart
/// ViewerPolicyScope(
///   policy: (platform) => platform.copyWith(
///     video: platform.video.copyWith(start: ViewerVideoStart.origin),
///   ),
///   child: app,
/// )
/// ```
class ViewerPolicyScope extends InheritedWidget {
  /// Applies [policy] to the platform's reference for the viewers below.
  const ViewerPolicyScope({
    required this.policy,
    required super.child,
    super.key,
  });

  /// The policy to use, given the platform's reference.
  final ViewerPolicy Function(ViewerPolicy platformDefault) policy;

  /// The policy a viewer at [context] uses: [policy] when given, else the
  /// closest scope's applied to the platform's reference, else that
  /// reference. The platform is the theme's (`ThemeData.platform`), so a
  /// host that overrides it in its theme gets that platform's viewer.
  ///
  /// Registers [context] as a dependent of the theme and the scope.
  static ViewerPolicy resolve(BuildContext context, {ViewerPolicy? policy}) {
    if (policy != null) return policy;
    final platform = ViewerPolicy.forPlatform(Theme.of(context).platform);
    final scope = context
        .dependOnInheritedWidgetOfExactType<ViewerPolicyScope>();
    return scope == null ? platform : scope.policy(platform);
  }

  @override
  bool updateShouldNotify(ViewerPolicyScope oldWidget) =>
      !identical(policy, oldWidget.policy);
}
