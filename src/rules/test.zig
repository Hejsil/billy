//! The root the rules are tested from.

test {
    _ = @import("atomic_write.zig");
    _ = @import("comment_budget.zig");
    _ = @import("hint_is_not_a_failure.zig");
    _ = @import("method_by_receiver.zig");
    _ = @import("no_bool_compare.zig");
    _ = @import("no_flush_in_defer.zig");
    _ = @import("no_log_newline.zig");
    _ = @import("no_unformatted_print.zig");
    _ = @import("report_failure_once.zig");
}
