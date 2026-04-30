const std = @import("std");
const array_list = std.array_list;
const compiler = @import("compiler");
const cli_context = @import("../cli/context.zig");
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

pub const BuildMode = enum {
    debug,
    release,

    pub fn name(self: BuildMode) []const u8 {
        return switch (self) {
            .debug => "debug",
            .release => "release",
        };
    }
};

pub const Options = struct {
    release: bool = false,
    package: ?[]const u8 = null,
    product: ?[]const u8 = null,
    bin: ?[]const u8 = null,
    cdylib: ?[]const u8 = null,
};

pub const CommandResult = struct {
    allocator: Allocator,
    prep: workspace.CompilerPrep,
    active: compiler.session.Session,
    artifacts: array_list.Managed(BuildArtifact),
    selected_target: []const u8,
    mode: BuildMode,

    pub fn deinit(self: *CommandResult) void {
        for (self.artifacts.items) |artifact| artifact.deinit(self.allocator);
        self.artifacts.deinit();
        self.allocator.free(self.selected_target);
        self.active.deinit();
        self.prep.deinit();
    }

    pub fn hasErrors(self: *const CommandResult) bool {
        return self.active.pipeline.diagnostics.hasErrors();
    }

    pub fn errorCount(self: *const CommandResult) usize {
        return self.active.pipeline.diagnostics.errorCount();
    }

    pub fn packageCount(self: *const CommandResult) usize {
        return self.prep.graph.packages.items.len;
    }

    pub fn productCount(self: *const CommandResult) usize {
        return self.prep.graph.root_products.items.len;
    }
};

pub fn buildCommandContext(
    allocator: Allocator,
    io: std.Io,
    command_context: *const cli_context.CommandContext,
    options: Options,
) !CommandResult {
    return switch (command_context.*) {
        .manifest_rooted => |*manifest_rooted| buildManifestRooted(allocator, io, manifest_rooted, options),
        .standalone => error.MissingManifest,
    };
}

pub fn buildManifestRooted(
    allocator: Allocator,
    io: std.Io,
    manifest_rooted: *const cli_context.ManifestRootedContext,
    options: Options,
) !CommandResult {
    var prep = try manifest_rooted.prepareCompilerInputs(io, .{ .selected_build_package = options.package });
    errdefer prep.deinit();

    var active = try compiler.semantic.openGraph(allocator, io, prep.compiler_graph.graph);
    errdefer active.deinit();

    const selected_target = try resolveSelectedTarget(allocator, &prep.graph, &active.pipeline.diagnostics);
    errdefer allocator.free(selected_target);

    const mode: BuildMode = if (options.release) .release else .debug;
    var result = CommandResult{
        .allocator = allocator,
        .prep = prep,
        .active = active,
        .artifacts = array_list.Managed(BuildArtifact).init(allocator),
        .selected_target = selected_target,
        .mode = mode,
    };
    errdefer result.deinit();

    const selected_products = try selectProducts(allocator, &result.prep.graph, &result.active.pipeline.diagnostics, options);
    defer allocator.free(selected_products);

    if (result.active.pipeline.diagnostics.hasErrors()) return result;
    for (result.prep.graph.root_products.items, 0..) |product, root_index| {
        if (!selected_products[root_index]) continue;
        if (product.kind == .lib) continue;

        try emitCommandProduct(
            allocator,
            io,
            manifest_rooted.command_root,
            &result,
            product,
            root_index,
        );
        if (result.active.pipeline.diagnostics.hasErrors()) break;
    }

    return result;
}

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

    const package_name = result.workspace.manifest.name.?;

    for (result.workspace.products.items, 0..) |product, index| {
        if (product.kind == .lib) continue;

        const product_dir = try std.fs.path.join(allocator, &.{
            root_dir,
            "target",
            compiler.target.hostName(),
            "debug",
            package_name,
            product.name,
        });
        defer allocator.free(product_dir);
        try ensureDirPath(io, product_dir);

        const c_name = try std.fmt.allocPrint(allocator, "{s}.c", .{product.name});
        defer allocator.free(c_name);
        const c_path = try std.fs.path.join(allocator, &.{ product_dir, c_name });

        const out_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{
            product.name,
            switch (product.kind) {
                .bin => compiler.target.hostExecutableExtension(),
                .cdylib => compiler.target.hostDynamicLibraryExtension(),
                .lib => unreachable,
            },
        });
        defer allocator.free(out_name);
        const out_path = try std.fs.path.join(allocator, &.{ product_dir, out_name });

        const metadata_name = try std.fmt.allocPrint(allocator, "{s}.runa.meta", .{product.name});
        defer allocator.free(metadata_name);
        const metadata_path = try std.fs.path.join(allocator, &.{ product_dir, metadata_name });
        var keep_paths = false;
        defer if (!keep_paths) {
            allocator.free(c_path);
            allocator.free(out_path);
            allocator.free(metadata_path);
        };

        var root_modules = array_list.Managed(*const compiler.backend_contract.LoweredModule).init(allocator);
        defer root_modules.deinit();
        for (result.pipeline.modules.items) |*module_pipeline| {
            if (module_pipeline.root_index != index) continue;
            if (module_pipeline.backend_contract) |*lowered| try root_modules.append(lowered);
        }
        if (root_modules.items.len == 0) {
            try result.pipeline.diagnostics.add(.@"error", "build.module.missing", null, "no lowered backend modules found for product '{s}'", .{product.name});
            continue;
        }

        var lowered_module = try compiler.backend_contract.mergeLoweredModules(allocator, .{
            .module_id = .{ .index = 0 },
            .target_name = compiler.target.hostName(),
            .output_kind = switch (product.kind) {
                .bin => .bin,
                .cdylib => .cdylib,
                .lib => unreachable,
            },
        }, root_modules.items);
        defer compiler.backend_contract.deinitLoweredModule(allocator, &lowered_module);

        const c_source = compiler.codegen.emitCModule(
            allocator,
            product.name,
            &lowered_module,
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
    }

    if (!result.pipeline.diagnostics.hasErrors()) {
        try workspace.writeLockfile(allocator, io, &result.workspace);
    }

    return result;
}

fn resolveSelectedTarget(
    allocator: Allocator,
    graph: *const workspace.Graph,
    diagnostics: *compiler.diag.Bag,
) ![]const u8 {
    var selected: ?[]const u8 = null;
    var seen_packages = std.AutoHashMap(usize, void).init(allocator);
    defer seen_packages.deinit();

    for (graph.root_products.items) |product| {
        const package_index = product.package_index orelse graph.root_package_index;
        const entry = try seen_packages.getOrPut(package_index);
        if (entry.found_existing) continue;
        entry.value_ptr.* = {};

        const package_node = graph.packages.items[package_index];
        const explicit = package_node.manifest.build_target orelse continue;
        if (selected) |current| {
            if (!std.mem.eql(u8, current, explicit)) {
                try diagnostics.add(
                    .@"error",
                    "build.target.conflict",
                    null,
                    "conflicting selected targets '{s}' and '{s}' in one build invocation",
                    .{ current, explicit },
                );
            }
        } else {
            selected = explicit;
        }
    }

    const target = selected orelse compiler.target.hostName();
    if (!targetKnown(target)) {
        try diagnostics.add(.@"error", "build.target.unknown", null, "unknown target '{s}'", .{target});
    } else if (!std.mem.eql(u8, target, compiler.target.hostName()) or !compiler.target.hostStage0Supported()) {
        try diagnostics.add(
            .@"error",
            "build.target.unsupported",
            null,
            "stage0 build supports only the current Windows host target; selected target is '{s}' and host is '{s}'",
            .{ target, compiler.target.hostName() },
        );
    }
    return allocator.dupe(u8, target);
}

fn targetKnown(target: []const u8) bool {
    for (compiler.target.supported_targets) |known| {
        if (std.mem.eql(u8, known, target)) return true;
    }
    return false;
}

fn selectProducts(
    allocator: Allocator,
    graph: *const workspace.Graph,
    diagnostics: *compiler.diag.Bag,
    options: Options,
) ![]bool {
    const selected = try allocator.alloc(bool, graph.root_products.items.len);
    @memset(selected, false);

    const selector = productSelector(options);
    if (selector == null) {
        @memset(selected, true);
        return selected;
    }

    var matches: usize = 0;
    for (graph.root_products.items, 0..) |product, index| {
        if (!productMatchesSelector(product, selector.?)) continue;
        selected[index] = true;
        matches += 1;
    }

    if (matches == 0) {
        try diagnostics.add(.@"error", "build.product.missing", null, "no selected product matches '{s}'", .{selector.?.name});
    } else if (matches > 1) {
        try diagnostics.add(.@"error", "build.product.ambiguous", null, "product selector '{s}' matches multiple products", .{selector.?.name});
    }

    return selected;
}

const ProductSelector = struct {
    name: []const u8,
    kind: ?package.ProductKind = null,
};

fn productSelector(options: Options) ?ProductSelector {
    if (options.product) |name| return .{ .name = name };
    if (options.bin) |name| return .{ .name = name, .kind = .bin };
    if (options.cdylib) |name| return .{ .name = name, .kind = .cdylib };
    return null;
}

fn productMatchesSelector(product: workspace.ResolvedProduct, selector: ProductSelector) bool {
    if (selector.kind) |kind| {
        if (product.kind != kind) return false;
    }
    return std.mem.eql(u8, product.name, selector.name);
}

fn emitCommandProduct(
    allocator: Allocator,
    io: std.Io,
    command_root: []const u8,
    result: *CommandResult,
    product: workspace.ResolvedProduct,
    root_index: usize,
) !void {
    const package_index = product.package_index orelse result.prep.graph.root_package_index;
    const package_node = result.prep.graph.packages.items[package_index];
    const package_name = package_node.manifest.name orelse package_node.package_name;

    const product_dir = try std.fs.path.join(allocator, &.{
        command_root,
        "target",
        result.selected_target,
        result.mode.name(),
        package_name,
        product.name,
    });
    defer allocator.free(product_dir);
    try ensureDirPath(io, product_dir);

    const c_name = try std.fmt.allocPrint(allocator, "{s}.c", .{product.name});
    defer allocator.free(c_name);
    const c_path = try std.fs.path.join(allocator, &.{ product_dir, c_name });

    const out_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{
        product.name,
        switch (product.kind) {
            .bin => compiler.target.hostExecutableExtension(),
            .cdylib => compiler.target.hostDynamicLibraryExtension(),
            .lib => unreachable,
        },
    });
    defer allocator.free(out_name);

    const out_dir = if (result.mode == .release) blk: {
        const release_dir = try std.fs.path.join(allocator, &.{
            command_root,
            "dist",
            result.selected_target,
            package_name,
            product.name,
        });
        try ensureDirPath(io, release_dir);
        break :blk release_dir;
    } else try allocator.dupe(u8, product_dir);
    defer allocator.free(out_dir);
    const out_path = try std.fs.path.join(allocator, &.{ out_dir, out_name });

    const metadata_name = try std.fmt.allocPrint(allocator, "{s}.runa.meta", .{product.name});
    defer allocator.free(metadata_name);
    const metadata_path = try std.fs.path.join(allocator, &.{ product_dir, metadata_name });

    var keep_paths = false;
    defer if (!keep_paths) {
        allocator.free(c_path);
        allocator.free(out_path);
        allocator.free(metadata_path);
    };

    var root_modules = array_list.Managed(*const compiler.backend_contract.LoweredModule).init(allocator);
    defer root_modules.deinit();
    for (result.active.pipeline.modules.items) |*module_pipeline| {
        if (module_pipeline.root_index != root_index) continue;
        if (module_pipeline.backend_contract) |*lowered| try root_modules.append(lowered);
    }
    if (root_modules.items.len == 0) {
        try result.active.pipeline.diagnostics.add(.@"error", "build.module.missing", null, "no lowered backend modules found for product '{s}'", .{product.name});
        return;
    }

    var lowered_module = try compiler.backend_contract.mergeLoweredModules(allocator, .{
        .module_id = .{ .index = 0 },
        .target_name = result.selected_target,
        .output_kind = switch (product.kind) {
            .bin => .bin,
            .cdylib => .cdylib,
            .lib => unreachable,
        },
    }, root_modules.items);
    defer compiler.backend_contract.deinitLoweredModule(allocator, &lowered_module);

    const c_source = compiler.codegen.emitCModule(
        allocator,
        product.name,
        &lowered_module,
        switch (product.kind) {
            .bin => .bin,
            .cdylib => .cdylib,
            .lib => unreachable,
        },
        &result.active.pipeline.diagnostics,
    ) catch return;
    defer allocator.free(c_source);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = c_path, .data = c_source });

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
        &result.active.pipeline.diagnostics,
    ) catch return;

    var packaged_metadata = try compiler.metadata.collectPackagedMetadataFromSession(
        allocator,
        &result.active,
        package_node.manifest.name.?,
        package_node.manifest.version.?,
        product.name,
        @tagName(product.kind),
        root_index,
    );
    defer packaged_metadata.deinit(allocator);
    const metadata_doc = try compiler.metadata.renderDocument(allocator, &packaged_metadata);
    defer allocator.free(metadata_doc);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = metadata_doc });

    try result.artifacts.append(.{
        .kind = product.kind,
        .name = try allocator.dupe(u8, product.name),
        .path = out_path,
        .c_path = c_path,
        .metadata_path = metadata_path,
    });
    keep_paths = true;
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
