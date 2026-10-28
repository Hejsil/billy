//! How a failure the user has already been told about is passed up, so nothing above it puts the
//! same thing into words again.

/// The failure a command returns once it has said what went wrong.
pub const Reported = error.Reported;
