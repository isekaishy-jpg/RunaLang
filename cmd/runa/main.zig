const std = @import("std");
const common = @import("cmd_common");
const bootstrap = @import("bootstrap");
const compiler = @import("compiler");
const toolchain = @import("toolchain");
const libraries = @import("libraries");

pub const Command = enum {
    new,
    build,
    check,
    @"test",
    fmt,
    doc,
    publish,
};

const help_lines = [_][]const u8{
    "Runa stage0 CLI.",
    "Subcommands: new build check test fmt doc publish",
};

pub fn main(init: std.process.Init) !void {
    _ = bootstrap;
    _ = libraries;

    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len <= 1) {
        try common.writeLines(init.io, &help_lines);
        return;
    }

    const command = parseSubcommand(args[1]) orelse return error.UnknownSubcommand;
    switch (command) {
        .new => try runNew(init, args),
        .build => try runBuild(init),
        .check => try runCheck(init),
        .@"test" => try runTest(init),
        .fmt => try runFmt(init),
        .doc => try runDoc(init),
        .publish => try runPublish(init, args),
    }
}

pub fn parseSubcommand(raw: []const u8) ?Command {
    inline for (toolchain.workflow_subcommands, 0..) |name, index| {
        if (std.mem.eql(u8, raw, name)) {
            return @as(Command, @enumFromInt(index));
        }
    }
    return null;
}

fn runCheck(init: std.process.Init) !void {
    const cwd = try std.process.currentPathAlloc(init.io, init.arena.allocator());
    var graph = toolchain.workspace.loadGraphAtPath(init.arena.allocator(), init.io, cwd) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa check: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer graph.deinit();
    var compiler_graph = try toolchain.workspace.toCompilerGraph(init.arena.allocator(), &graph);
    defer compiler_graph.deinit();

    var active = compiler.semantic.openGraph(init.arena.allocator(), init.io, compiler_graph.graph) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa check: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer active.deinit();

    try printDiagnostics(init, active.pipeline.diagnostics, &active.pipeline.sources);
    if (active.pipeline.diagnostics.hasErrors()) return error.CheckFailed;

    const summary = try std.fmt.allocPrint(init.arena.allocator(), "runa check: ok ({d} files, {d} items)", .{
        active.pipeline.sourceFileCount(),
        active.pipeline.itemCount(),
    });
    try common.writeLine(init.io, summary);
}

fn runNew(init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 3) {
        try common.writeLine(init.io, "runa new: missing package name");
        return error.MissingPackageName;
    }

    const cwd = try std.process.currentPathAlloc(init.io, init.arena.allocator());
    const package_dir = toolchain.workspace.createPackageAtPath(init.arena.allocator(), init.io, cwd, args[2]) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa new: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };

    const summary = try std.fmt.allocPrint(init.arena.allocator(), "runa new: created {s}", .{package_dir});
    try common.writeLine(init.io, summary);
}

fn runBuild(init: std.process.Init) !void {
    var result = toolchain.build.buildCurrentWorkspace(init.arena.allocator(), init.io) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa build: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer result.deinit();

    try printDiagnostics(init, result.pipeline.diagnostics, &result.pipeline.sources);
    if (result.pipeline.diagnostics.hasErrors()) return error.BuildFailed;

    const summary = try std.fmt.allocPrint(init.arena.allocator(), "runa build: ok ({d} artifacts)", .{result.artifacts.items.len});
    try common.writeLine(init.io, summary);
    for (result.artifacts.items) |artifact| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "  {s}: {s}", .{
            artifact.name,
            artifact.path,
        });
        try common.writeLine(init.io, line);
    }
}

fn runFmt(init: std.process.Init) !void {
    const cwd = try std.process.currentPathAlloc(init.io, init.arena.allocator());
    var loaded_workspace = toolchain.workspace.loadAtPath(init.arena.allocator(), init.io, cwd) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa fmt: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer loaded_workspace.deinit();
    var graph = try toolchain.workspace.loadGraphAtPath(init.arena.allocator(), init.io, cwd);
    defer graph.deinit();
    var compiler_graph = try toolchain.workspace.toCompilerGraph(init.arena.allocator(), &graph);
    defer compiler_graph.deinit();

    var active = compiler.semantic.openGraph(init.arena.allocator(), init.io, compiler_graph.graph) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa fmt: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer active.deinit();

    try printDiagnostics(init, active.pipeline.diagnostics, &active.pipeline.sources);
    if (active.pipeline.diagnostics.hasErrors()) return error.CheckFailed;

    const result = try toolchain.fmt.formatPipeline(init.arena.allocator(), init.io, &active.pipeline, true);
    const summary = try std.fmt.allocPrint(init.arena.allocator(), "runa fmt: formatted {d} files, changed {d}", .{
        result.formatted_files,
        result.changed_files,
    });
    try common.writeLine(init.io, summary);
}

fn runDoc(init: std.process.Init) !void {
    const cwd = try std.process.currentPathAlloc(init.io, init.arena.allocator());
    var loaded_workspace = toolchain.workspace.loadAtPath(init.arena.allocator(), init.io, cwd) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa doc: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer loaded_workspace.deinit();
    var graph = try toolchain.workspace.loadGraphAtPath(init.arena.allocator(), init.io, cwd);
    defer graph.deinit();
    var compiler_graph = try toolchain.workspace.toCompilerGraph(init.arena.allocator(), &graph);
    defer compiler_graph.deinit();

    var active = compiler.semantic.openGraph(init.arena.allocator(), init.io, compiler_graph.graph) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa doc: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer active.deinit();

    try printDiagnostics(init, active.pipeline.diagnostics, &active.pipeline.sources);
    if (active.pipeline.diagnostics.hasErrors()) return error.CheckFailed;

    const doc_output = try toolchain.doc.renderWorkspaceSummary(init.arena.allocator(), &loaded_workspace, &active);
    defer init.arena.allocator().free(doc_output);

    var lines = std.mem.splitScalar(u8, doc_output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try common.writeLine(init.io, line);
    }
}

fn runTest(init: std.process.Init) !void {
    var result = toolchain.build.buildCurrentWorkspace(init.arena.allocator(), init.io) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa test: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer result.deinit();

    try printDiagnostics(init, result.pipeline.diagnostics, &result.pipeline.sources);
    if (result.pipeline.diagnostics.hasErrors()) return error.BuildFailed;

    var executed: usize = 0;
    var passed: usize = 0;

    for (result.artifacts.items) |artifact| {
        if (artifact.kind != .bin) continue;
        if (!toolchain.testing.isTestProduct(&result.workspace, artifact.name)) continue;

        executed += 1;
        const line = try std.fmt.allocPrint(init.arena.allocator(), "test {s}", .{artifact.name});
        try common.writeLine(init.io, line);

        const run_result = try std.process.run(init.arena.allocator(), init.io, .{
            .argv = &.{artifact.path},
            .cwd = .inherit,
        });
        defer init.arena.allocator().free(run_result.stdout);
        defer init.arena.allocator().free(run_result.stderr);

        switch (run_result.term) {
            .exited => |code| {
                if (code == 0) {
                    passed += 1;
                    const ok_line = try std.fmt.allocPrint(init.arena.allocator(), "  ok ({d})", .{code});
                    try common.writeLine(init.io, ok_line);
                } else {
                    const fail_line = try std.fmt.allocPrint(init.arena.allocator(), "  fail ({d})", .{code});
                    try common.writeLine(init.io, fail_line);
                    return error.TestFailed;
                }
            },
            else => {
                try common.writeLine(init.io, "  fail (abnormal termination)");
                return error.TestFailed;
            },
        }
    }

    const summary = try std.fmt.allocPrint(init.arena.allocator(), "runa test: {d} passed, {d} total", .{
        passed,
        executed,
    });
    try common.writeLine(init.io, summary);
}

fn runPublish(init: std.process.Init, args: []const []const u8) !void {
    const registry = if (args.len >= 3) args[2] else "default";
    const cwd = try std.process.currentPathAlloc(init.io, init.arena.allocator());
    var loaded_workspace = toolchain.workspace.loadAtPath(init.arena.allocator(), init.io, cwd) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa publish: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer loaded_workspace.deinit();
    var graph = try toolchain.workspace.loadGraphAtPath(init.arena.allocator(), init.io, cwd);
    defer graph.deinit();
    var compiler_graph = try toolchain.workspace.toCompilerGraph(init.arena.allocator(), &graph);
    defer compiler_graph.deinit();

    var active = compiler.semantic.openGraph(init.arena.allocator(), init.io, compiler_graph.graph) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa publish: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer active.deinit();

    try printDiagnostics(init, active.pipeline.diagnostics, &active.pipeline.sources);
    if (active.pipeline.diagnostics.hasErrors()) return error.CheckFailed;

    var result = toolchain.publish.publishCurrentWorkspace(init.arena.allocator(), init.io, registry) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runa publish: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer result.deinit(init.arena.allocator());

    const summary = try std.fmt.allocPrint(init.arena.allocator(), "runa publish: ok ({s}, {d} files, {d} artifacts)", .{
        result.source_root,
        result.copied_source_files,
        result.published_artifacts,
    });
    try common.writeLine(init.io, summary);
}

fn printDiagnostics(init: std.process.Init, diagnostics: compiler.diag.Bag, sources: *const compiler.source.Table) !void {
    for (diagnostics.items.items, 0..) |_, index| {
        const line = try diagnostics.formatDiagnostic(init.arena.allocator(), index, sources);
        try common.writeLine(init.io, line);
    }
}
