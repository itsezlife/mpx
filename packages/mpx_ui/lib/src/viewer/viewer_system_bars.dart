/// What the viewer does with the system bars (the status bar and the
/// navigation bar) while it is open.
///
/// The pictures lie above the navigation bar whatever this is; it is clear,
/// and the viewer's own bars draw over it.
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
