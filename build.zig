const std = @import("std");
const Translator = @import("translate_c").Translator;
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filters = b.option([]const []const u8, "filter", "Run only tests whose names contain this substring") orelse &.{};

    // md4cs is the one markdown parser: mdflow's md4c, streamed for a reply as it arrives and batch
    // for a stored block, so the two frontends cannot drift.
    const mdflow = b.dependency("mdflow", .{
        .target = target,
        .optimize = optimize,
    });
    const spaghet = b.dependency("spaghet", .{
        .target = target,
        .optimize = optimize,
    });

    const translate_c = b.dependency("translate_c", .{});
    const md4cs_zig: Translator = .init(translate_c, .{
        .name = "md4cs",
        .c_source_file = b.path("src/md4cs_binding.h"),
        .target = target,
        .optimize = optimize,
    });
    md4cs_zig.addIncludePath(mdflow.path("src"));
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
        // C99, because the library is written in it, so a compiler whose default is newer or older
        // does not decide whether it builds.
        .flags = &.{
            "-std=c99",
            "-DMD4C_USE_UTF8",
            "-DMD4C_STREAMING",
            "-Dmd_parse=md4cs_parse_stream",
        },
    });
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
    // Dropping unreachable sections keeps the markdown library's unused code out of the binary, and
    // it is also what lets a build that links libc work here at all: this system's `crt1.o` carries
    // an `.sframe` section whose relocations the linker cannot resolve, and something has to remove
    // it.
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

    // The lint rules are billy's own source, but nothing imports them, so the module above never
    // reaches them: they are built and tested from a root of their own, against the same zlinter
    // the lint step uses.
    const rules_module = b.createModule(.{
        .root_source_file = b.path("src/rules/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zlinter", .module = b.dependency("zlinter", .{}).module("zlinter") },
        },
    });
    const rules_tests = b.addTest(.{ .root_module = rules_module });
    const run_rules_tests = b.addRunArtifact(rules_tests);

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_rules_tests.step);

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
        builder.addRule(.{ .builtin = .file_naming }, .{});
        builder.addRule(.{ .builtin = .no_literal_args }, .{ .detect_bool_literal = .@"error" });
        builder.addRule(.{ .builtin = .no_swallow_error }, .{
            .detect_catch_unreachable = .@"error",
            .detect_empty_catch = .@"error",
            .detect_empty_else = .@"error",
            .detect_else_unreachable = .@"error",
        });
        builder.addRule(.{ .builtin = .require_errdefer_dealloc }, .{ .severity = .@"error" });
        builder.addRule(.{ .builtin = .no_redundant_comptime }, .{ .severity = .@"error" });
        builder.addRule(.{ .builtin = .import_ordering }, .{ .severity = .@"error" });
        builder.addRule(.{ .builtin = .no_empty_block }, .{});
        builder.addRule(.{ .builtin = .function_naming }, .{});
        builder.addRule(.{ .builtin = .switch_case_ordering }, .{ .else_is_last = .@"error" });
        builder.addRule(.{ .builtin = .no_comment_out_code }, .{ .severity = .@"error" });
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{ .severity = .@"error" });
        builder.addRule(.{ .builtin = .no_panic }, .{ .severity = .@"error" });
        builder.addRule(.{ .builtin = .no_hidden_allocations }, .{ .severity = .@"error" });
        builder.addRule(.{ .builtin = .no_literal_only_bool_expression }, .{});
        builder.addRule(.{ .builtin = .build_zig_zon }, .{});
        builder.addRule(.{ .builtin = .no_unsafe_undefined }, .{
            .return_value = .@"error",
            .break_value = .@"error",
            .const_value = .@"error",
            .optional_value = .@"error",
            .pointer_value = .@"error",
            .enum_or_union_value = .@"error",
            .primitive_scalar_value = .@"error",
        });
        builder.addCustomRule("no_bool_compare", b.path("src/rules/no_bool_compare.zig"), .{});
        builder.addCustomRule("no_unformatted_print", b.path("src/rules/no_unformatted_print.zig"), .{});
        builder.addCustomRule("no_log_newline", b.path("src/rules/no_log_newline.zig"), .{});
        builder.addCustomRule("report_failure_once", b.path("src/rules/report_failure_once.zig"), .{});
        builder.addCustomRule("method_by_receiver", b.path("src/rules/method_by_receiver.zig"), .{});
        builder.addCustomRule("hint_is_not_a_failure", b.path("src/rules/hint_is_not_a_failure.zig"), .{});
        builder.addCustomRule("no_flush_in_defer", b.path("src/rules/no_flush_in_defer.zig"), .{});
        builder.addCustomRule("comment_budget", b.path("src/rules/comment_budget.zig"), .{});
        builder.addCustomRule("atomic_write", b.path("src/rules/atomic_write.zig"), .{});
        builder.addPaths(.{
            .include_dirs = &.{b.path("src")},
            .include_files = &.{ b.path("build.zig"), b.path("build.zig.zon") },
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
