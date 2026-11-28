/// Who cancelled a job or removed an item: the `by` field of the
/// `cancelled` and `itemRemoved` events.
///
/// Internal to the package: the facade's verbs pick it.
enum CancelledBy {
  /// The user, through the facade's cancel.
  user,

  /// The job's owner: a publish job cancelling its uploads, or the host
  /// cancelling the publish job.
  owner,

  /// The OS envelope, as when the user cancels all from its notification.
  envelope,

  /// A cell bound to the item's key.
  cell,

  /// The host, removing an item from its publish job.
  host,
}
