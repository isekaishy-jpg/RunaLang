const std = @import("std");
const package = @import("../package/root.zig");
const workspace = @import("../workspace/root.zig");

pub const StandaloneContext = struct {
    allocator: std.mem.Allocator,
    cwd: [:0]u8,
    global_store: ?package.GlobalStore = null,
    registry_config: ?package.RegistryConfig = null,
    env_map: ?*const std.process.Environ.Map = null,

    pub fn deinit(self: *StandaloneContext) void {
        if (self.global_store) |*store| store.deinit(self.allocator);
        if (self.registry_config) |*config| config.deinit();
        self.allocator.free(self.cwd);
    }
};

pub const TargetPackage = struct {
    name: []const u8,
    root_dir: []const u8,
    manifest_path: []const u8,

    pub fn deinit(self: TargetPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root_dir);
        allocator.free(self.manifest_path);
    }
};

pub const CommandContext = union(enum) {
    standalone: StandaloneContext,
    manifest_rooted: ManifestRootedContext,

    pub fn deinit(self: *CommandContext) void {
        switch (self.*) {
            .standalone => |*standalone| standalone.deinit(),
            .manifest_rooted => |*manifest_rooted| manifest_rooted.deinit(),
        }
    }

    pub fn prepareCompilerInputs(
        self: *const CommandContext,
        io: std.Io,
        scope: workspace.CompilerPrepScope,
    ) !workspace.CompilerPrep {
        return switch (self.*) {
            .manifest_rooted => |*manifest_rooted| manifest_rooted.prepareCompilerInputs(io, scope),
            .standalone => error.MissingManifest,
        };
    }
};

pub const ManifestRootedContext = struct {
    allocator: std.mem.Allocator,
    cwd: [:0]u8,
    invoked_manifest_candidate: []const u8,
    command_root: []const u8,
    command_root_kind: workspace.CommandRootKind,
    target_package: ?TargetPackage,
    lockfile_path: []const u8,
    global_store: ?package.GlobalStore = null,
    registry_config: ?package.RegistryConfig = null,
    env_map: ?*const std.process.Environ.Map = null,

    pub fn deinit(self: *ManifestRootedContext) void {
        if (self.registry_config) |*config| config.deinit();
        if (self.global_store) |*store| store.deinit(self.allocator);
        if (self.target_package) |target| target.deinit(self.allocator);
        self.allocator.free(self.cwd);
        self.allocator.free(self.invoked_manifest_candidate);
        self.allocator.free(self.command_root);
        self.allocator.free(self.lockfile_path);
    }

    pub fn prepareCompilerInputs(
        self: *const ManifestRootedContext,
        io: std.Io,
        scope: workspace.CompilerPrepScope,
    ) !workspace.CompilerPrep {
        return workspace.prepareCompilerInputsForCommandRoot(self.allocator, io, .{
            .root_dir = self.command_root,
            .kind = self.command_root_kind,
            .target_package_root = if (self.target_package) |target| target.root_dir else null,
        }, scope, .{ .store_root_override = self.storeRootOverride() });
    }

    pub fn storeRootOverride(self: *const ManifestRootedContext) ?[]const u8 {
        if (self.global_store) |store| return store.root;
        if (self.env_map) |map| return map.get("RUNA_STORE_ROOT");
        return null;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: anytype,
) !CommandContext {
    return buildWithEnvMap(allocator, io, command, null);
}

pub fn buildWithEnvMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: anytype,
    env_map: ?*const std.process.Environ.Map,
) !CommandContext {
    return switch (command.contextKind()) {
        .standalone => .{ .standalone = try buildStandalone(allocator, io, command, env_map) },
        .manifest_rooted => .{ .manifest_rooted = try buildManifestRooted(allocator, io, command, env_map) },
    };
}

pub fn buildStandalone(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: anytype,
    env_map: ?*const std.process.Environ.Map,
) !StandaloneContext {
    var result = StandaloneContext{
        .allocator = allocator,
        .cwd = try std.process.currentPathAlloc(io, allocator),
        .env_map = env_map,
    };
    errdefer result.deinit();

    if (command.needsGlobalStore()) {
        result.global_store = if (env_map) |map|
            try package.GlobalStore.initWithEnvMap(allocator, io, map)
        else
            try package.GlobalStore.init(allocator, io);
    }
    if (command.needsRegistryConfig()) {
        result.registry_config = if (env_map) |map|
            try package.RegistryConfig.loadWithEnvMap(allocator, io, map)
        else
            try package.RegistryConfig.load(allocator, io);
    }
    return result;
}

pub fn buildManifestRooted(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: anytype,
    env_map: ?*const std.process.Environ.Map,
) !ManifestRootedContext {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    errdefer allocator.free(cwd);

    var discovered = try workspace.discoverCommandRoot(allocator, io, cwd);
    defer discovered.deinit();

    const target_package = if (command.needsTargetPackage())
        try targetPackageFromDiscovery(allocator, &discovered)
    else
        null;
    errdefer if (target_package) |target| target.deinit(allocator);

    var store: ?package.GlobalStore = null;
    if (command.needsGlobalStore()) {
        store = if (env_map) |map|
            try package.GlobalStore.initWithEnvMap(allocator, io, map)
        else
            try package.GlobalStore.init(allocator, io);
    }
    errdefer if (store) |*global_store| global_store.deinit(allocator);

    var registry_config: ?package.RegistryConfig = null;
    if (command.needsRegistryConfig()) {
        registry_config = if (env_map) |map|
            try package.RegistryConfig.loadWithEnvMap(allocator, io, map)
        else
            try package.RegistryConfig.load(allocator, io);
    }
    errdefer if (registry_config) |*config| config.deinit();

    return .{
        .allocator = allocator,
        .cwd = cwd,
        .invoked_manifest_candidate = try allocator.dupe(u8, discovered.nearest_manifest_path),
        .command_root = try allocator.dupe(u8, discovered.root_dir),
        .command_root_kind = discovered.kind,
        .target_package = target_package,
        .lockfile_path = try allocator.dupe(u8, discovered.lockfile_path),
        .global_store = store,
        .registry_config = registry_config,
        .env_map = env_map,
    };
}

fn targetPackageFromDiscovery(
    allocator: std.mem.Allocator,
    discovered: *const workspace.CommandRootDiscovery,
) !?TargetPackage {
    const target = discovered.target_package orelse return error.MissingTargetPackage;
    return .{
        .name = try allocator.dupe(u8, target.name),
        .root_dir = try allocator.dupe(u8, target.root_dir),
        .manifest_path = try allocator.dupe(u8, target.manifest_path),
    };
}
