/// The page's warning before it is closed or reloaded while transfers run.
///
/// The engine arms it while any job is queued or running and disarms it
/// when none is. Only the web has one: a closed tab ends every transfer in
/// it, and only the user can stop that.
///
/// Internal to the package: hosts never see it.
abstract interface class UnloadWarning {
  /// Whether leaving the page asks the user first.
  bool get isArmed;

  /// Makes leaving the page ask the user first. Arming twice is once.
  void arm();

  /// Lets the page be left without asking. Disarming twice is once.
  void disarm();
}
