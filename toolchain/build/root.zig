const std = @import("std");
const array_list = std.array_list;
const compiler = @import("compiler");
const package = @import("../package/root.zig");
const workspace = @import("../workspace/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Build graph and orchestration.";

pub const BuildArtifact = struct {
    kind: package.ProductKind,
    name: []const u8,
    path: []const u8,
    c_path: []const u8,
    metadata_path: []const u8,

    fn deinit(self: BuildArtifact, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.c_path);
        allocator.free(self.metadata_path);
    }
};

pub const BuildResult = struct {
    allocator: Allocator,
    workspace: workspace.Loaded,
    pipeline: compiler.driver.Pipeline,
    artifacts: array_list.Managed(BuildArtifact),

    pub fn deinit(self: *BuildResult) void {
        for (self.artifacts.items) |artifact| artifact.deinit(self.allocator);
        self.artifacts.deinit();
        self.pipeline.deinit();
        self.workspace.deinit();
    }
};

pub fn buildCurrentWorkspace(allocator: Allocator, io: std.Io) !BuildResult {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return buildAtPath(allocator, io, cwd);
}

pub fn buildAtPath(allocator: Allocator, io: std.Io, root_dir: []const u8) !BuildResult {
    return buildAtPathWithOptions(allocator, io, root_dir, .{});
}

pub fn buildAtPathWithOptions(
    allocator: Allocator,
    io: std.Io,
    root_dir: []const u8,
    options: workspace.LoadOptions,
) !BuildResult {
    var loaded_workspace = try workspace.loadAtPath(allocator, io, root_dir);
    errdefer loaded_workspace.deinit();

    var graph = try workspace.loadGraphAtPathWithOptions(allocator, io, root_dir, options);
    defer graph.deinit();
    var compiler_graph = try workspace.toCompilerGraph(allocator, &graph);
    defer compiler_graph.deinit();

    var metadata_docs = array_list.Managed([]u8).init(allocator);
    defer {
        for (metadata_docs.items) |metadata_doc| allocator.free(metadata_doc);
        metadata_docs.deinit();
    }

    var pipeline = blk: {
        var active = try compiler.semantic.openGraph(allocator, io, compiler_graph.graph);
        errdefer active.deinit();
        if (!active.pipeline.diagnostics.hasErrors()) {
            for (loaded_workspace.products.items, 0..) |product, product_index| {
                var packaged_metadata = try compiler.metadata.collectPackagedMetadataFromSession(
                    allocator,
                    &active,
                    loaded_workspace.manifest.name.?,
                    loaded_workspace.manifest.version.?,
                    product.name,
                    @tagName(product.kind),
                    product_index,
                );
                defer packaged_metadata.deinit(allocator);
                try metadata_docs.append(try compiler.metadata.renderDocument(allocator, &packaged_metadata));
            }
        }
        break :blk compiler.session.intoPipeline(&active);
    };
    errdefer pipeline.deinit();

    var result = BuildResult{
        .allocator = allocator,
        .workspace = loaded_workspace,
        .pipeline = pipeline,
        .artifacts = array_list.Managed(BuildArtifact).init(allocator),
    };
    errdefer result.deinit();

    if (!compiler.target.hostStage0Supported()) {
        try result.pipeline.diagnostics.add(.@"error", "build.target.unsupported", null, "stage0 build is only implemented for Windows hosts; current host is '{s}'", .{
            compiler.target.hostName(),
        });
        return result;
    }

    if (result.pipeline.diagnostics.hasErrors()) return result;

    const c_dir = try std.fs.path.join(allocator, &.{ root_dir, ".zig-cache", "runa-stage0" });
    defer allocator.free(c_dir);
    try ensureDirPath(io, c_dir);

    const out_dir = try std.fs.path.join(allocator, &.{ root_dir, "zig-out", "stage0" });
    defer allocator.free(out_dir);
    try ensureDirPath(io, out_dir);

    var lock_artifacts = array_list.Managed(package.LockfileArtifactRecord).init(allocator);
    defer {
        for (lock_artifacts.items) |artifact| {
            if (artifact.checksum) |checksum| allocator.free(checksum);
        }
        lock_artifacts.deinit();
    }

    for (result.workspace.products.items, 0..) |product, index| {
        if (product.kind == .lib) {
            try result.pipeline.diagnostics.add(.@"error", "build.kind.unsupported", null, "stage0 build supports only 'bin' and 'cdylib'; product '{s}' is 'lib'", .{product.name});
            continue;
        }

        const c_name = try std.fmt.allocPrint(allocator, "{s}.c", .{product.name});
        defer allocator.free(c_name);
        const c_path = try std.fs.path.join(allocator, &.{ c_dir, c_name });

        const out_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{
            product.name,
            switch (product.kind) {
                .bin => compiler.target.hostExecutableExtension(),
                .cdylib => compiler.target.hostDynamicLibraryExtension(),
                .lib => unreachable,
            },
        });
        defer allocator.free(out_name);
        const out_path = try std.fs.path.join(allocator, &.{ out_dir, out_name });

        const metadata_name = try std.fmt.allocPrint(allocator, "{s}.runa.meta", .{product.name});
        defer allocator.free(metadata_name);
        const metadata_path = try std.fs.path.join(allocator, &.{ out_dir, metadata_name });
        var keep_paths = false;
        defer if (!keep_paths) {
            allocator.free(c_path);
            allocator.free(out_path);
            allocator.free(metadata_path);
        };

        var root_modules = array_list.Managed(*const compiler.mir.Module).init(allocator);
        defer root_modules.deinit();
        for (result.pipeline.modules.items) |*module_pipeline| {
            if (module_pipeline.root_index != index) continue;
            if (module_pipeline.mir) |*module| try root_modules.append(module);
        }
        if (root_modules.items.len == 0) {
            try result.pipeline.diagnostics.add(.@"error", "build.module.missing", null, "no lowered modules found for product '{s}'", .{product.name});
            continue;
        }

        var merged_module = try compiler.mir.mergeModules(allocator, root_modules.items);
        defer merged_module.deinit();

        const c_source = compiler.codegen.emitCModule(
            allocator,
            product.name,
            &merged_module,
            switch (product.kind) {
                .bin => .bin,
                .cdylib => .cdylib,
                .lib => unreachable,
            },
            &result.pipeline.diagnostics,
        ) catch {
            continue;
        };
        defer allocator.free(c_source);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = c_path,
            .data = c_source,
        });

        compiler.link.linkGeneratedC(
            allocator,
            io,
            c_path,
            out_path,
            switch (product.kind) {
                .bin => .bin,
                .cdylib => .cdylib,
                .lib => unreachable,
            },
            &result.pipeline.diagnostics,
        ) catch {
            continue;
        };

        const metadata_doc = metadata_docs.items[index];
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = metadata_path,
            .data = metadata_doc,
        });

        try result.artifacts.append(.{
            .kind = product.kind,
            .name = try allocator.dupe(u8, product.name),
            .path = out_path,
            .c_path = c_path,
            .metadata_path = metadata_path,
        });
        keep_paths = true;

        try lock_artifacts.append(.{
            .product = product.name,
            .kind = product.kind,
            .target = compiler.target.hostName(),
            .checksum = try computeFileChecksumHex(allocator, io, out_path),
        });
    }

    if (!result.pipeline.diagnostics.hasErrors()) {
        try workspace.writeLockfile(allocator, io, &result.workspace, lock_artifacts.items);
    }

    return result;
}

fn collectRootPaths(allocator: Allocator, products: []const workspace.ResolvedProduct) ![][]const u8 {
    var paths = try allocator.alloc([]const u8, products.len);
    for (products, 0..) |product, index| paths[index] = product.root_path;
    return paths;
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

fn computeFileChecksumHex(allocator: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    const rendered = try allocator.alloc(u8, digest.len * 2);
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        rendered[index * 2] = hex[byte >> 4];
        rendered[index * 2 + 1] = hex[byte & 0x0f];
    }
    return rendered;
}
