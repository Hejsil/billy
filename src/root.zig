//! By convention, root.zig is the root source file when making a package.

pub const agent = @import("Agent.zig");
pub const Config = @import("Config.zig");
pub const credentials = @import("credentials.zig");
pub const diff = @import("diff.zig");
pub const format = @import("format.zig");
pub const Health = @import("Health.zig");
pub const html = @import("html.zig");
pub const LineEditor = @import("LineEditor.zig");
pub const llm = @import("llm.zig");
pub const md = @import("md.zig");
pub const models = @import("models.zig");
pub const tools_web = @import("Tools/web.zig");
pub const Setup = @import("Setup.zig");
pub const Session = @import("Session.zig");
pub const Terminal = @import("Terminal.zig");
pub const Tools = @import("Tools.zig");
pub const web = @import("web.zig");
pub const ulid = @import("ulid.zig");
pub const xdg = @import("xdg.zig");

test {
    // `zig build test` only collects the tests declared in the test target's
    // root file. The declarations above are lazy, so without this the tests in
    // the imported files are never analyzed and the suite silently runs nothing.
    @import("std").testing.refAllDecls(@This());
}
