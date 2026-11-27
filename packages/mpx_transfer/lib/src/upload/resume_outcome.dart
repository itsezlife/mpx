/// What the upload engine decided for an upload that ran before, when a
/// run of it begins again (after a restart, a pause or a retry): the
/// `outcome` of `TransportOp.resumeDecision`.
enum ResumeOutcome {
  /// The source is unchanged and the transport's window open: the session
  /// reopened with the resume token and the upload continues after its
  /// high-water mark.
  resumed,

  /// The source file changed since the upload read it: it starts from
  /// zero.
  sourceChanged,

  /// The transport's freshness window closed (its window by size, the
  /// remote end's expiry carried with the token, or the remote end no
  /// longer had the upload): it starts from zero.
  windowExpired,

  /// The transport cannot reopen an upload, or there was nothing to reopen
  /// it with: it starts from zero.
  noResume,

  /// The source is gone: the job fails with its source lost.
  sourceLost,
}
