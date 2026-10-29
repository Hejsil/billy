const std = @import("std");
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filters = b.option([]const []const u8, "filter", "Run only tests whose names contain this substring") orelse &.{};

    const spaghet = b.dependency("spaghet", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("billy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
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
    b.installArtifact(exe);

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = filters,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
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
        builder.addCustomRule("streamed_write", b.path("src/rules/streamed_write.zig"), .{});
        builder.addCustomRule("unfailable_error", b.path("src/rules/unfailable_error.zig"), .{});
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
