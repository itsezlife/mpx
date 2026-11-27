/// The web hook: no operating system version to read (the browser's user
/// agent is not one, and names the user's setup).
String? $operatingSystemVersion() => null;

/// The web hook: nothing to say about the device.
String? $deviceDescription() => null;

/// The web hook: no folder; the journal lives in memory for the page.
String? $journalDirectoryPath(String name) => null;
