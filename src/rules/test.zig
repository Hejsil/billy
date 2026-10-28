//! The root the rules are tested from. Nothing in billy imports a rule -- they
//! are read by the linter, which is its own program -- so their tests are
//! reached from here, one line per file, and `build.zig` builds this instead of
//! naming them.

test {
    _ = @import("comment_budget.zig");
    _ = @import("hint_is_not_a_failure.zig");
    _ = @import("method_by_receiver.zig");
    _ = @import("no_bool_compare.zig");
    _ = @import("no_flush_in_defer.zig");
    _ = @import("no_log_newline.zig");
    _ = @import("no_unformatted_print.zig");
    _ = @import("report_failure_once.zig");
}
