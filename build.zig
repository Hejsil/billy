const std = @import("std");
const Translator = @import("translate_c").Translator;
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filters = b.option([]const []const u8, "filter", "Run only tests whose names contain this substring") orelse &.{};

    const mdflow = b.dependency("mdflow", .{
        .target = target,
        .optimize = optimize,
    });
    const spaghet = b.dependency("spaghet", .{
        .target = target,
        .optimize = optimize,
    });

    // mdflow's md4cs is billy's only markdown parser. It is a fork of md4c that
    // keeps md4c's callback API but can also read a document while it is still
    // arriving, which is what lets the terminal show a reply as the model writes
    // it. The same parser, in its batch mode, reads a whole stored block for the
    // web frontend, so the two frontends cannot drift apart on markdown.
    //
    // Only the parser is built. mdflow's ANSI renderer would replace billy's own
    // output style, and its `html.c` is a scanner for raw HTML *input*, not a
    // renderer to HTML; billy's `html.zig` and `Terminal/Markdown.zig` are the
    // renderers.
    //
    // The header is translated at build time, since `@cImport` was removed in
    // Zig 0.17 and translate-c is now a package of its own. It includes
    // `entity.h` as well as `md4cs.h`, because billy decodes entities itself.
    const translate_c = b.dependency("translate_c", .{});
    const md4cs_zig: Translator = .init(translate_c, .{
        .name = "md4cs",
        .c_source_file = b.path("src/md4cs_binding.h"),
        .target = target,
        .optimize = optimize,
    });
    md4cs_zig.addIncludePath(mdflow.path("src"));
    // Also set in the C flags below, so the translated header and the compiled
    // library agree on the encoding.
    md4cs_zig.defineCMacro("MD4C_USE_UTF8", null);
    md4cs_zig.defineCMacro("MD4C_STREAMING", null);
    md4cs_zig.defineCMacro("md_parse", "md4cs_parse_stream");

    const mod = b.addModule("billy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("md4cs", md4cs_zig.mod);
    mod.addIncludePath(mdflow.path("src"));
    mod.addCSourceFiles(.{
        .root = mdflow.path("src"),
        .files = &.{ "md4cs.c", "entity.c" },
        // C99, because the library is written in it, so a compiler whose default
        // is newer or older does not decide whether it builds.
        .flags = &.{
            "-std=c99",
            "-DMD4C_USE_UTF8",
            "-DMD4C_STREAMING",
            // The streaming build's `md_parse` is the batch entry point without
            // the context it needs, and upstream never uses it; only the
            // `md_stream_*` entry points are called. It is named apart so no one
            // reaches for it by mistake.
            "-Dmd_parse=md4cs_parse_stream",
        },
    });
    // The same parser, built in its batch mode. mdflow's own build does this too:
    // the streaming build does not carry a working `md_parse`, and a whole
    // document -- a stored block for the page, or a replayed reply -- should be
    // read by the batch parser so loose lists and reference links resolve the
    // way CommonMark says. The entity table is shared with the streaming build.
    mod.addCSourceFiles(.{
        .root = mdflow.path("src"),
        .files = &.{"md4cs.c"},
        .flags = &.{
            "-std=c99",
            "-DMD4C_USE_UTF8",
            "-Dmd_parse=md4cs_parse_batch",
        },
    });

    const exe = b.addExecutable(.{
        .name = "billy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "billy", .module = mod },
                .{ .name = "spaghet", .module = spaghet.module("spaghet") },
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

    const lint = b.step("lint", "Lint the source");
    lint.dependOn(step: {
        var builder = zlinter.builder(b, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{ .severity = .@"error" });
        builder.addRule(.{ .builtin = .no_unused }, .{ .container_declaration = .@"error" });
        builder.addPaths(.{
            .include_dirs = &.{b.path("src")},
            .include_files = &.{b.path("build.zig")},
        });
        break :step builder.build();
    });

    const all = b.step("all", "Build and install billy, run the tests, check formatting, and lint");
    all.dependOn(b.getInstallStep());
    all.dependOn(test_step);
    all.dependOn(fmt_step);
    all.dependOn(lint);
    b.default_step = all;
}
