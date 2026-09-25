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
        // md4c-html.c is built for its renderer, which only the oracle test uses
        // (to check billy's own renderer against md4c's); the executable does not
        // call it, so the linker drops it.
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

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check that every source file is formatted");
    fmt_step.dependOn(&fmt.step);

    // `zig build` does the whole lot: it builds and installs billy, runs the
    // tests, and checks the formatting, so one command is the whole check. The
    // steps are named, so a narrower thing is one word away: `zig build install`
    // builds and installs alone, `zig build test` runs the tests alone, and
    // `zig build fmt` checks the formatting alone. See `b.default_step`: it is
    // the install step until it is set to something else, so it is set here.
    const all = b.step("all", "Build and install billy, run the tests, and check formatting");
    all.dependOn(b.getInstallStep());
    all.dependOn(test_step);
    all.dependOn(fmt_step);
    b.default_step = all;
}
