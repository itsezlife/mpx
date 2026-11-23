/// What the viewer does with the system bars (the status bar and the
/// navigation bar) while it is open.
///
/// The navigation bar is clear whatever this is, and the pictures run under
/// it; with the controls shown the viewer draws its bar fill over it, as the
/// top bar's covers the status bar, and without them the picture shows
/// through.
enum ViewerSystemBars {
  /// The bars stay as the host has them.
  keep,

  /// The status bar hides with the viewer's controls and shows with them, as
  /// a messenger's viewer does; the navigation bar stays. They are as they
  /// were, edge to edge, when the viewer closes.
  hideStatusBar,

  /// Both bars hide with the controls (they come back with a swipe from the
  /// edge, and with the controls).
  hideAll,
}
