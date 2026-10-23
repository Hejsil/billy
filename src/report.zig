//! How a failure the user has already been told about is passed up, so nothing
//! above it puts the same thing into words again.

/// The failure a command returns once it has said what went wrong.
///
/// A site that can explain a failure -- it knows which file, which setting,
/// which provider -- writes the sentence and returns this, rather than the
/// error underneath it. `main` treats it as a failure and stays quiet, because
/// saying it twice is how a typo in a flag comes to read as a crash: the
/// message, then the error's name, then a stack trace under both.
///
/// A failure the site cannot explain is returned as it is, and `main` reports
/// it once.
pub const Reported = error.Reported;
