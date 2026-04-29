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
    package_index: ?usize = null,

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
    include_workspace_members: bool = true,
};

pub const CompilerPrepScope = union(enum) {
    workspace,
    local_authoring,
    selected_build_package: ?[]const u8,
};

pub const CommandRootKind = enum {
    standalone_package,
    workspace_root,
    workspace_only_root,
};

pub const PackageOrigin = enum {
    workspace,
    vendored,
    external_path,
    global_store,
};

pub const DiscoveredTargetPackage = struct {
    name: []const u8,
    root_dir: []const u8,
    manifest_path: []const u8,

    fn deinit(self: DiscoveredTargetPackage, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root_dir);
        allocator.free(self.manifest_path);
    }
};

pub const CommandRootDiscovery = struct {
    allocator: Allocator,
    cwd: []const u8,
    nearest_manifest_path: []const u8,
    nearest_manifest_dir: []const u8,
    root_dir: []const u8,
    root_manifest_path: []const u8,
    lockfile_path: []const u8,
    kind: CommandRootKind,
    target_package: ?DiscoveredTargetPackage,

    pub fn deinit(self: *CommandRootDiscovery) void {
        if (self.target_package) |target| target.deinit(self.allocator);
        self.allocator.free(self.cwd);
        self.allocator.free(self.nearest_manifest_path);
        self.allocator.free(self.nearest_manifest_dir);
        self.allocator.free(self.root_dir);
        self.allocator.free(self.root_manifest_path);
        self.allocator.free(self.lockfile_path);
    }
};

pub const CompilerPrep = struct {
    allocator: Allocator,
    graph: Graph,
    compiler_graph: CompilerGraph,

    pub fn deinit(self: *CompilerPrep) void {
        self.compiler_graph.deinit();
        self.graph.deinit();
    }
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
    if (loaded.manifest.has_package) try validateDependencies(io, &loaded);
    loadOptionalLockfile(io, &loaded) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try resolveProductsForLoaded(io, &loaded);

    return loaded;
}

pub fn discoverCommandRoot(allocator: Allocator, io: std.Io, cwd: []const u8) !CommandRootDiscovery {
    const start = try std.fs.path.resolve(allocator, &.{cwd});
    defer allocator.free(start);

    const nearest_dir = (try findNearestManifestDir(allocator, io, start)) orelse return error.MissingManifest;
    errdefer allocator.free(nearest_dir);
    const nearest_manifest_path = try std.fs.path.join(allocator, &.{ nearest_dir, "runa.toml" });
    errdefer allocator.free(nearest_manifest_path);

    var nearest_manifest = try package.Manifest.loadAtPath(allocator, io, nearest_manifest_path);
    defer nearest_manifest.deinit();

    var root_dir: []const u8 = try allocator.dupe(u8, nearest_dir);
    errdefer allocator.free(root_dir);
    var kind: CommandRootKind = if (nearest_manifest.has_workspace)
        if (nearest_manifest.has_package) .workspace_root else .workspace_only_root
    else
        .standalone_package;

    if (!nearest_manifest.has_workspace) {
        if (try findEnclosingWorkspaceRoot(allocator, io, nearest_dir)) |enclosing| {
            allocator.free(root_dir);
            root_dir = enclosing.root_dir;
            kind = if (enclosing.has_package) .workspace_root else .workspace_only_root;
        }
    }

    const root_manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "runa.toml" });
    errdefer allocator.free(root_manifest_path);
    const lockfile_path = try std.fs.path.join(allocator, &.{ root_dir, "runa.lock" });
    errdefer allocator.free(lockfile_path);

    const target_package = if (nearest_manifest.has_package)
        try discoveredTargetPackage(allocator, &nearest_manifest, nearest_dir, nearest_manifest_path)
    else
        null;
    errdefer if (target_package) |target| target.deinit(allocator);

    return .{
        .allocator = allocator,
        .cwd = try allocator.dupe(u8, start),
        .nearest_manifest_path = nearest_manifest_path,
        .nearest_manifest_dir = nearest_dir,
        .root_dir = root_dir,
        .root_manifest_path = root_manifest_path,
        .lockfile_path = lockfile_path,
        .kind = kind,
        .target_package = target_package,
    };
}

pub fn prepareCompilerInputs(
    allocator: Allocator,
    io: std.Io,
    discovery: *const CommandRootDiscovery,
    scope: CompilerPrepScope,
    options: LoadOptions,
) !CompilerPrep {
    return prepareCompilerInputsForCommandRoot(allocator, io, .{
        .root_dir = discovery.root_dir,
        .kind = discovery.kind,
        .target_package_root = if (discovery.target_package) |target| target.root_dir else null,
    }, scope, options);
}

pub const CompilerPrepCommandRoot = struct {
    root_dir: []const u8,
    kind: CommandRootKind,
    target_package_root: ?[]const u8 = null,
};

pub fn prepareCompilerInputsForCommandRoot(
    allocator: Allocator,
    io: std.Io,
    command_root: CompilerPrepCommandRoot,
    scope: CompilerPrepScope,
    options: LoadOptions,
) !CompilerPrep {
    var scoped_options = options;
    const prep_root = try compilerPrepRoot(allocator, io, command_root, scope, &scoped_options);
    defer allocator.free(prep_root);

    var graph = try loadGraphAtPathWithOptions(allocator, io, prep_root, scoped_options);
    errdefer graph.deinit();
    var compiler_graph = try toCompilerGraph(allocator, &graph);
    errdefer compiler_graph.deinit();
    return .{
        .allocator = allocator,
        .graph = graph,
        .compiler_graph = compiler_graph,
    };
}

pub fn packageOrigin(command_root: []const u8, package_root: []const u8) PackageOrigin {
    return packageOriginWithStore(command_root, null, package_root);
}

pub fn packageOriginWithStore(command_root: []const u8, store_root: ?[]const u8, package_root: []const u8) PackageOrigin {
    if (store_root) |root| {
        if (relativePathText(root, package_root) != null) return .global_store;
    }
    const relative = relativePathText(command_root, package_root) orelse return .external_path;
    if (std.mem.eql(u8, relative, ".") or relative.len == 0) return .workspace;
    if (std.mem.startsWith(u8, relative, "vendor/") or std.mem.startsWith(u8, relative, "vendor\\")) return .vendored;
    return .workspace;
}

pub fn localAuthoringScope(allocator: Allocator, discovery: *const CommandRootDiscovery) ![][]const u8 {
    const root = if (discovery.target_package) |target|
        target.root_dir
    else switch (discovery.kind) {
        .standalone_package, .workspace_root => discovery.root_dir,
        .workspace_only_root => return error.MissingLocalAuthoringScope,
    };
    return singleScopeRoot(allocator, root);
}

pub fn selectedBuildPackageScope(
    allocator: Allocator,
    io: std.Io,
    discovery: *const CommandRootDiscovery,
    package_name: ?[]const u8,
) ![][]const u8 {
    if (package_name) |name| {
        const root = try findWorkspacePackageRootByName(allocator, io, discovery.root_dir, name);
        errdefer allocator.free(root);
        var roots = try allocator.alloc([]const u8, 1);
        roots[0] = root;
        return roots;
    }
    return singleScopeRoot(allocator, discovery.root_dir);
}

pub fn packageCommandTargetPackage(discovery: *const CommandRootDiscovery) ?DiscoveredTargetPackage {
    return discovery.target_package;
}

fn compilerPrepRoot(
    allocator: Allocator,
    io: std.Io,
    command_root: CompilerPrepCommandRoot,
    scope: CompilerPrepScope,
    options: *LoadOptions,
) ![]const u8 {
    return switch (scope) {
        .workspace => blk: {
            options.include_workspace_members = true;
            break :blk allocator.dupe(u8, command_root.root_dir);
        },
        .local_authoring => blk: {
            options.include_workspace_members = false;
            if (command_root.target_package_root) |root| break :blk allocator.dupe(u8, root);
            switch (command_root.kind) {
                .standalone_package, .workspace_root => break :blk allocator.dupe(u8, command_root.root_dir),
                .workspace_only_root => return error.MissingLocalAuthoringScope,
            }
        },
        .selected_build_package => |package_name| blk: {
            if (package_name) |name| {
                options.include_workspace_members = false;
                break :blk findWorkspacePackageRootByName(allocator, io, command_root.root_dir, name);
            }
            options.include_workspace_members = true;
            break :blk allocator.dupe(u8, command_root.root_dir);
        },
    };
}

fn singleScopeRoot(allocator: Allocator, root: []const u8) ![][]const u8 {
    var roots = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(roots);
    roots[0] = try allocator.dupe(u8, root);
    return roots;
}

fn findWorkspacePackageRootByName(
    allocator: Allocator,
    io: std.Io,
    command_root: []const u8,
    package_name: []const u8,
) ![]const u8 {
    const root_manifest_path = try std.fs.path.join(allocator, &.{ command_root, "runa.toml" });
    defer allocator.free(root_manifest_path);
    var root_manifest = try package.Manifest.loadAtPath(allocator, io, root_manifest_path);
    defer root_manifest.deinit();

    if (root_manifest.has_package) {
        if (std.mem.eql(u8, root_manifest.name.?, package_name)) return allocator.dupe(u8, command_root);
    }

    if (root_manifest.has_workspace) {
        for (root_manifest.workspace_members.items) |member| {
            const member_root = try std.fs.path.join(allocator, &.{ command_root, member });
            errdefer allocator.free(member_root);

            const member_manifest_path = try std.fs.path.join(allocator, &.{ member_root, "runa.toml" });
            defer allocator.free(member_manifest_path);
            var member_manifest = try package.Manifest.loadAtPath(allocator, io, member_manifest_path);
            defer member_manifest.deinit();
            if (!member_manifest.has_package) {
                allocator.free(member_root);
                continue;
            }
            if (std.mem.eql(u8, member_manifest.name.?, package_name)) return member_root;
            allocator.free(member_root);
        }
    }

    return error.UnknownWorkspacePackage;
}

pub fn atomicRewriteFile(allocator: Allocator, io: std.Io, path: []const u8, contents: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    if (std.Io.Dir.cwd().access(io, tmp_path, .{})) |_| {
        return error.AtomicRewriteTempExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_path,
        .data = contents,
    });
    const verify = try std.Io.Dir.cwd().readFileAlloc(io, tmp_path, allocator, .limited(contents.len + 1));
    defer allocator.free(verify);
    if (!std.mem.eql(u8, verify, contents)) return error.AtomicRewriteVerifyFailed;

    try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, io);
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

    const root_manifest_path = try std.fs.path.join(allocator, &.{ root_dir, "runa.toml" });
    defer allocator.free(root_manifest_path);
    var root_manifest = try package.Manifest.loadAtPath(allocator, io, root_manifest_path);
    defer root_manifest.deinit();

    var loaded_any = false;
    if (root_manifest.has_package) {
        graph.root_package_index = try loadPathPackage(allocator, io, &graph, &visited, root_dir, null, options);
        loaded_any = true;
        try appendRootProductsFromPath(allocator, io, &graph, root_dir, graph.root_package_index);
    }

    if (root_manifest.has_workspace and options.include_workspace_members) {
        for (root_manifest.workspace_members.items) |member| {
            const member_root = try std.fs.path.join(allocator, &.{ root_dir, member });
            defer allocator.free(member_root);
            if (std.mem.eql(u8, member_root, root_dir)) continue;

            const member_index = try loadPathPackage(allocator, io, &graph, &visited, member_root, null, options);
            if (!loaded_any) {
                graph.root_package_index = member_index;
                loaded_any = true;
            }
            try appendRootProductsFromPath(allocator, io, &graph, member_root, member_index);
        }
    }
    if (!loaded_any) return error.EmptyWorkspace;

    return graph;
}

fn appendRootProductsFromPath(
    allocator: Allocator,
    io: std.Io,
    graph: *Graph,
    root_dir: []const u8,
    package_index: usize,
) !void {
    var loaded = try loadAtPath(allocator, io, root_dir);
    defer loaded.deinit();
    for (loaded.products.items) |product| {
        try graph.root_products.append(.{
            .kind = product.kind,
            .name = try allocator.dupe(u8, product.name),
            .root_path = try allocator.dupe(u8, product.root_path),
            .package_index = package_index,
        });
    }
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
            .package_index = product.package_index orelse graph.root_package_index,
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
        \\version = "2026.0.01"
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
) !void {
    const contents = try package.renderRootLockfile(allocator, &loaded.manifest);
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
    if (!manifest.has_package) return;

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
        error.FileNotFound => return error.MissingManagedSource,
        else => return err,
    };

    const source_root = try std.fs.path.join(allocator, &.{ entry_root, "sources" });
    defer allocator.free(source_root);
    return loadPublishedPackage(allocator, io, graph, visited, entry_root, source_root, try allocator.dupe(u8, identity), options);
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

fn findNearestManifestDir(allocator: Allocator, io: std.Io, start_dir: []const u8) !?[]const u8 {
    var current = try allocator.dupe(u8, start_dir);
    defer allocator.free(current);

    while (true) {
        const manifest_path = try std.fs.path.join(allocator, &.{ current, "runa.toml" });
        defer allocator.free(manifest_path);
        if (std.Io.Dir.cwd().access(io, manifest_path, .{})) |_| {
            return try allocator.dupe(u8, current);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

const EnclosingWorkspace = struct {
    root_dir: []const u8,
    has_package: bool,
};

fn findEnclosingWorkspaceRoot(allocator: Allocator, io: std.Io, package_dir: []const u8) !?EnclosingWorkspace {
    var current = if (std.fs.path.dirname(package_dir)) |parent|
        try allocator.dupe(u8, parent)
    else
        return null;
    defer allocator.free(current);

    while (true) {
        const manifest_path = try std.fs.path.join(allocator, &.{ current, "runa.toml" });
        defer allocator.free(manifest_path);
        if (std.Io.Dir.cwd().access(io, manifest_path, .{})) |_| {
            var manifest = try package.Manifest.loadAtPath(allocator, io, manifest_path);
            defer manifest.deinit();
            if (manifest.has_workspace and try workspaceClaimsMember(allocator, current, &manifest, package_dir)) {
                return .{
                    .root_dir = try allocator.dupe(u8, current),
                    .has_package = manifest.has_package,
                };
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn workspaceClaimsMember(
    allocator: Allocator,
    workspace_dir: []const u8,
    manifest: *const package.Manifest,
    package_dir: []const u8,
) !bool {
    const package_resolved = try std.fs.path.resolve(allocator, &.{package_dir});
    defer allocator.free(package_resolved);
    for (manifest.workspace_members.items) |member| {
        const member_resolved = try std.fs.path.resolve(allocator, &.{ workspace_dir, member });
        defer allocator.free(member_resolved);
        if (std.mem.eql(u8, member_resolved, package_resolved)) return true;
    }
    return false;
}

fn discoveredTargetPackage(
    allocator: Allocator,
    manifest: *const package.Manifest,
    root_dir: []const u8,
    manifest_path: []const u8,
) !DiscoveredTargetPackage {
    return .{
        .name = try allocator.dupe(u8, manifest.name.?),
        .root_dir = try allocator.dupe(u8, root_dir),
        .manifest_path = try allocator.dupe(u8, manifest_path),
    };
}

fn relativePathText(root: []const u8, path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, path)) return ".";
    if (!std.mem.startsWith(u8, path, root)) return null;
    var relative = path[root.len..];
    if (relative.len != 0 and relative[0] != '/' and relative[0] != '\\') return null;
    while (relative.len != 0 and (relative[0] == '/' or relative[0] == '\\')) relative = relative[1..];
    return relative;
}

fn isValidPackageName(name: []const u8) bool {
    return package.isValidPackageName(name);
}
