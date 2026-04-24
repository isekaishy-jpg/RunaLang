const std = @import("std");
const array_list = std.array_list;
const compiler = @import("compiler");
const build = @import("../build/root.zig");
const package = @import("../package/root.zig");
const workspace = @import("../workspace/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Managed source publication workflow.";

pub const Result = struct {
    source_root: []const u8,
    checksum: []const u8,
    copied_source_files: usize,
    published_artifacts: usize,

    pub fn deinit(self: *Result, allocator: Allocator) void {
        allocator.free(self.source_root);
        allocator.free(self.checksum);
    }
};

pub fn publishCurrentWorkspace(
    allocator: Allocator,
    io: std.Io,
    registry: []const u8,
) !Result {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return publishAtPath(allocator, io, cwd, registry, null);
}

pub fn publishAtPath(
    allocator: Allocator,
    io: std.Io,
    root_dir: []const u8,
    registry: []const u8,
    store_root_override: ?[]const u8,
) !Result {
    var loaded_workspace = try workspace.loadAtPath(allocator, io, root_dir);
    defer loaded_workspace.deinit();

    try package.validateManifestForPublication(&loaded_workspace.manifest);

    var graph = try workspace.loadGraphAtPath(allocator, io, root_dir);
    defer graph.deinit();
    var compiler_graph = try workspace.toCompilerGraph(allocator, &graph);
    defer compiler_graph.deinit();

    var active = try compiler.semantic.openGraph(allocator, io, compiler_graph.graph);
    defer active.deinit();

    const pipeline = &active.pipeline;
    if (pipeline.diagnostics.hasErrors()) return error.CheckFailed;

    var store = if (store_root_override) |store_root|
        try package.GlobalStore.initAtRoot(allocator, store_root)
    else
        try package.GlobalStore.init(allocator, io);
    defer store.deinit(allocator);

    const checksum = try computeSourceChecksum(allocator, io, loaded_workspace.manifest_path, &pipeline.sources);
    errdefer allocator.free(checksum);

    const source_root = try store.publishSourceManifest(
        allocator,
        io,
        registry,
        &loaded_workspace.manifest,
        loaded_workspace.manifest_path,
        checksum,
    );
    errdefer allocator.free(source_root);

    const copied_source_files = try copyPipelineSources(
        allocator,
        io,
        loaded_workspace.root_dir,
        &pipeline.sources,
        source_root,
    );

    const published_artifacts = try maybePublishArtifacts(
        allocator,
        io,
        root_dir,
        registry,
        &store,
        &loaded_workspace.manifest,
    );

    return .{
        .source_root = source_root,
        .checksum = checksum,
        .copied_source_files = copied_source_files,
        .published_artifacts = published_artifacts,
    };
}

fn computeSourceChecksum(
    allocator: Allocator,
    io: std.Io,
    manifest_path: []const u8,
    sources: *const compiler.source.Table,
) ![]const u8 {
    var paths = try allocator.alloc([]const u8, sources.files.items.len + 1);
    defer allocator.free(paths);

    paths[0] = manifest_path;
    for (sources.files.items, 0..) |file, index| paths[index + 1] = file.path;

    std.mem.sort([]const u8, paths, {}, lessThanString);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (paths) |path| {
        hasher.update(path);
        hasher.update("\n");

        if (std.mem.eql(u8, path, manifest_path)) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
            defer allocator.free(bytes);
            hasher.update(bytes);
        } else {
            for (sources.files.items) |file| {
                if (!std.mem.eql(u8, file.path, path)) continue;
                hasher.update(file.contents);
                break;
            }
        }
        hasher.update("\n");
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return renderHex(allocator, &digest);
}

fn copyPipelineSources(
    allocator: Allocator,
    io: std.Io,
    workspace_root: []const u8,
    sources: *const compiler.source.Table,
    source_root: []const u8,
) !usize {
    var copied: usize = 0;
    for (sources.files.items) |file| {
        const relative = try relativeToWorkspace(allocator, workspace_root, file.path);
        defer allocator.free(relative);

        const dest_path = try std.fs.path.join(allocator, &.{ source_root, "sources", relative });
        defer allocator.free(dest_path);
        try ensureParentDir(io, dest_path);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = dest_path,
            .data = file.contents,
        });
        copied += 1;
    }
    return copied;
}

fn maybePublishArtifacts(
    allocator: Allocator,
    io: std.Io,
    root_dir: []const u8,
    registry: []const u8,
    store: *const package.GlobalStore,
    manifest: *const package.Manifest,
) !usize {
    var resolved = try workspace.loadAtPath(allocator, io, root_dir);
    defer resolved.deinit();

    var has_buildable_product = false;
    for (resolved.products.items) |product| {
        if (product.kind == .bin or product.kind == .cdylib) {
            has_buildable_product = true;
            break;
        }
    }
    if (!has_buildable_product) return 0;

    var built = build.buildAtPath(allocator, io, root_dir) catch |err| switch (err) {
        error.BuildFailed => return error.BuildFailed,
        else => return err,
    };
    defer built.deinit();

    if (built.pipeline.diagnostics.hasErrors()) return error.BuildFailed;

    var published: usize = 0;
    for (built.artifacts.items) |artifact| {
        try package.validateArtifactPublication(manifest, artifact.name, artifact.kind, compiler.target.hostName());

        var identity: package.ArtifactIdentity = .{
            .registry = try allocator.dupe(u8, registry),
            .name = try allocator.dupe(u8, manifest.name.?),
            .version = try allocator.dupe(u8, manifest.version.?),
            .product = try allocator.dupe(u8, artifact.name),
            .kind = artifact.kind,
            .target = try allocator.dupe(u8, compiler.target.hostName()),
            .checksum = try computeFileChecksumHex(allocator, io, artifact.path),
        };
        defer identity.deinit(allocator);

        const published_root = try store.publishBuiltArtifact(
            allocator,
            io,
            identity,
            artifact.path,
            artifact.metadata_path,
        );
        allocator.free(published_root);
        published += 1;
    }

    return published;
}

fn relativeToWorkspace(allocator: Allocator, workspace_root: []const u8, full_path: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, full_path, workspace_root)) return error.InvalidPublication;
    var relative = full_path[workspace_root.len..];
    while (relative.len != 0 and (relative[0] == '\\' or relative[0] == '/')) {
        relative = relative[1..];
    }
    return allocator.dupe(u8, relative);
}

fn ensureParentDir(io: std.Io, full_path: []const u8) !void {
    const parent = std.fs.path.dirname(full_path) orelse return;
    try ensureDirPath(io, parent);
}

fn ensureDirPath(io: std.Io, absolute_path: []const u8) !void {
    var parts = std.mem.splitAny(u8, absolute_path, "/\\");
    var built = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer built.deinit();

    var first = true;
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (!first) try built.appendSlice("\\");
        first = false;
        try built.appendSlice(part);

        std.Io.Dir.cwd().createDir(io, built.items, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

fn renderHex(allocator: Allocator, digest: []const u8) ![]const u8 {
    const rendered = try allocator.alloc(u8, digest.len * 2);
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        rendered[index * 2] = hex[byte >> 4];
        rendered[index * 2 + 1] = hex[byte & 0x0f];
    }
    return rendered;
}

fn computeFileChecksumHex(allocator: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return renderHex(allocator, &digest);
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
