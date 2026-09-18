//! By convention, root.zig is the root source file when making a package.

pub const agent = @import("agent.zig");
pub const config = @import("config.zig");
pub const format = @import("format.zig");
pub const line_editor = @import("line_editor.zig");
pub const llm = @import("llm.zig");
pub const models = @import("models.zig");
pub const session = @import("session.zig");
pub const style = @import("style.zig");
pub const tools = @import("tools.zig");

test {
    // `zig build test` only collects the tests declared in the test target's
    // root file. The declarations above are lazy, so without this the tests in
    // the imported files are never analyzed and the suite silently runs nothing.
    @import("std").testing.refAllDecls(@This());
}
