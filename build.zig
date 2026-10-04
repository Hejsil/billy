const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filters = b.option([]const []const u8, "filter", "Run only tests whose names contain this substring") orelse &.{};

    const md4c = b.dependency("md4c", .{});

    // The md4c binding is translated from its headers at build time, since
    // `@cImport` was removed in Zig 0.17 and translate-c is now a package of its
    // own. The header billy translates is one file that includes the three md4c
    // headers it needs, which is what the translator takes as its input.
    const translate_c = b.dependency("translate_c", .{});
    const md4c_zig: Translator = .init(translate_c, .{
        .name = "md4c",
        .c_source_file = b.path("src/md4c_binding.h"),
        .target = target,
        .optimize = optimize,
    });
    md4c_zig.addIncludePath(md4c.path("src"));
    // A reply is UTF-8, and md4c is told which encoding to expect rather than
    // guessing at it.
    md4c_zig.defineCMacro("MD4C_USE_UTF8", null);

    const mod = b.addModule("billy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("md4c", md4c_zig.mod);
    mod.addCSourceFiles(.{
        .root = md4c.path("src"),
        .files = &.{ "md4c.c", "md4c-html.c", "entity.c" },
        // C99, because the library is written in it, so a compiler whose default
        // is newer or older does not decide whether it builds. UTF-8, because a
        // reply is UTF-8 and md4c is told which encoding to expect rather than
        // guessing.
        .flags = &.{ "-std=c99", "-DMD4C_USE_UTF8" },
    });

    const exe = b.addExecutable(.{
        .name = "billy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "billy", .module = mod },
            },
        }),
    });
    // Dropping unreachable sections keeps the markdown library's unused code out
    // of the binary, and it is also what lets a build that links libc work here
    // at all: this system's `crt1.o` carries an `.sframe` section whose
    // relocations the linker cannot resolve, and something has to remove it.
    exe.link_gc_sections = true;
    b.installArtifact(exe);

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = filters,
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
        .paths = &.{ b.path("src"), b.path("build.zig"), b.path("build.zig.zon") },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Check that every source file is formatted");
    fmt_step.dependOn(&fmt.step);

    const all = b.step("all", "Build and install billy, run the tests, and check formatting");
    all.dependOn(b.getInstallStep());
    all.dependOn(test_step);
    all.dependOn(fmt_step);
    b.default_step = all;
}
