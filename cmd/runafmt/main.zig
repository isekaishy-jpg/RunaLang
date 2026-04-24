const std = @import("std");
const common = @import("cmd_common");
const compiler = @import("compiler");
const toolchain = @import("toolchain");

pub fn main(init: std.process.Init) !void {
    _ = toolchain.fmt;

    const cwd = try std.process.currentPathAlloc(init.io, init.arena.allocator());
    var graph = toolchain.workspace.loadGraphAtPath(init.arena.allocator(), init.io, cwd) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runafmt: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer graph.deinit();
    var compiler_graph = try toolchain.workspace.toCompilerGraph(init.arena.allocator(), &graph);
    defer compiler_graph.deinit();

    var active = compiler.semantic.openGraph(init.arena.allocator(), init.io, compiler_graph.graph) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runafmt: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer active.deinit();

    for (active.pipeline.diagnostics.items.items, 0..) |_, index| {
        const line = try active.pipeline.diagnostics.formatDiagnostic(init.arena.allocator(), index, &active.pipeline.sources);
        try common.writeLine(init.io, line);
    }
    if (active.pipeline.diagnostics.hasErrors()) return error.CheckFailed;

    const result = try toolchain.fmt.formatPipeline(init.arena.allocator(), init.io, &active.pipeline, true);
    const summary = try std.fmt.allocPrint(init.arena.allocator(), "runafmt: formatted {d} files, changed {d}", .{
        result.formatted_files,
        result.changed_files,
    });
    try common.writeLine(init.io, summary);
}
