const std = @import("std");
const array_list = std.array_list;
const build_command = @import("../build/root.zig");
const cli_context = @import("../cli/context.zig");
const package = @import("../package/root.zig");
const publish = @import("../publish/root.zig");
const workspace = @import("../workspace/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Public package-command execution.";

pub const NewOptions = struct {
    name: []const u8,
    lib: bool = false,
};

pub const DependencyEditOptions = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    path: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    lang_version: ?[]const u8 = null,
};

pub const RemoveOptions = struct {
    name: []const u8,
};

pub const ImportOptions = struct {
    name: []const u8,
    version: []const u8,
    registry: ?[]const u8 = null,
};

pub const VendorOptions = struct {
    name: []const u8,
    version: []const u8,
    registry: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    lang_version: ?[]const u8 = null,
};

pub const PublishOptions = struct {
    registry: []const u8,
    artifacts: bool = false,
};

pub const NewResult = struct {
    package_dir: []const u8,
    files_written: usize,

    pub fn deinit(self: *NewResult, allocator: Allocator) void {
        allocator.free(self.package_dir);
    }
};

pub const ManifestEditResult = struct {
    manifest_path: []const u8,

    pub fn deinit(self: *ManifestEditResult, allocator: Allocator) void {
        allocator.free(self.manifest_path);
    }
};

pub const ImportResult = struct {
    store_entry_root: []const u8,
    already_present: bool = false,

    pub fn deinit(self: *ImportResult, allocator: Allocator) void {
        allocator.free(self.store_entry_root);
    }
};

pub const VendorResult = struct {
    vendor_root: []const u8,
    manifest_path: []const u8,

    pub fn deinit(self: *VendorResult, allocator: Allocator) void {
        allocator.free(self.vendor_root);
        allocator.free(self.manifest_path);
    }
};

pub const PublishResult = struct {
    source_root: []const u8,
    checksum: []const u8,
    copied_source_files: usize,
    published_artifacts: usize,

    pub fn deinit(self: *PublishResult, allocator: Allocator) void {
        allocator.free(self.source_root);
        allocator.free(self.checksum);
    }
};

const SelectedRegistry = struct {
    name: []const u8,
    root: []const u8,
};

const SourceEntryMetadata = struct {
    registry: []const u8,
    name: []const u8,
    version: []const u8,
    edition: []const u8,
    lang_version: []const u8,
    checksum: []const u8,

    fn deinit(self: *SourceEntryMetadata, allocator: Allocator) void {
        allocator.free(self.registry);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.edition);
        allocator.free(self.lang_version);
        allocator.free(self.checksum);
    }
};

pub fn runNew(
    allocator: Allocator,
    io: std.Io,
    standalone: *const cli_context.StandaloneContext,
    options: NewOptions,
) !NewResult {
    const package_dir = try workspace.createPackageAtPathWithOptions(allocator, io, standalone.cwd, options.name, .{ .lib = options.lib });
    return .{
        .package_dir = package_dir,
        .files_written = if (options.lib) 3 else 2,
    };
}

pub fn runAdd(
    allocator: Allocator,
    io: std.Io,
    manifest_rooted: *const cli_context.ManifestRootedContext,
    options: DependencyEditOptions,
) !ManifestEditResult {
    const target = manifest_rooted.target_package orelse return error.MissingTargetPackage;
    if (!package.isValidPackageName(options.name)) return error.InvalidPackageName;

    var manifest = try package.Manifest.loadAtPath(allocator, io, target.manifest_path);
    defer manifest.deinit();
    if (!manifest.has_package) return error.MissingTargetPackage;
    if (dependencyCount(&manifest, options.name) != 0) return error.DependencyAlreadyExists;

    var dependency = try buildDependencyForAdd(
        allocator,
        io,
        target.root_dir,
        options,
        if (manifest_rooted.registry_config) |*value| value else null,
        if (manifest_rooted.global_store) |*value| value else null,
        manifest_rooted.env_map,
    );
    errdefer dependency.deinit(allocator);
    try manifest.dependencies.append(dependency);

    try rewriteManifest(allocator, io, target.manifest_path, &manifest);
    return .{ .manifest_path = try allocator.dupe(u8, target.manifest_path) };
}

pub fn runRemove(
    allocator: Allocator,
    io: std.Io,
    manifest_rooted: *const cli_context.ManifestRootedContext,
    options: RemoveOptions,
) !ManifestEditResult {
    const target = manifest_rooted.target_package orelse return error.MissingTargetPackage;
    var manifest = try package.Manifest.loadAtPath(allocator, io, target.manifest_path);
    defer manifest.deinit();

    const count = dependencyCount(&manifest, options.name);
    if (count == 0) return error.DependencyNotFound;
    if (count > 1) return error.AmbiguousDependency;

    var write_index: usize = 0;
    for (manifest.dependencies.items, 0..) |dependency, read_index| {
        if (std.mem.eql(u8, dependency.name, options.name)) {
            dependency.deinit(allocator);
            continue;
        }
        if (write_index != read_index) manifest.dependencies.items[write_index] = dependency;
        write_index += 1;
    }
    manifest.dependencies.shrinkRetainingCapacity(write_index);

    try rewriteManifest(allocator, io, target.manifest_path, &manifest);
    return .{ .manifest_path = try allocator.dupe(u8, target.manifest_path) };
}

pub fn runImport(
    allocator: Allocator,
    io: std.Io,
    standalone: *const cli_context.StandaloneContext,
    options: ImportOptions,
) !ImportResult {
    if (!package.isValidPackageName(options.name)) return error.InvalidPackageName;
    if (!package.isValidPackageVersion(options.version)) return error.InvalidPackageVersion;

    const config = if (standalone.registry_config) |*value| value else return error.MissingRegistryConfigRoot;
    const store = if (standalone.global_store) |*value| value else return error.MissingGlobalStoreRoot;
    const selected = try selectRegistry(config, options.registry);

    const registry_entry_root = try sourceEntryRoot(allocator, selected.root, options.name, options.version);
    defer allocator.free(registry_entry_root);
    try verifySourceEntry(allocator, io, registry_entry_root, selected.name, options.name, options.version, null, null);

    var source_id: package.SourceIdentity = .{
        .registry = try allocator.dupe(u8, selected.name),
        .name = try allocator.dupe(u8, options.name),
        .version = try allocator.dupe(u8, options.version),
    };
    defer source_id.deinit(allocator);
    const final_root = try store.pathForSource(allocator, source_id);
    errdefer allocator.free(final_root);

    if (try pathExists(io, final_root)) {
        try verifySourceEntry(allocator, io, final_root, selected.name, options.name, options.version, null, null);
        return .{ .store_entry_root = final_root, .already_present = true };
    }

    const parent = std.fs.path.dirname(final_root) orelse return error.InvalidStorePath;
    try ensureDirPath(io, parent);
    const tmp_root = try std.fmt.allocPrint(allocator, "{s}\\tmp\\{s}-{s}-{s}", .{
        store.root,
        selected.name,
        options.name,
        options.version,
    });
    defer allocator.free(tmp_root);
    if (try pathExists(io, tmp_root)) return error.ImportTempExists;
    errdefer std.Io.Dir.cwd().deleteTree(io, tmp_root) catch {};

    try copyTree(allocator, io, registry_entry_root, tmp_root);
    try verifySourceEntry(allocator, io, tmp_root, selected.name, options.name, options.version, null, null);
    try std.Io.Dir.rename(.cwd(), tmp_root, .cwd(), final_root, io);

    return .{ .store_entry_root = final_root };
}

pub fn runVendor(
    allocator: Allocator,
    io: std.Io,
    manifest_rooted: *const cli_context.ManifestRootedContext,
    options: VendorOptions,
) !VendorResult {
    const target = manifest_rooted.target_package orelse return error.MissingTargetPackage;
    if (!package.isValidPackageName(options.name)) return error.InvalidPackageName;
    if (!package.isValidPackageVersion(options.version)) return error.InvalidPackageVersion;
    if (options.edition) |edition| if (!package.isValidEdition(edition)) return error.InvalidEdition;
    if (options.lang_version) |lang_version| if (!package.isValidLangVersion(lang_version)) return error.InvalidLangVersion;

    const config = if (manifest_rooted.registry_config) |*value| value else return error.MissingRegistryConfigRoot;
    const selected = try selectRegistry(config, options.registry);
    const registry_entry_root = try sourceEntryRoot(allocator, selected.root, options.name, options.version);
    defer allocator.free(registry_entry_root);
    try verifySourceEntry(allocator, io, registry_entry_root, selected.name, options.name, options.version, options.edition, options.lang_version);

    const vendor_root = try std.fs.path.join(allocator, &.{ manifest_rooted.command_root, "vendor", options.name });
    errdefer allocator.free(vendor_root);
    if (try pathExists(io, vendor_root)) return error.VendorAlreadyExists;
    try ensureDirPath(io, vendor_root);

    const registry_manifest = try std.fs.path.join(allocator, &.{ registry_entry_root, "runa.toml" });
    defer allocator.free(registry_manifest);
    const vendor_manifest = try std.fs.path.join(allocator, &.{ vendor_root, "runa.toml" });
    defer allocator.free(vendor_manifest);
    try copyFile(io, allocator, registry_manifest, vendor_manifest);

    const registry_sources = try std.fs.path.join(allocator, &.{ registry_entry_root, "sources" });
    defer allocator.free(registry_sources);
    _ = try copyTreeContents(allocator, io, registry_sources, vendor_root);

    var manifest = try package.Manifest.loadAtPath(allocator, io, target.manifest_path);
    defer manifest.deinit();
    const count = dependencyCount(&manifest, options.name);
    if (count > 1) return error.AmbiguousDependency;
    if (count == 1) removeDependencyUnchecked(allocator, &manifest, options.name);

    const relative_path = try relativePathForManifest(allocator, io, target.root_dir, vendor_root);
    defer allocator.free(relative_path);
    var dependency = package.Dependency{
        .name = try allocator.dupe(u8, options.name),
        .version = try allocator.dupe(u8, options.version),
        .path = try allocator.dupe(u8, relative_path),
        .edition = if (options.edition) |value| try allocator.dupe(u8, value) else null,
        .lang_version = if (options.lang_version) |value| try allocator.dupe(u8, value) else null,
    };
    errdefer dependency.deinit(allocator);
    try manifest.dependencies.append(dependency);
    try rewriteManifest(allocator, io, target.manifest_path, &manifest);

    return .{
        .vendor_root = vendor_root,
        .manifest_path = try allocator.dupe(u8, target.manifest_path),
    };
}

pub fn runPublish(
    allocator: Allocator,
    io: std.Io,
    manifest_rooted: *const cli_context.ManifestRootedContext,
    options: PublishOptions,
) !PublishResult {
    const target = manifest_rooted.target_package orelse return error.MissingTargetPackage;
    if (!package.isValidRegistryName(options.registry)) return error.InvalidRegistryName;

    const config = if (manifest_rooted.registry_config) |*value| value else return error.MissingRegistryConfigRoot;
    const registry_root = config.registryRoot(options.registry) orelse return error.UnknownRegistry;

    var loaded = try workspace.loadAtPath(allocator, io, target.root_dir);
    defer loaded.deinit();
    try publish.validateManifestForPublication(&loaded.manifest);

    var built_result: ?build_command.CommandResult = null;
    defer if (built_result) |*result| result.deinit();
    if (options.artifacts) {
        built_result = try buildReleaseForPublish(allocator, io, manifest_rooted, loaded.manifest.name.?);
    }

    const source_root = try publishSourcePackage(allocator, io, registry_root, options.registry, target.root_dir, &loaded.manifest);
    errdefer allocator.free(source_root.root);
    errdefer allocator.free(source_root.checksum);

    const artifact_count = if (built_result) |*built|
        try publishArtifactsFromBuild(allocator, io, registry_root, options.registry, &loaded.manifest, built)
    else
        0;

    return .{
        .source_root = source_root.root,
        .checksum = source_root.checksum,
        .copied_source_files = source_root.copied_files,
        .published_artifacts = artifact_count,
    };
}

fn buildDependencyForAdd(
    allocator: Allocator,
    io: std.Io,
    target_root: []const u8,
    options: DependencyEditOptions,
    registry_config_override: ?*const package.RegistryConfig,
    global_store_override: ?*const package.GlobalStore,
    env_map: ?*const std.process.Environ.Map,
) !package.Dependency {
    if (options.edition) |edition| if (!package.isValidEdition(edition)) return error.InvalidEdition;
    if (options.lang_version) |lang_version| if (!package.isValidLangVersion(lang_version)) return error.InvalidLangVersion;
    if (options.version) |version| if (!package.isValidPackageVersion(version)) return error.InvalidPackageVersion;

    if (options.path) |path| {
        if (options.registry != null) return error.ConflictingDependencySource;
        try validatePathDependency(allocator, io, target_root, options);
        return .{
            .name = try allocator.dupe(u8, options.name),
            .version = if (options.version) |value| try allocator.dupe(u8, value) else null,
            .path = try allocator.dupe(u8, path),
            .edition = if (options.edition) |value| try allocator.dupe(u8, value) else null,
            .lang_version = if (options.lang_version) |value| try allocator.dupe(u8, value) else null,
        };
    }

    const version = options.version orelse return error.MissingDependencyVersion;
    var loaded_config: package.RegistryConfig = undefined;
    const config = registry_config_override orelse blk: {
        loaded_config = if (env_map) |map|
            try package.RegistryConfig.loadWithEnvMap(allocator, io, map)
        else
            try package.RegistryConfig.load(allocator, io);
        break :blk &loaded_config;
    };
    defer if (registry_config_override == null) loaded_config.deinit();
    const selected = try selectRegistry(config, options.registry);

    var loaded_store: package.GlobalStore = undefined;
    const store = global_store_override orelse blk: {
        loaded_store = if (env_map) |map|
            try package.GlobalStore.initWithEnvMap(allocator, io, map)
        else
            try package.GlobalStore.init(allocator, io);
        break :blk &loaded_store;
    };
    defer if (global_store_override == null) loaded_store.deinit(allocator);
    var source_id: package.SourceIdentity = .{
        .registry = try allocator.dupe(u8, selected.name),
        .name = try allocator.dupe(u8, options.name),
        .version = try allocator.dupe(u8, version),
    };
    defer source_id.deinit(allocator);
    const entry_root = try store.pathForSource(allocator, source_id);
    defer allocator.free(entry_root);
    try verifySourceEntry(allocator, io, entry_root, selected.name, options.name, version, options.edition, options.lang_version);

    return .{
        .name = try allocator.dupe(u8, options.name),
        .version = try allocator.dupe(u8, version),
        .registry = try allocator.dupe(u8, selected.name),
        .edition = if (options.edition) |value| try allocator.dupe(u8, value) else null,
        .lang_version = if (options.lang_version) |value| try allocator.dupe(u8, value) else null,
    };
}

fn validatePathDependency(
    allocator: Allocator,
    io: std.Io,
    target_root: []const u8,
    options: DependencyEditOptions,
) !void {
    const path = options.path orelse return error.MissingDependencyPath;
    const dep_root = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.join(allocator, &.{ target_root, path });
    defer allocator.free(dep_root);

    const dep_manifest_path = try std.fs.path.join(allocator, &.{ dep_root, "runa.toml" });
    defer allocator.free(dep_manifest_path);
    var dep_manifest = try package.Manifest.loadAtPath(allocator, io, dep_manifest_path);
    defer dep_manifest.deinit();

    if (dep_manifest.name == null or !std.mem.eql(u8, dep_manifest.name.?, options.name)) return error.DependencyNameMismatch;
    if (options.version) |version| {
        if (dep_manifest.version == null or !std.mem.eql(u8, dep_manifest.version.?, version)) return error.DependencyVersionMismatch;
    }
    if (options.edition) |edition| {
        if (dep_manifest.edition == null or !std.mem.eql(u8, dep_manifest.edition.?, edition)) return error.DependencyEditionMismatch;
    }
    if (options.lang_version) |lang_version| {
        if (dep_manifest.lang_version == null or !std.mem.eql(u8, dep_manifest.lang_version.?, lang_version)) return error.DependencyLangVersionMismatch;
    }
}

fn dependencyCount(manifest: *const package.Manifest, name: []const u8) usize {
    var count: usize = 0;
    for (manifest.dependencies.items) |dependency| {
        if (std.mem.eql(u8, dependency.name, name)) count += 1;
    }
    return count;
}

fn removeDependencyUnchecked(allocator: Allocator, manifest: *package.Manifest, name: []const u8) void {
    var write_index: usize = 0;
    for (manifest.dependencies.items, 0..) |dependency, read_index| {
        if (std.mem.eql(u8, dependency.name, name)) {
            dependency.deinit(allocator);
            continue;
        }
        if (write_index != read_index) manifest.dependencies.items[write_index] = dependency;
        write_index += 1;
    }
    manifest.dependencies.shrinkRetainingCapacity(write_index);
}

fn rewriteManifest(allocator: Allocator, io: std.Io, path: []const u8, manifest: *const package.Manifest) !void {
    const rendered = try package.renderManifest(allocator, manifest);
    defer allocator.free(rendered);
    var verify = try package.Manifest.parse(allocator, rendered);
    defer verify.deinit();
    try workspace.atomicRewriteFile(allocator, io, path, rendered);
}

fn selectRegistry(config: *const package.RegistryConfig, explicit: ?[]const u8) !SelectedRegistry {
    if (explicit) |name| {
        if (!package.isValidRegistryName(name)) return error.InvalidRegistryName;
        return .{ .name = name, .root = config.registryRoot(name) orelse return error.UnknownRegistry };
    }
    const name = config.default_registry orelse return error.MissingDefaultRegistry;
    return .{ .name = name, .root = try config.defaultRegistryRoot() };
}

fn sourceEntryRoot(allocator: Allocator, registry_root: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ registry_root, "sources", name, version });
}

fn verifySourceEntry(
    allocator: Allocator,
    io: std.Io,
    entry_root: []const u8,
    registry: []const u8,
    name: []const u8,
    version: []const u8,
    edition: ?[]const u8,
    lang_version: ?[]const u8,
) !void {
    const entry_path = try std.fs.path.join(allocator, &.{ entry_root, "entry.toml" });
    defer allocator.free(entry_path);
    const manifest_path = try std.fs.path.join(allocator, &.{ entry_root, "runa.toml" });
    defer allocator.free(manifest_path);
    const sources_root = try std.fs.path.join(allocator, &.{ entry_root, "sources" });
    defer allocator.free(sources_root);

    try std.Io.Dir.cwd().access(io, entry_path, .{});
    try std.Io.Dir.cwd().access(io, manifest_path, .{});
    try std.Io.Dir.cwd().access(io, sources_root, .{});

    const entry_bytes = try std.Io.Dir.cwd().readFileAlloc(io, entry_path, allocator, .limited(1024 * 1024));
    defer allocator.free(entry_bytes);
    var metadata = try parseSourceEntryMetadata(allocator, entry_bytes);
    defer metadata.deinit(allocator);
    if (!std.mem.eql(u8, metadata.registry, registry)) return error.SourceEntryIdentityMismatch;
    if (!std.mem.eql(u8, metadata.name, name)) return error.SourceEntryIdentityMismatch;
    if (!std.mem.eql(u8, metadata.version, version)) return error.SourceEntryIdentityMismatch;

    var manifest = try package.Manifest.loadAtPath(allocator, io, manifest_path);
    defer manifest.deinit();
    if (manifest.name == null or !std.mem.eql(u8, manifest.name.?, name)) return error.SourceEntryIdentityMismatch;
    if (manifest.version == null or !std.mem.eql(u8, manifest.version.?, version)) return error.SourceEntryIdentityMismatch;
    if (manifest.edition == null or !std.mem.eql(u8, manifest.edition.?, metadata.edition)) return error.SourceEntryIdentityMismatch;
    if (manifest.lang_version == null or !std.mem.eql(u8, manifest.lang_version.?, metadata.lang_version)) return error.SourceEntryIdentityMismatch;
    if (edition) |value| if (!std.mem.eql(u8, manifest.edition.?, value)) return error.DependencyEditionMismatch;
    if (lang_version) |value| if (!std.mem.eql(u8, manifest.lang_version.?, value)) return error.DependencyLangVersionMismatch;

    const checksum = try computeSourcePackageChecksum(allocator, io, entry_root);
    defer allocator.free(checksum);
    if (!std.mem.eql(u8, checksum, metadata.checksum)) return error.SourceEntryChecksumMismatch;
}

fn parseSourceEntryMetadata(allocator: Allocator, contents: []const u8) !SourceEntryMetadata {
    var metadata = SourceEntryMetadata{
        .registry = try allocator.dupe(u8, ""),
        .name = try allocator.dupe(u8, ""),
        .version = try allocator.dupe(u8, ""),
        .edition = try allocator.dupe(u8, ""),
        .lang_version = try allocator.dupe(u8, ""),
        .checksum = try allocator.dupe(u8, ""),
    };
    errdefer metadata.deinit(allocator);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, trimCarriageReturn(raw_line), " \t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidSourceEntry;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = try parseQuoted(allocator, std.mem.trim(u8, line[eq_index + 1 ..], " \t"));
        errdefer allocator.free(value);
        if (std.mem.eql(u8, key, "registry")) {
            allocator.free(metadata.registry);
            metadata.registry = value;
        } else if (std.mem.eql(u8, key, "name")) {
            allocator.free(metadata.name);
            metadata.name = value;
        } else if (std.mem.eql(u8, key, "version")) {
            allocator.free(metadata.version);
            metadata.version = value;
        } else if (std.mem.eql(u8, key, "edition")) {
            allocator.free(metadata.edition);
            metadata.edition = value;
        } else if (std.mem.eql(u8, key, "lang_version")) {
            allocator.free(metadata.lang_version);
            metadata.lang_version = value;
        } else if (std.mem.eql(u8, key, "checksum")) {
            allocator.free(metadata.checksum);
            metadata.checksum = value;
        } else {
            return error.InvalidSourceEntry;
        }
    }

    if (metadata.registry.len == 0 or metadata.name.len == 0 or metadata.version.len == 0 or
        metadata.edition.len == 0 or metadata.lang_version.len == 0 or metadata.checksum.len == 0)
    {
        return error.InvalidSourceEntry;
    }
    return metadata;
}

const PublishedSource = struct {
    root: []const u8,
    checksum: []const u8,
    copied_files: usize,
};

fn publishSourcePackage(
    allocator: Allocator,
    io: std.Io,
    registry_root: []const u8,
    registry: []const u8,
    package_root: []const u8,
    manifest: *const package.Manifest,
) !PublishedSource {
    const final_root = try sourceEntryRoot(allocator, registry_root, manifest.name.?, manifest.version.?);
    errdefer allocator.free(final_root);
    if (try pathExists(io, final_root)) return error.AlreadyPublished;

    const tmp_root = try std.fmt.allocPrint(allocator, "{s}\\.tmp\\source-{s}-{s}", .{ registry_root, manifest.name.?, manifest.version.? });
    defer allocator.free(tmp_root);
    if (try pathExists(io, tmp_root)) return error.PublishTempExists;
    errdefer std.Io.Dir.cwd().deleteTree(io, tmp_root) catch {};
    try ensureDirPath(io, tmp_root);

    const manifest_source = try std.fs.path.join(allocator, &.{ package_root, "runa.toml" });
    defer allocator.free(manifest_source);
    const manifest_dest = try std.fs.path.join(allocator, &.{ tmp_root, "runa.toml" });
    defer allocator.free(manifest_dest);
    try copyFile(io, allocator, manifest_source, manifest_dest);

    const sources_dest = try std.fs.path.join(allocator, &.{ tmp_root, "sources" });
    defer allocator.free(sources_dest);
    try ensureDirPath(io, sources_dest);
    const copied_files = try copyPackageSourceFiles(allocator, io, package_root, sources_dest);

    const checksum = try computeSourcePackageChecksum(allocator, io, tmp_root);
    errdefer allocator.free(checksum);
    const entry_doc = try std.fmt.allocPrint(allocator,
        \\registry = "{s}"
        \\name = "{s}"
        \\version = "{s}"
        \\edition = "{s}"
        \\lang_version = "{s}"
        \\checksum = "{s}"
        \\
    , .{ registry, manifest.name.?, manifest.version.?, manifest.edition.?, manifest.lang_version.?, checksum });
    defer allocator.free(entry_doc);
    const entry_path = try std.fs.path.join(allocator, &.{ tmp_root, "entry.toml" });
    defer allocator.free(entry_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = entry_path, .data = entry_doc });
    try verifySourceEntry(allocator, io, tmp_root, registry, manifest.name.?, manifest.version.?, null, null);

    const parent = std.fs.path.dirname(final_root) orelse return error.InvalidRegistryRoot;
    try ensureDirPath(io, parent);
    try std.Io.Dir.rename(.cwd(), tmp_root, .cwd(), final_root, io);
    return .{ .root = final_root, .checksum = checksum, .copied_files = copied_files };
}

fn buildReleaseForPublish(
    allocator: Allocator,
    io: std.Io,
    manifest_rooted: *const cli_context.ManifestRootedContext,
    package_name: []const u8,
) !build_command.CommandResult {
    var built = try build_command.buildManifestRooted(allocator, io, manifest_rooted, .{
        .release = true,
        .package = package_name,
    });
    if (built.hasErrors()) {
        built.deinit();
        return error.BuildFailed;
    }
    return built;
}

fn publishArtifactsFromBuild(
    allocator: Allocator,
    io: std.Io,
    registry_root: []const u8,
    registry: []const u8,
    manifest: *const package.Manifest,
    built: *const build_command.CommandResult,
) !usize {
    var published_count: usize = 0;
    for (built.artifacts.items) |artifact| {
        var identity = publish.ArtifactIdentity{
            .registry = try allocator.dupe(u8, registry),
            .name = try allocator.dupe(u8, manifest.name.?),
            .version = try allocator.dupe(u8, manifest.version.?),
            .product = try allocator.dupe(u8, artifact.name),
            .kind = artifact.kind,
            .target = try allocator.dupe(u8, built.selected_target),
            .checksum = try computeFileChecksumHex(allocator, io, artifact.path),
        };
        defer identity.deinit(allocator);

        const root = try publish.publishBuiltArtifact(allocator, io, registry_root, identity, artifact.path, artifact.metadata_path);
        allocator.free(root);
        published_count += 1;
    }
    return published_count;
}

fn copyPackageSourceFiles(allocator: Allocator, io: std.Io, package_root: []const u8, dest_root: []const u8) !usize {
    var dir = try openIterableDir(io, package_root);
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var copied: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (isExcludedPackageDir(entry.path)) walker.leave(io);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".rna")) continue;

        const source_path = try std.fs.path.join(allocator, &.{ package_root, entry.path });
        defer allocator.free(source_path);
        const dest_path = try std.fs.path.join(allocator, &.{ dest_root, entry.path });
        defer allocator.free(dest_path);
        try ensureParentDir(io, dest_path);
        try copyFile(io, allocator, source_path, dest_path);
        copied += 1;
    }
    return copied;
}

fn copyTree(allocator: Allocator, io: std.Io, source_root: []const u8, dest_root: []const u8) !void {
    try ensureDirPath(io, dest_root);
    _ = try copyTreeContents(allocator, io, source_root, dest_root);
}

fn copyTreeContents(allocator: Allocator, io: std.Io, source_root: []const u8, dest_root: []const u8) !usize {
    var dir = try openIterableDir(io, source_root);
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var copied: usize = 0;
    while (try walker.next(io)) |entry| {
        const dest_path = try std.fs.path.join(allocator, &.{ dest_root, entry.path });
        defer allocator.free(dest_path);
        if (entry.kind == .directory) {
            try ensureDirPath(io, dest_path);
            continue;
        }
        if (entry.kind != .file) return error.UnsupportedPackageEntryKind;
        const source_path = try std.fs.path.join(allocator, &.{ source_root, entry.path });
        defer allocator.free(source_path);
        try ensureParentDir(io, dest_path);
        try copyFile(io, allocator, source_path, dest_path);
        copied += 1;
    }
    return copied;
}

fn computeSourcePackageChecksum(allocator: Allocator, io: std.Io, entry_root: []const u8) ![]const u8 {
    var paths = array_list.Managed([]const u8).init(allocator);
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit();
    }

    try paths.append(try allocator.dupe(u8, "runa.toml"));
    const sources_root = try std.fs.path.join(allocator, &.{ entry_root, "sources" });
    defer allocator.free(sources_root);
    var dir = try openIterableDir(io, sources_root);
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind != .file) return error.UnsupportedPackageEntryKind;
        const normalized = try normalizedRelative(allocator, entry.path);
        defer allocator.free(normalized);
        try paths.append(try std.fs.path.join(allocator, &.{ "sources", normalized }));
    }

    std.mem.sort([]const u8, paths.items, {}, lessThanString);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (paths.items) |relative| {
        const full_path = try std.fs.path.join(allocator, &.{ entry_root, relative });
        defer allocator.free(full_path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        const normalized = try normalizedRelative(allocator, relative);
        defer allocator.free(normalized);
        hasher.update(normalized);
        hasher.update("\n");
        hasher.update(bytes);
        hasher.update("\n");
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return renderHex(allocator, &digest);
}

fn relativePathForManifest(allocator: Allocator, io: std.Io, from: []const u8, to: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const raw = try std.fs.path.relative(allocator, cwd, null, from, to);
    defer allocator.free(raw);
    return normalizedRelative(allocator, raw);
}

fn normalizedRelative(allocator: Allocator, raw: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, raw);
    for (out) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return out;
}

fn isExcludedPackageDir(raw: []const u8) bool {
    const name = std.fs.path.basename(raw);
    return std.mem.eql(u8, name, "target") or
        std.mem.eql(u8, name, "dist") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, ".git");
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn openIterableDir(io: std.Io, path: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

fn ensureParentDir(io: std.Io, full_path: []const u8) !void {
    const parent = std.fs.path.dirname(full_path) orelse return;
    try ensureDirPath(io, parent);
}

fn ensureDirPath(io: std.Io, absolute_path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, absolute_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn copyFile(io: std.Io, allocator: Allocator, source_path: []const u8, dest_path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = bytes });
}

fn parseQuoted(allocator: Allocator, raw: []const u8) ![]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.InvalidSourceEntry;
    return allocator.dupe(u8, raw[1 .. raw.len - 1]);
}

fn trimCarriageReturn(raw: []const u8) []const u8 {
    if (raw.len != 0 and raw[raw.len - 1] == '\r') return raw[0 .. raw.len - 1];
    return raw;
}

fn computeFileChecksumHex(allocator: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return renderHex(allocator, &digest);
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

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}
