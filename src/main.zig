const std = @import("std");
const Io = std.Io;

const billy = @import("billy");

pub fn main(init: std.process.Init) !void {
    // Anything that lives as long as the process, including the conversation,
    // is allocated here.
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    const api_key = init.environ_map.get("DEEPSEEK_API_KEY") orelse
        init.environ_map.get("OPENAI_API_KEY") orelse {
        std.log.err("set DEEPSEEK_API_KEY to your API key", .{});
        return error.MissingApiKey;
    };
    const base_url = init.environ_map.get("BILLY_BASE_URL") orelse "https://api.deepseek.com";
    const config: billy.agent.Config = .{
        .api_key = api_key,
        .url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{
            std.mem.trimEnd(u8, base_url, "/"),
        }),
        .model = init.environ_map.get("BILLY_MODEL") orelse "deepseek-flash",
    };

    try out.print("billy · {s} · Ctrl-D to exit\n", .{config.model});
    try billy.agent.run(io, arena, init.gpa, out, config);
}
