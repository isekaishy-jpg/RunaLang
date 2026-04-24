const std = @import("std");
const array_list = std.array_list;
const compiler = @import("compiler");
const package = @import("../package/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Workspace and manifest loading.";
pub const default_edition = "2026";
pub const default_lang_version = "0.00";

pub const ResolvedProduct = struct {
    kind: package.ProductKind,
    name: []const u8,
    root_path: []const u8,

    fn deinit(self: ResolvedProduct, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root_path);
    }
};

pub const Loaded = struct {
    allocator: Allocator,
    root_dir: []const u8,
    manifest_path: []const u8,
    lockfile_path: []const u8,
    manifest: package.Manifest,
    lockfile: ?package.Lockfile,
    products: array_list.Managed(ResolvedProduct),

    pub fn deinit(self: *Loaded) void {
        for (self.products.items) |product| product.deinit(self.allocator);
        self.products.deinit();
        if (self.lockfile) |*lockfile| lockfile.deinit();
        self.manifest.deinit();
        self.allocator.free(self.root_dir);
        self.allocator.free(self.manifest_path);
        self.allocator.free(self.lockfile_path);
    }
};

pub const DependencyEdge = struct {
    alias: []const u8,
    package_index: usize,

    fn deinit(self: DependencyEdge, allocator: Allocator) void {
        allocator.free(self.alias);
    }
};

pub const PackageNode = struct {
    allocator: Allocator,
    identity_key: []const u8,
    package_name: []const u8,
    root_dir: []const u8,
    source_root: []const u8,
    manifest_path: []const u8,
    import_root_path: ?[]const u8,
    manifest: package.Manifest,
    dependencies: array_list.Managed(DependencyEdge),

    fn deinit(self: *PackageNode) void {
        for (self.dependencies.items) |edge| edge.deinit(self.allocator);
        self.dependencies.deinit();
        self.manifest.deinit();
        self.allocator.free(self.identity_key);
        self.allocator.free(self.root_dir);
        self.allocator.free(self.source_root);
        self.allocator.free(self.manifest_path);
        if (self.import_root_path) |value| self.allocator.free(value);
    }
};

pub const Graph = struct {
    allocator: Allocator,
    root_package_index: usize,
    root_products: array_list.Managed(ResolvedProduct),
    packages: array_list.Managed(PackageNode),

    pub fn deinit(self: *Graph) void {
        for (self.root_products.items) |product| product.deinit(self.allocator);
        self.root_products.deinit();
        for (self.packages.items) |*package_node| package_node.deinit();
        self.packages.deinit();
    }
};

pub const CompilerGraph = struct {
    allocator: Allocator,
    graph: compiler.driver.GraphInput,
    packages: []compiler.driver.GraphPackage,
    roots: []compiler.driver.GraphRoot,
    dependencies: [][]compiler.driver.GraphDependency,

    pub fn deinit(self: *CompilerGraph) void {
        for (self.dependencies) |dependency_slice| self.allocator.free(dependency_slice);
        self.allocator.free(self.dependencies);
        self.allocator.free(self.packages);
        self.allocator.free(self.roots);
    }
};

pub const LoadOptions = struct {
    store_root_override: ?[]const u8 = null,
};

pub fn loadAtPath(allocator: Allocator, io: std.Io, root_dir: []const u8) !Loaded {
    var loaded = Loaded{
        .allocator = allocator,
        .root_dir = try allocator.dupe(u8, root_dir),
        .manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "runa.toml" }),
        .lockfile_path = try std.fs.path.join(allocator, &.{ root_dir, "runa.lock" }),
        .manifest = package.Manifest.init(allocator),
        .lockfile = null,
        .products = array_list.Managed(ResolvedProduct).init(allocator),
    };
    errdefer loaded.deinit();

    loaded.manifest.deinit();
    loaded.manifest = try package.Manifest.loadAtPath(allocator, io, loaded.manifest_path);
    try validateDependencies(io, &loaded);
    loadOptionalLockfile(io, &loaded) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try resolveProductsForLoaded(io, &loaded);

    return loaded;
}

pub fn loadGraphAtPath(allocator: Allocator, io: std.Io, root_dir: []const u8) !Graph {
    return loadGraphAtPathWithOptions(allocator, io, root_dir, .{});
}

pub fn loadGraphAtPathWithOptions(
    allocator: Allocator,
    io: std.Io,
    root_dir: []const u8,
    options: LoadOptions,
) !Graph {
    var graph = Graph{
        .allocator = allocator,
        .root_package_index = 0,
        .root_products = array_list.Managed(ResolvedProduct).init(allocator),
        .packages = array_list.Managed(PackageNode).init(allocator),
    };
    errdefer graph.deinit();

    var visited = std.StringHashMap(usize).init(allocator);
    defer visited.deinit();

    graph.root_package_index = try loadPathPackage(allocator, io, &graph, &visited, root_dir, null, options);

    var root_loaded = try loadAtPath(allocator, io, root_dir);
    defer root_loaded.deinit();
    for (root_loaded.products.items) |product| {
        try graph.root_products.append(.{
            .kind = product.kind,
            .name = try allocator.dupe(u8, product.name),
            .root_path = try allocator.dupe(u8, product.root_path),
        });
    }

    return graph;
}

pub fn toCompilerGraph(allocator: Allocator, graph: *const Graph) !CompilerGraph {
    const packages = try allocator.alloc(compiler.driver.GraphPackage, graph.packages.items.len);
    errdefer allocator.free(packages);
    const roots = try allocator.alloc(compiler.driver.GraphRoot, graph.root_products.items.len);
    errdefer allocator.free(roots);
    const dependencies = try allocator.alloc([]compiler.driver.GraphDependency, graph.packages.items.len);
    errdefer allocator.free(dependencies);

    for (graph.packages.items, 0..) |package_node, index| {
        dependencies[index] = try allocator.alloc(compiler.driver.GraphDependency, package_node.dependencies.items.len);
        for (package_node.dependencies.items, 0..) |dependency, dep_index| {
            dependencies[index][dep_index] = .{
                .alias = dependency.alias,
                .package_index = dependency.package_index,
            };
        }

        packages[index] = .{
            .package_name = package_node.package_name,
            .symbol_prefix = if (index == graph.root_package_index) "" else package_node.package_name,
            .import_root_path = package_node.import_root_path,
            .dependencies = dependencies[index],
        };
    }

    for (graph.root_products.items, 0..) |product, index| {
        roots[index] = .{
            .root_path = product.root_path,
            .package_index = graph.root_package_index,
        };
    }

    return .{
        .allocator = allocator,
        .graph = .{
            .packages = packages,
            .roots = roots,
        },
        .packages = packages,
        .roots = roots,
        .dependencies = dependencies,
    };
}

pub fn createPackageAtPath(allocator: Allocator, io: std.Io, parent_dir: []const u8, package_name: []const u8) ![]const u8 {
    if (!isValidPackageName(package_name)) return error.InvalidPackageName;

    const package_dir = try std.fs.path.join(allocator, &.{ parent_dir, package_name });
    errdefer allocator.free(package_dir);

    std.Io.Dir.cwd().createDir(io, package_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.PathAlreadyExists,
        else => return err,
    };

    const manifest_path = try std.fs.path.join(allocator, &.{ package_dir, "runa.toml" });
    defer allocator.free(manifest_path);
    const main_path = try std.fs.path.join(allocator, &.{ package_dir, "main.rna" });
    defer allocator.free(main_path);

    const manifest = try std.fmt.allocPrint(allocator,
        \\[package]
        \\name = "{s}"
        \\version = "0.1.0"
        \\edition = "{s}"
        \\lang_version = "{s}"
        \\
        \\[[products]]
        \\kind = "bin"
        \\root = "main.rna"
        \\
    , .{ package_name, default_edition, default_lang_version });
    defer allocator.free(manifest);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = manifest_path,
        .data = manifest,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = main_path,
        .data =
        \\fn main() -> I32:
        \\    return 0
        \\
        ,
    });

    return package_dir;
}

pub fn writeLockfile(
    allocator: Allocator,
    io: std.Io,
    loaded: *Loaded,
    artifacts: []const package.LockfileArtifactRecord,
) !void {
    const contents = try package.renderRootLockfile(allocator, &loaded.manifest, artifacts);
    defer allocator.free(contents);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = loaded.lockfile_path,
        .data = contents,
    });

    if (loaded.lockfile) |*lockfile| lockfile.deinit();
    loaded.lockfile = try package.Lockfile.parse(allocator, contents);
}

fn loadOptionalLockfile(io: std.Io, loaded: *Loaded) !void {
    loaded.lockfile = try package.Lockfile.loadAtPath(loaded.allocator, io, loaded.lockfile_path);
}

fn validateDependencies(io: std.Io, loaded: *Loaded) !void {
    for (loaded.manifest.dependencies.items) |dependency| {
        const rel_path = dependency.path orelse continue;
        const dep_root = try std.fs.path.join(loaded.allocator, &.{ loaded.root_dir, rel_path });
        defer loaded.allocator.free(dep_root);

        const dep_manifest_path = try std.fs.path.join(loaded.allocator, &.{ dep_root, "runa.toml" });
        defer loaded.allocator.free(dep_manifest_path);

        var dep_manifest = try package.Manifest.loadAtPath(loaded.allocator, io, dep_manifest_path);
        defer dep_manifest.deinit();

        const dep_name = dep_manifest.name orelse return error.InvalidDependency;
        if (!std.mem.eql(u8, dep_name, dependency.name)) return error.DependencyNameMismatch;

        if (dependency.version) |expected_version| {
            const dep_version = dep_manifest.version orelse return error.InvalidDependency;
            if (!std.mem.eql(u8, dep_version, expected_version)) return error.DependencyVersionMismatch;
        }
    }
}

fn resolveProductsForLoaded(io: std.Io, loaded: *Loaded) !void {
    try resolveProductsForManifest(io, loaded.allocator, &loaded.manifest, loaded.root_dir, &loaded.products);
}

fn resolveProductsForManifest(
    io: std.Io,
    allocator: Allocator,
    manifest: *const package.Manifest,
    source_root: []const u8,
    out_products: *array_list.Managed(ResolvedProduct),
) !void {
    if (manifest.products.items.len == 0) {
        try inferDefaultProductsForManifest(io, allocator, manifest, source_root, out_products);
        return;
    }

    for (manifest.products.items) |product| {
        const name = if (product.name) |value|
            try allocator.dupe(u8, value)
        else
            try allocator.dupe(u8, manifest.name.?);
        errdefer allocator.free(name);

        const root_rel = if (product.root) |value| value else product.kind.defaultRoot();
        const root_path = try std.fs.path.join(allocator, &.{ source_root, root_rel });
        errdefer allocator.free(root_path);

        try out_products.append(.{
            .kind = product.kind,
            .name = name,
            .root_path = root_path,
        });
    }
}

fn resolveImportRootPath(
    io: std.Io,
    allocator: Allocator,
    manifest: *const package.Manifest,
    source_root: []const u8,
) !?[]const u8 {
    for (manifest.products.items) |product| {
        if (product.kind != .lib) continue;
        const root_rel = if (product.root) |value| value else product.kind.defaultRoot();
        const root_path: []const u8 = try std.fs.path.join(allocator, &.{ source_root, root_rel });
        return root_path;
    }

    const fallback = try std.fs.path.join(allocator, &.{ source_root, package.ProductKind.lib.defaultRoot() });
    std.Io.Dir.cwd().access(io, fallback, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(fallback);
            return null;
        },
        else => return err,
    };
    return fallback;
}

fn inferDefaultProductsForManifest(
    io: std.Io,
    allocator: Allocator,
    manifest: *const package.Manifest,
    source_root: []const u8,
    out_products: *array_list.Managed(ResolvedProduct),
) !void {
    const defaults = [_]package.ProductKind{ .lib, .bin };
    var found_any = false;

    for (defaults) |kind| {
        const root_path = try std.fs.path.join(allocator, &.{ source_root, kind.defaultRoot() });
        defer allocator.free(root_path);

        std.Io.Dir.cwd().access(io, root_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        found_any = true;
        try out_products.append(.{
            .kind = kind,
            .name = try allocator.dupe(u8, manifest.name.?),
            .root_path = try allocator.dupe(u8, root_path),
        });
    }

    if (!found_any) return error.InvalidManifest;
}

fn loadPathPackage(
    allocator: Allocator,
    io: std.Io,
    graph: *Graph,
    visited: *std.StringHashMap(usize),
    root_dir: []const u8,
    identity_override: ?[]const u8,
    options: LoadOptions,
) anyerror!usize {
    const identity_key = if (identity_override) |value|
        try allocator.dupe(u8, value)
    else
        try allocator.dupe(u8, root_dir);
    var own_identity_key = true;
    errdefer if (own_identity_key) allocator.free(identity_key);

    const entry = try visited.getOrPut(identity_key);
    if (entry.found_existing) {
        allocator.free(identity_key);
        return entry.value_ptr.*;
    }
    entry.key_ptr.* = identity_key;

    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "runa.toml" });
    var own_manifest_path = true;
    errdefer if (own_manifest_path) allocator.free(manifest_path);
    var manifest = try package.Manifest.loadAtPath(allocator, io, manifest_path);
    var own_manifest = true;
    errdefer if (own_manifest) manifest.deinit();
    const import_root_path = try resolveImportRootPath(io, allocator, &manifest, root_dir);
    var own_import_root_path = true;
    errdefer if (own_import_root_path) if (import_root_path) |value| allocator.free(value);
    const root_dir_copy = try allocator.dupe(u8, root_dir);
    var own_root_dir_copy = true;
    errdefer if (own_root_dir_copy) allocator.free(root_dir_copy);
    const source_root_copy = try allocator.dupe(u8, root_dir);
    var own_source_root_copy = true;
    errdefer if (own_source_root_copy) allocator.free(source_root_copy);

    var node = PackageNode{
        .allocator = allocator,
        .identity_key = identity_key,
        .package_name = manifest.name.?,
        .root_dir = root_dir_copy,
        .source_root = source_root_copy,
        .manifest_path = manifest_path,
        .import_root_path = import_root_path,
        .manifest = manifest,
        .dependencies = array_list.Managed(DependencyEdge).init(allocator),
    };
    own_identity_key = false;
    own_manifest_path = false;
    own_manifest = false;
    own_import_root_path = false;
    own_root_dir_copy = false;
    own_source_root_copy = false;
    var node_owned_by_graph = false;
    errdefer if (!node_owned_by_graph) node.deinit();

    const index = graph.packages.items.len;
    try graph.packages.append(node);
    node_owned_by_graph = true;
    entry.value_ptr.* = index;

    try loadDependencyEdges(allocator, io, graph, visited, index, options);
    return index;
}

fn loadRegistryPackage(
    allocator: Allocator,
    io: std.Io,
    graph: *Graph,
    visited: *std.StringHashMap(usize),
    registry: []const u8,
    package_name: []const u8,
    version: []const u8,
    options: LoadOptions,
) anyerror!usize {
    const identity = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ registry, package_name, version });
    defer allocator.free(identity);

    var store = if (options.store_root_override) |store_root|
        try package.GlobalStore.initAtRoot(allocator, store_root)
    else
        try package.GlobalStore.init(allocator, io);
    defer store.deinit(allocator);

    var source_id: package.SourceIdentity = .{
        .registry = try allocator.dupe(u8, registry),
        .name = try allocator.dupe(u8, package_name),
        .version = try allocator.dupe(u8, version),
        .edition = null,
        .lang_version = null,
        .checksum = null,
    };
    defer source_id.deinit(allocator);

    const entry_root = try store.pathForSource(allocator, source_id);
    defer allocator.free(entry_root);
    std.Io.Dir.cwd().access(io, entry_root, .{}) catch |err| switch (err) {
        error.FileNotFound => return loadRegistryStubPackage(allocator, graph, visited, entry_root, try allocator.dupe(u8, identity), package_name, version),
        else => return err,
    };

    const source_root = try std.fs.path.join(allocator, &.{ entry_root, "sources" });
    defer allocator.free(source_root);
    return loadPublishedPackage(allocator, io, graph, visited, entry_root, source_root, try allocator.dupe(u8, identity), options);
}

fn loadRegistryStubPackage(
    allocator: Allocator,
    graph: *Graph,
    visited: *std.StringHashMap(usize),
    expected_root: []const u8,
    identity_key: []const u8,
    package_name: []const u8,
    version: []const u8,
) anyerror!usize {
    var own_identity_key = true;
    errdefer if (own_identity_key) allocator.free(identity_key);
    const entry = try visited.getOrPut(identity_key);
    if (entry.found_existing) {
        allocator.free(identity_key);
        return entry.value_ptr.*;
    }
    entry.key_ptr.* = identity_key;

    var manifest = package.Manifest.init(allocator);
    var own_manifest = true;
    errdefer if (own_manifest) manifest.deinit();
    manifest.name = try allocator.dupe(u8, package_name);
    manifest.version = try allocator.dupe(u8, version);
    manifest.edition = try allocator.dupe(u8, default_edition);
    manifest.lang_version = try allocator.dupe(u8, default_lang_version);

    const root_dir_copy = try allocator.dupe(u8, expected_root);
    var own_root_dir_copy = true;
    errdefer if (own_root_dir_copy) allocator.free(root_dir_copy);
    const source_root_copy = try allocator.dupe(u8, expected_root);
    var own_source_root_copy = true;
    errdefer if (own_source_root_copy) allocator.free(source_root_copy);
    const manifest_path = try std.fs.path.join(allocator, &.{ expected_root, "runa.toml" });
    var own_manifest_path = true;
    errdefer if (own_manifest_path) allocator.free(manifest_path);

    var node = PackageNode{
        .allocator = allocator,
        .identity_key = identity_key,
        .package_name = manifest.name.?,
        .root_dir = root_dir_copy,
        .source_root = source_root_copy,
        .manifest_path = manifest_path,
        .import_root_path = null,
        .manifest = manifest,
        .dependencies = array_list.Managed(DependencyEdge).init(allocator),
    };
    own_identity_key = false;
    own_manifest = false;
    own_root_dir_copy = false;
    own_source_root_copy = false;
    own_manifest_path = false;
    var node_owned_by_graph = false;
    errdefer if (!node_owned_by_graph) node.deinit();

    const index = graph.packages.items.len;
    try graph.packages.append(node);
    node_owned_by_graph = true;
    entry.value_ptr.* = index;
    return index;
}

fn loadPublishedPackage(
    allocator: Allocator,
    io: std.Io,
    graph: *Graph,
    visited: *std.StringHashMap(usize),
    root_dir: []const u8,
    source_root: []const u8,
    identity_key: []const u8,
    options: LoadOptions,
) anyerror!usize {
    var own_identity_key = true;
    errdefer if (own_identity_key) allocator.free(identity_key);
    const entry = try visited.getOrPut(identity_key);
    if (entry.found_existing) {
        allocator.free(identity_key);
        return entry.value_ptr.*;
    }
    entry.key_ptr.* = identity_key;

    const manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "runa.toml" });
    var own_manifest_path = true;
    errdefer if (own_manifest_path) allocator.free(manifest_path);
    var manifest = try package.Manifest.loadAtPath(allocator, io, manifest_path);
    var own_manifest = true;
    errdefer if (own_manifest) manifest.deinit();
    const import_root_path = try resolveImportRootPath(io, allocator, &manifest, source_root);
    var own_import_root_path = true;
    errdefer if (own_import_root_path) if (import_root_path) |value| allocator.free(value);
    const root_dir_copy = try allocator.dupe(u8, root_dir);
    var own_root_dir_copy = true;
    errdefer if (own_root_dir_copy) allocator.free(root_dir_copy);
    const source_root_copy = try allocator.dupe(u8, source_root);
    var own_source_root_copy = true;
    errdefer if (own_source_root_copy) allocator.free(source_root_copy);

    var node = PackageNode{
        .allocator = allocator,
        .identity_key = identity_key,
        .package_name = manifest.name.?,
        .root_dir = root_dir_copy,
        .source_root = source_root_copy,
        .manifest_path = manifest_path,
        .import_root_path = import_root_path,
        .manifest = manifest,
        .dependencies = array_list.Managed(DependencyEdge).init(allocator),
    };
    own_identity_key = false;
    own_manifest_path = false;
    own_manifest = false;
    own_import_root_path = false;
    own_root_dir_copy = false;
    own_source_root_copy = false;
    var node_owned_by_graph = false;
    errdefer if (!node_owned_by_graph) node.deinit();

    const index = graph.packages.items.len;
    try graph.packages.append(node);
    node_owned_by_graph = true;
    entry.value_ptr.* = index;

    try loadDependencyEdges(allocator, io, graph, visited, index, options);
    return index;
}

fn loadDependencyEdges(
    allocator: Allocator,
    io: std.Io,
    graph: *Graph,
    visited: *std.StringHashMap(usize),
    package_index: usize,
    options: LoadOptions,
) anyerror!void {
    const current = &graph.packages.items[package_index];
    for (current.manifest.dependencies.items) |dependency| {
        const target_index = if (dependency.path) |rel_path| blk: {
            const dep_root = try std.fs.path.join(allocator, &.{ current.source_root, rel_path });
            defer allocator.free(dep_root);
            break :blk try loadPathPackage(allocator, io, graph, visited, dep_root, null, options);
        } else blk: {
            const registry = dependency.registry orelse "default";
            const version = dependency.version orelse return error.InvalidDependency;
            break :blk try loadRegistryPackage(allocator, io, graph, visited, registry, dependency.name, version, options);
        };

        try current.dependencies.append(.{
            .alias = try allocator.dupe(u8, dependency.name),
            .package_index = target_index,
        });
    }
}

fn isValidPackageName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        const ok = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '_' or
            byte == '-';
        if (!ok) return false;
    }
    return true;
}
