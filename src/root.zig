//! By convention, root.zig is the root source file when making a package.

pub const Agent = @import("Agent.zig");
pub const Billy = @import("Billy.zig");
pub const Config = @import("Config.zig");
pub const Credentials = @import("Credentials.zig");
pub const diff = @import("diff.zig");
pub const Dirs = @import("Dirs.zig");
pub const endpoint = @import("endpoint.zig");
pub const Health = @import("Health.zig");
pub const html = @import("html.zig");
pub const http = @import("http.zig");
pub const LineEditor = @import("LineEditor.zig");
pub const llm = @import("llm.zig");
pub const md = @import("md.zig");
pub const models = @import("models.zig");
pub const report = @import("report.zig");
pub const Server = @import("Server.zig");
pub const Session = @import("Session.zig");
pub const setup = @import("setup.zig");
pub const Terminal = @import("Terminal.zig");
pub const Tools = @import("Tools.zig");
pub const ulid = @import("ulid.zig");
pub const xdg = @import("xdg.zig");

test {
    // `zig build test` only collects the tests declared in the test target's
    // root file. The declarations above are lazy, so without this the tests in
    // the imported files are never analyzed and the suite silently runs nothing.
    @import("std").testing.refAllDecls(@This());
}
