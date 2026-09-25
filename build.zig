const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Markdown. The C library is built into the `billy` module, so every target
    // that uses the module -- the executable and the module's own tests -- gets
    // it, and none of them has to know where it came from.
    const md4c = b.dependency("md4c", .{});

    const mod = b.addModule("billy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(md4c.path("src"));
    mod.addCSourceFiles(.{
        .root = md4c.path("src"),
        .files = &.{ "md4c.c", "md4c-html.c", "entity.c" },
        // C99, because the library is written in it. UTF-8, because a reply is
        // UTF-8 and md4c is told which encoding to expect rather than guessing.
        .flags = &.{ "-std=c99", "-DMD4C_USE_UTF8" },
    });

    const exe = b.addExecutable(.{
        .name = "billy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "billy", .module = mod },
            },
        }),
    });
    // Dropping unreachable sections keeps the markdown library's unused code out
    // of the binary, and it is also what lets a build that links libc work here
    // at all: this system's `crt1.o` carries an `.sframe` section whose
    // relocations the linker cannot resolve, and something has to remove it. See
    // the note on `md.zig` for why libc is linked.
    exe.link_gc_sections = true;
    b.installArtifact(exe);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.link_gc_sections = true;
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.link_gc_sections = true;
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
