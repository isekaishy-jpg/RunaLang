const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bootstrap_mod = b.addModule("bootstrap", .{
        .root_source_file = b.path("bootstrap/zig/root.zig"),
        .target = target,
    });
    const compiler_mod = b.addModule("compiler", .{
        .root_source_file = b.path("compiler/root.zig"),
        .target = target,
    });
    const toolchain_mod = b.addModule("toolchain", .{
        .root_source_file = b.path("toolchain/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "compiler", .module = compiler_mod },
        },
    });
    const libraries_mod = b.addModule("libraries", .{
        .root_source_file = b.path("libraries/root.zig"),
        .target = target,
    });
    const cmd_common_mod = b.addModule("cmd_common", .{
        .root_source_file = b.path("cmd/common.zig"),
        .target = target,
    });
    const bench_imports: []const std.Build.Module.Import = &.{
        .{ .name = "compiler", .module = compiler_mod },
        .{ .name = "toolchain", .module = toolchain_mod },
    };

    const app_imports: []const std.Build.Module.Import = &.{
        .{ .name = "bootstrap", .module = bootstrap_mod },
        .{ .name = "compiler", .module = compiler_mod },
        .{ .name = "toolchain", .module = toolchain_mod },
        .{ .name = "libraries", .module = libraries_mod },
        .{ .name = "cmd_common", .module = cmd_common_mod },
    };

    const runa_cli_mod = b.addModule("runa_cli", .{
        .root_source_file = b.path("cmd/runa/main.zig"),
        .target = target,
        .imports = app_imports,
    });

    const runa = addTool(b, target, optimize, "runa", "cmd/runa/main.zig", app_imports);
    _ = addTool(b, target, optimize, "runac", "cmd/runac/main.zig", app_imports);
    _ = addTool(b, target, optimize, "runafmt", "cmd/runafmt/main.zig", app_imports);
    _ = addTool(b, target, optimize, "runadoc", "cmd/runadoc/main.zig", app_imports);
    _ = addTool(b, target, optimize, "runals", "cmd/runals/main.zig", app_imports);

    const run_step = b.step("run", "Run the primary runa CLI");
    const run_cmd = b.addRunArtifact(runa);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const scaffold_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/scaffold_shape_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &[_]std.Build.Module.Import{
                .{ .name = "bootstrap", .module = bootstrap_mod },
                .{ .name = "compiler", .module = compiler_mod },
                .{ .name = "toolchain", .module = toolchain_mod },
                .{ .name = "libraries", .module = libraries_mod },
                .{ .name = "runa_cli", .module = runa_cli_mod },
            },
        }),
    });
    const run_scaffold_tests = b.addRunArtifact(scaffold_tests);

    const test_step = b.step("test", "Run scaffold smoke tests");
    test_step.dependOn(&run_scaffold_tests.step);

    const parser_bench = b.addExecutable(.{
        .name = "parser-frontend-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/parser_frontend_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = bench_imports,
        }),
    });
    const run_parser_bench = b.addRunArtifact(parser_bench);
    const bench_step = b.step("bench", "Run parser/frontend benchmarks");
    bench_step.dependOn(&run_parser_bench.step);
    const bench_parser_step = b.step("bench-parser", "Run parser/frontend benchmarks");
    bench_parser_step.dependOn(&run_parser_bench.step);
    if (b.args) |args| {
        run_parser_bench.addArgs(args);
    }
}

fn addTool(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source_file: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });

    b.installArtifact(exe);
    return exe;
}
