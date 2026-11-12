/// How urgently a caller needs a request's bytes.
///
/// Declared from least to most urgent, so a higher [index] is served first.
enum RequestPriority {
  /// Work nobody waits on (warming a cache, a background refresh).
  background,

  /// Bytes likely needed soon (the next cells, the next page).
  preload,

  /// Bytes something on screen waits for.
  visible
  ;

  /// Whether this priority is served before [other].
  bool isAbove(RequestPriority other) => index > other.index;
}

/// A request's [RequestPriority], which its caller may change at any time.
///
/// Mirrors a cancel token: the caller keeps it and the client reads it. A
/// queued request is served by the priority its tokens hold when a slot
/// frees, so raising [priority] (a cell scrolling into view) overtakes queued
/// preload and background work. A GET that already holds a slot is not
/// affected. A coalesced GET takes the highest priority among its callers.
final class PriorityToken {
  /// Starts at [priority].
  PriorityToken([this.priority = RequestPriority.visible]);

  /// The current priority; set it to move the request in the queue.
  RequestPriority priority;
}
