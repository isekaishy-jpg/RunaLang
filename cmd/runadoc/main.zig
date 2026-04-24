const std = @import("std");
const common = @import("cmd_common");
const compiler = @import("compiler");
const libraries = @import("libraries");
const toolchain = @import("toolchain");

pub fn main(init: std.process.Init) !void {
    _ = libraries;
    _ = toolchain.doc;

    const cwd = try std.process.currentPathAlloc(init.io, init.arena.allocator());
    var loaded_workspace = toolchain.workspace.loadAtPath(init.arena.allocator(), init.io, cwd) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runadoc: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer loaded_workspace.deinit();
    var graph = try toolchain.workspace.loadGraphAtPath(init.arena.allocator(), init.io, cwd);
    defer graph.deinit();
    var compiler_graph = try toolchain.workspace.toCompilerGraph(init.arena.allocator(), &graph);
    defer compiler_graph.deinit();

    var active = compiler.semantic.openGraph(init.arena.allocator(), init.io, compiler_graph.graph) catch |err| {
        const line = try std.fmt.allocPrint(init.arena.allocator(), "runadoc: {s}", .{@errorName(err)});
        try common.writeLine(init.io, line);
        return err;
    };
    defer active.deinit();

    for (active.pipeline.diagnostics.items.items, 0..) |_, index| {
        const line = try active.pipeline.diagnostics.formatDiagnostic(init.arena.allocator(), index, &active.pipeline.sources);
        try common.writeLine(init.io, line);
    }
    if (active.pipeline.diagnostics.hasErrors()) return error.CheckFailed;

    const doc_output = try toolchain.doc.renderWorkspaceSummary(init.arena.allocator(), &loaded_workspace, &active);
    defer init.arena.allocator().free(doc_output);

    var lines = std.mem.splitScalar(u8, doc_output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try common.writeLine(init.io, line);
    }
}
