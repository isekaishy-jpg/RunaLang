const std = @import("std");
const compiler = @import("compiler");
const context = @import("../cli/context.zig");
const package = @import("../package/root.zig");
const workspace = @import("../workspace/root.zig");

const Allocator = std.mem.Allocator;

pub const summary = "Shared semantic and structural check command.";
pub const authored_line_limit: usize = 3000;

pub const Result = struct {
    prep: workspace.CompilerPrep,
    active: compiler.session.Session,

    pub fn deinit(self: *Result) void {
        self.active.deinit();
        self.prep.deinit();
    }

    pub fn errorCount(self: *const Result) usize {
        return self.active.pipeline.diagnostics.errorCount();
    }

    pub fn hasErrors(self: *const Result) bool {
        return self.active.pipeline.diagnostics.hasErrors();
    }

    pub fn checkedPackageCount(self: *const Result) usize {
        return self.prep.graph.packages.items.len;
    }

    pub fn checkedProductCount(self: *const Result) usize {
        return self.prep.graph.root_products.items.len;
    }

    pub fn checkedSourceFileCount(self: *const Result) usize {
        return self.active.sourceFileCount();
    }
};

pub fn runContext(allocator: Allocator, io: std.Io, command_context: *const context.CommandContext) !Result {
    return switch (command_context.*) {
        .manifest_rooted => |*manifest_rooted| runManifestRooted(allocator, io, manifest_rooted),
        .standalone => error.MissingManifest,
    };
}

pub fn runManifestRooted(allocator: Allocator, io: std.Io, manifest_rooted: *const context.ManifestRootedContext) !Result {
    var prep = try manifest_rooted.prepareCompilerInputs(io, .local_authoring);
    errdefer prep.deinit();

    var active = try compiler.semantic.openGraph(allocator, io, prep.compiler_graph.graph);
    errdefer active.deinit();

    try validateExplicitPackageTargets(&prep.graph, &active.pipeline.diagnostics);
    try validateAuthoredSourceFiles(manifest_rooted, &active.pipeline);
    try validateLibraryProducts(manifest_rooted, &prep.graph, &active.pipeline);

    return .{
        .prep = prep,
        .active = active,
    };
}

fn validateExplicitPackageTargets(graph: *const workspace.Graph, diagnostics: *compiler.diag.Bag) !void {
    for (graph.packages.items) |package_node| {
        const selected_target = package_node.manifest.build_target orelse continue;
        if (!targetKnown(selected_target)) {
            try diagnostics.add(.@"error", "check.target.unknown", null, "unknown target '{s}'", .{selected_target});
            continue;
        }
        if (!std.mem.eql(u8, selected_target, compiler.target.hostName()) or !compiler.target.hostStage0Supported()) {
            try diagnostics.add(
                .@"error",
                "check.target.unsupported",
                null,
                "stage0 check supports only the current Windows host target; selected target is '{s}' and host is '{s}'",
                .{ selected_target, compiler.target.hostName() },
            );
        }
    }
}

fn targetKnown(selected_target: []const u8) bool {
    for (compiler.target.supported_targets) |known| {
        if (std.mem.eql(u8, selected_target, known)) return true;
    }
    return false;
}

fn validateAuthoredSourceFiles(
    manifest_rooted: *const context.ManifestRootedContext,
    pipeline: *compiler.driver.Pipeline,
) !void {
    for (pipeline.sources.files.items) |file| {
        if (!isAuthoredSourcePath(manifest_rooted, file.path)) continue;

        const lines = physicalLineCount(file.contents);
        if (lines <= authored_line_limit) continue;

        try pipeline.diagnostics.add(
            .@"error",
            "check.source.too_large",
            .{ .file_id = file.id, .start = 0, .end = 0 },
            "authored source file has {d} physical lines; maximum is {d}",
            .{ lines, authored_line_limit },
        );
    }
}

fn validateLibraryProducts(
    manifest_rooted: *const context.ManifestRootedContext,
    graph: *const workspace.Graph,
    pipeline: *compiler.driver.Pipeline,
) !void {
    for (graph.root_products.items, 0..) |product, root_index| {
        if (product.kind != .lib) continue;
        if (!isAuthoredSourcePath(manifest_rooted, product.root_path)) continue;

        const root_module = findRootModule(pipeline, root_index) orelse continue;
        if (rootModuleHasChildModule(root_module)) continue;

        const file_id = root_module.parsed.module.file_id;
        try pipeline.diagnostics.add(
            .@"error",
            "check.lib.child_module_missing",
            .{ .file_id = file_id, .start = 0, .end = 0 },
            "lib product '{s}' root must declare at least one child module",
            .{product.name},
        );
    }
}

fn findRootModule(pipeline: *compiler.driver.Pipeline, root_index: usize) ?*const compiler.driver.ModulePipeline {
    for (pipeline.modules.items) |*module_pipeline| {
        if (module_pipeline.root_index == root_index and module_pipeline.module_path.len == 0) return module_pipeline;
    }
    return null;
}

fn rootModuleHasChildModule(module_pipeline: *const compiler.driver.ModulePipeline) bool {
    for (module_pipeline.hir.items.items) |item| {
        if (item.kind == .module_decl) return true;
    }
    return false;
}

fn isAuthoredSourcePath(manifest_rooted: *const context.ManifestRootedContext, path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".rna")) return false;
    const relative = relativePathText(manifest_rooted.command_root, path) orelse return false;
    if (std.mem.eql(u8, relative, ".") or relative.len == 0) return true;
    if (pathStartsWithSegment(relative, "target")) return false;
    if (pathStartsWithSegment(relative, "dist")) return false;
    if (manifest_rooted.global_store) |store| {
        if (relativePathText(store.root, path) != null) return false;
    }
    return true;
}

fn physicalLineCount(contents: []const u8) usize {
    if (contents.len == 0) return 0;

    var lines: usize = 1;
    for (contents, 0..) |byte, index| {
        if (byte == '\n' and index + 1 < contents.len) lines += 1;
    }
    return lines;
}

fn pathStartsWithSegment(path: []const u8, segment: []const u8) bool {
    if (std.mem.eql(u8, path, segment)) return true;
    return std.mem.startsWith(u8, path, segment) and
        path.len > segment.len and
        (path[segment.len] == '/' or path[segment.len] == '\\');
}

fn relativePathText(root: []const u8, path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, path)) return ".";
    if (!std.mem.startsWith(u8, path, root)) return null;
    var relative = path[root.len..];
    if (relative.len != 0 and relative[0] != '/' and relative[0] != '\\') return null;
    while (relative.len != 0 and (relative[0] == '/' or relative[0] == '\\')) relative = relative[1..];
    return relative;
}

test "physical line count ignores one trailing final newline" {
    try std.testing.expectEqual(@as(usize, 0), physicalLineCount(""));
    try std.testing.expectEqual(@as(usize, 1), physicalLineCount("a"));
    try std.testing.expectEqual(@as(usize, 1), physicalLineCount("a\n"));
    try std.testing.expectEqual(@as(usize, 2), physicalLineCount("a\nb\n"));
}
