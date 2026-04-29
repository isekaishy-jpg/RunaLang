const std = @import("std");
const array_list = std.array_list;
const Allocator = std.mem.Allocator;

pub const summary = "Package, lockfile, and source managed-store workflows.";

pub const ProductKind = enum {
    lib,
    bin,
    cdylib,

    pub fn parse(raw: []const u8) ?ProductKind {
        if (std.mem.eql(u8, raw, "lib")) return .lib;
        if (std.mem.eql(u8, raw, "bin")) return .bin;
        if (std.mem.eql(u8, raw, "cdylib")) return .cdylib;
        return null;
    }

    pub fn defaultRoot(self: ProductKind) []const u8 {
        return switch (self) {
            .lib, .cdylib => "lib.rna",
            .bin => "main.rna",
        };
    }
};

pub const Dependency = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    path: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    lang_version: ?[]const u8 = null,

    fn deinit(self: Dependency, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.version) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
        if (self.registry) |value| allocator.free(value);
        if (self.edition) |value| allocator.free(value);
        if (self.lang_version) |value| allocator.free(value);
    }
};

pub const Product = struct {
    kind: ProductKind,
    name: ?[]const u8 = null,
    root: ?[]const u8 = null,

    fn deinit(self: Product, allocator: Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.root) |value| allocator.free(value);
    }
};

pub const Manifest = struct {
    allocator: Allocator,
    has_package: bool = false,
    has_workspace: bool = false,
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    lang_version: ?[]const u8 = null,
    build_target: ?[]const u8 = null,
    workspace_members: array_list.Managed([]const u8),
    dependencies: array_list.Managed(Dependency),
    products: array_list.Managed(Product),

    pub fn init(allocator: Allocator) Manifest {
        return .{
            .allocator = allocator,
            .workspace_members = array_list.Managed([]const u8).init(allocator),
            .dependencies = array_list.Managed(Dependency).init(allocator),
            .products = array_list.Managed(Product).init(allocator),
        };
    }

    pub fn deinit(self: *Manifest) void {
        if (self.name) |value| self.allocator.free(value);
        if (self.version) |value| self.allocator.free(value);
        if (self.edition) |value| self.allocator.free(value);
        if (self.lang_version) |value| self.allocator.free(value);
        if (self.build_target) |value| self.allocator.free(value);

        for (self.workspace_members.items) |member| self.allocator.free(member);
        self.workspace_members.deinit();

        for (self.dependencies.items) |dependency| dependency.deinit(self.allocator);
        self.dependencies.deinit();

        for (self.products.items) |product| product.deinit(self.allocator);
        self.products.deinit();
    }

    pub fn loadAtPath(allocator: Allocator, io: std.Io, path: []const u8) !Manifest {
        const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(contents);
        return parse(allocator, contents);
    }

    pub fn parse(allocator: Allocator, contents: []const u8) !Manifest {
        var manifest = Manifest.init(allocator);
        errdefer manifest.deinit();

        const Section = enum { none, package, dependencies, product, workspace, build, native_links };
        var current_section: Section = .none;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line_no_cr = trimCarriageReturn(raw_line);
            const line = std.mem.trim(u8, line_no_cr, " \t");
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.eql(u8, line, "[package]")) {
                manifest.has_package = true;
                current_section = .package;
                continue;
            }
            if (std.mem.eql(u8, line, "[dependencies]")) {
                current_section = .dependencies;
                continue;
            }
            if (std.mem.eql(u8, line, "[workspace]")) {
                manifest.has_workspace = true;
                current_section = .workspace;
                continue;
            }
            if (std.mem.eql(u8, line, "[build]")) {
                current_section = .build;
                continue;
            }
            if (std.mem.eql(u8, line, "[[products]]")) {
                current_section = .product;
                try manifest.products.append(.{ .kind = .bin });
                continue;
            }
            if (std.mem.eql(u8, line, "[[native_links]]")) {
                current_section = .native_links;
                continue;
            }

            const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidManifest;
            const key = std.mem.trim(u8, line[0..eq_index], " \t");
            const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

            switch (current_section) {
                .package => try assignPackageField(&manifest, key, value),
                .dependencies => try assignDependencyField(&manifest, key, value),
                .product => try assignProductField(&manifest, key, value),
                .workspace => try assignWorkspaceField(&manifest, key, value),
                .build => try assignBuildField(&manifest, key, value),
                .native_links => {},
                .none => return error.InvalidManifest,
            }
        }

        try validateManifest(&manifest);
        return manifest;
    }
};

pub const SourceIdentity = struct {
    registry: []const u8,
    name: []const u8,
    version: []const u8,
    edition: ?[]const u8 = null,
    lang_version: ?[]const u8 = null,
    checksum: ?[]const u8 = null,

    pub fn deinit(self: SourceIdentity, allocator: Allocator) void {
        allocator.free(self.registry);
        allocator.free(self.name);
        allocator.free(self.version);
        if (self.edition) |value| allocator.free(value);
        if (self.lang_version) |value| allocator.free(value);
        if (self.checksum) |value| allocator.free(value);
    }
};

pub const Lockfile = struct {
    allocator: Allocator,
    sources: array_list.Managed(SourceIdentity),

    pub fn init(allocator: Allocator) Lockfile {
        return .{
            .allocator = allocator,
            .sources = array_list.Managed(SourceIdentity).init(allocator),
        };
    }

    pub fn deinit(self: *Lockfile) void {
        for (self.sources.items) |entry| entry.deinit(self.allocator);
        self.sources.deinit();
    }

    pub fn loadAtPath(allocator: Allocator, io: std.Io, path: []const u8) !Lockfile {
        const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(contents);
        return parse(allocator, contents);
    }

    pub fn parse(allocator: Allocator, contents: []const u8) !Lockfile {
        var lockfile = Lockfile.init(allocator);
        errdefer lockfile.deinit();

        const Section = enum { none, source };
        var current_section: Section = .none;

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line_no_cr = trimCarriageReturn(raw_line);
            const line = std.mem.trim(u8, line_no_cr, " \t");
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.eql(u8, line, "[[sources]]")) {
                current_section = .source;
                try lockfile.sources.append(.{
                    .registry = try allocator.dupe(u8, ""),
                    .name = try allocator.dupe(u8, ""),
                    .version = try allocator.dupe(u8, ""),
                });
                continue;
            }
            if (std.mem.eql(u8, line, "[[artifacts]]")) return error.InvalidLockfile;

            const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLockfile;
            const key = std.mem.trim(u8, line[0..eq_index], " \t");
            const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

            switch (current_section) {
                .source => try assignSourceLockField(allocator, &lockfile.sources.items[lockfile.sources.items.len - 1], key, value),
                .none => return error.InvalidLockfile,
            }
        }

        try validateLockfile(&lockfile);
        return lockfile;
    }
};

pub const RegistryEntry = struct {
    name: []const u8,
    root: []const u8,

    fn deinit(self: RegistryEntry, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root);
    }
};

pub const RegistryConfig = struct {
    allocator: Allocator,
    path: []const u8,
    default_registry: ?[]const u8 = null,
    registries: array_list.Managed(RegistryEntry),

    pub fn init(allocator: Allocator, path: []const u8) !RegistryConfig {
        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .registries = array_list.Managed(RegistryEntry).init(allocator),
        };
    }

    pub fn deinit(self: *RegistryConfig) void {
        if (self.default_registry) |value| self.allocator.free(value);
        for (self.registries.items) |entry| entry.deinit(self.allocator);
        self.registries.deinit();
        self.allocator.free(self.path);
    }

    pub fn load(allocator: Allocator, io: std.Io) !RegistryConfig {
        const env: std.process.Environ = .{ .block = .global };
        var map = try env.createMap(allocator);
        defer map.deinit();
        return loadWithEnvMap(allocator, io, &map);
    }

    pub fn loadWithEnvMap(allocator: Allocator, io: std.Io, map: *const std.process.Environ.Map) !RegistryConfig {
        const path = if (map.get("RUNA_CONFIG_PATH")) |override|
            try allocator.dupe(u8, override)
        else blk: {
            if (map.get("APPDATA")) |appdata| {
                break :blk try std.fs.path.join(allocator, &.{ appdata, "Runa", "config.toml" });
            }
            if (map.get("XDG_CONFIG_HOME")) |xdg_config| {
                break :blk try std.fs.path.join(allocator, &.{ xdg_config, "runa", "config.toml" });
            }
            if (map.get("HOME")) |home| {
                break :blk try std.fs.path.join(allocator, &.{ home, ".config", "runa", "config.toml" });
            }
            return error.MissingRegistryConfigRoot;
        };
        defer allocator.free(path);

        const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(contents);
        return parse(allocator, path, contents);
    }

    pub fn parse(allocator: Allocator, path: []const u8, contents: []const u8) !RegistryConfig {
        var config = try RegistryConfig.init(allocator, path);
        errdefer config.deinit();

        var current_registry: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw_line| {
            const line_no_cr = trimCarriageReturn(raw_line);
            const line = std.mem.trim(u8, line_no_cr, " \t");
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.startsWith(u8, line, "[registries.") and std.mem.endsWith(u8, line, "]")) {
                const name = line["[registries.".len .. line.len - 1];
                if (!isValidRegistryName(name)) return error.InvalidRegistryName;
                current_registry = name;
                continue;
            }

            const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidRegistryConfig;
            const key = std.mem.trim(u8, line[0..eq_index], " \t");
            const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");
            if (current_registry) |name| {
                if (!std.mem.eql(u8, key, "root")) return error.InvalidRegistryConfig;
                const root = try parseString(allocator, value);
                errdefer allocator.free(root);
                if (!std.fs.path.isAbsolute(root)) return error.InvalidRegistryRoot;
                try config.registries.append(.{
                    .name = try allocator.dupe(u8, name),
                    .root = root,
                });
            } else if (std.mem.eql(u8, key, "default_registry")) {
                if (config.default_registry != null) return error.InvalidRegistryConfig;
                const name = try parseString(allocator, value);
                errdefer allocator.free(name);
                if (!isValidRegistryName(name)) return error.InvalidRegistryName;
                config.default_registry = name;
            } else {
                return error.InvalidRegistryConfig;
            }
        }

        if (config.default_registry) |name| {
            _ = config.registryRoot(name) orelse return error.UnknownRegistry;
        }
        return config;
    }

    pub fn registryRoot(self: *const RegistryConfig, name: []const u8) ?[]const u8 {
        for (self.registries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.root;
        }
        return null;
    }

    pub fn defaultRegistryRoot(self: *const RegistryConfig) ![]const u8 {
        const name = self.default_registry orelse return error.MissingDefaultRegistry;
        return self.registryRoot(name) orelse error.UnknownRegistry;
    }
};

pub const GlobalStore = struct {
    root: []const u8,

    pub fn initAtRoot(allocator: Allocator, root: []const u8) !GlobalStore {
        return .{
            .root = try allocator.dupe(u8, root),
        };
    }

    pub fn init(allocator: Allocator, io: std.Io) !GlobalStore {
        const env: std.process.Environ = .{ .block = .global };
        var map = try env.createMap(allocator);
        defer map.deinit();
        return initWithEnvMap(allocator, io, &map);
    }

    pub fn initWithEnvMap(allocator: Allocator, io: std.Io, map: *const std.process.Environ.Map) !GlobalStore {
        if (map.get("RUNA_STORE_ROOT")) |value| {
            try validateStoreRoot(io, value);
            return .{ .root = try allocator.dupe(u8, value) };
        }

        const base = if (map.get("LOCALAPPDATA")) |value|
            try allocator.dupe(u8, value)
        else if (map.get("XDG_DATA_HOME")) |value|
            try allocator.dupe(u8, value)
        else if (map.get("HOME")) |value|
            try std.fs.path.join(allocator, &.{ value, ".local", "share" })
        else if (map.get("USERPROFILE")) |value|
            try allocator.dupe(u8, value)
        else
            return error.MissingGlobalStoreRoot;
        defer allocator.free(base);
        const root = try std.fs.path.join(allocator, &.{ base, "Runa", "store" });
        errdefer allocator.free(root);
        try validateStoreRoot(io, root);
        return .{ .root = root };
    }

    pub fn deinit(self: *GlobalStore, allocator: Allocator) void {
        allocator.free(self.root);
    }

    pub fn pathForSource(self: *const GlobalStore, allocator: Allocator, source_id: SourceIdentity) ![]const u8 {
        return std.fs.path.join(allocator, &.{
            self.root,
            "sources",
            source_id.registry,
            source_id.name,
            source_id.version,
        });
    }

    pub fn publishSourceManifest(
        self: *const GlobalStore,
        allocator: Allocator,
        io: std.Io,
        registry: []const u8,
        manifest: *const Manifest,
        manifest_source_path: []const u8,
        checksum: []const u8,
    ) ![]const u8 {
        const entry_root = try self.pathForSource(allocator, .{
            .registry = registry,
            .name = manifest.name.?,
            .version = manifest.version.?,
            .edition = manifest.edition.?,
            .lang_version = manifest.lang_version.?,
            .checksum = checksum,
        });
        errdefer allocator.free(entry_root);

        if (std.Io.Dir.cwd().access(io, entry_root, .{})) |_| {
            return error.AlreadyPublished;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        try ensureDirPath(io, entry_root);

        const manifest_copy_path = try std.fs.path.join(allocator, &.{ entry_root, "runa.toml" });
        defer allocator.free(manifest_copy_path);
        try copyFile(io, allocator, manifest_source_path, manifest_copy_path);

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

        const entry_path = try std.fs.path.join(allocator, &.{ entry_root, "entry.toml" });
        defer allocator.free(entry_path);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = entry_path,
            .data = entry_doc,
        });

        return entry_root;
    }
};

pub fn effectiveRegistry(dependency: Dependency) []const u8 {
    return dependency.registry orelse "default";
}

pub fn renderRootLockfile(
    allocator: Allocator,
    manifest: *const Manifest,
) ![]u8 {
    var out = array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("[[sources]]\n");
    try appendTomlField(&out, "registry", "workspace");
    try appendTomlField(&out, "name", manifest.name.?);
    try appendTomlField(&out, "version", manifest.version.?);
    try appendTomlField(&out, "edition", manifest.edition.?);
    try appendTomlField(&out, "lang_version", manifest.lang_version.?);

    for (manifest.dependencies.items) |dependency| {
        if (dependency.path != null or dependency.version == null) continue;

        try out.appendSlice("\n[[sources]]\n");
        try appendTomlField(&out, "registry", effectiveRegistry(dependency));
        try appendTomlField(&out, "name", dependency.name);
        try appendTomlField(&out, "version", dependency.version.?);
    }

    return out.toOwnedSlice();
}

fn validateManifest(manifest: *Manifest) !void {
    if (!manifest.has_package and !manifest.has_workspace) return error.InvalidManifest;

    if (manifest.has_package and (manifest.name == null or manifest.version == null or manifest.edition == null or manifest.lang_version == null)) {
        return error.InvalidManifest;
    }
    if (manifest.has_package) {
        if (!isValidPackageName(manifest.name.?)) return error.InvalidManifest;
        if (!isValidEdition(manifest.edition.?)) return error.InvalidManifest;
        if (!isValidLangVersion(manifest.lang_version.?)) return error.InvalidManifest;
    }

    for (manifest.dependencies.items) |dependency| {
        if (dependency.path != null and dependency.registry != null) return error.InvalidManifest;
        if (dependency.path == null and dependency.version == null) return error.InvalidManifest;
        if (dependency.edition) |value| if (!isValidEdition(value)) return error.InvalidManifest;
        if (dependency.lang_version) |value| if (!isValidLangVersion(value)) return error.InvalidManifest;
    }
}

fn validateLockfile(lockfile: *Lockfile) !void {
    for (lockfile.sources.items) |entry| {
        if (entry.registry.len == 0 or entry.name.len == 0 or entry.version.len == 0) return error.InvalidLockfile;
    }
}

fn assignPackageField(manifest: *Manifest, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "name")) {
        manifest.name = try parseString(manifest.allocator, value);
    } else if (std.mem.eql(u8, key, "version")) {
        manifest.version = try parseString(manifest.allocator, value);
    } else if (std.mem.eql(u8, key, "edition")) {
        manifest.edition = try parseString(manifest.allocator, value);
    } else if (std.mem.eql(u8, key, "lang_version")) {
        manifest.lang_version = try parseString(manifest.allocator, value);
    }
}

fn assignDependencyField(manifest: *Manifest, key: []const u8, value: []const u8) !void {
    var dependency = Dependency{
        .name = try manifest.allocator.dupe(u8, key),
    };
    errdefer dependency.deinit(manifest.allocator);

    if (value.len > 0 and value[0] == '"') {
        dependency.version = try parseString(manifest.allocator, value);
    } else if (value.len > 0 and value[0] == '{') {
        try parseDependencyInlineTable(manifest.allocator, &dependency, value);
    } else {
        return error.InvalidManifest;
    }

    try manifest.dependencies.append(dependency);
}

fn assignProductField(manifest: *Manifest, key: []const u8, value: []const u8) !void {
    if (manifest.products.items.len == 0) return error.InvalidManifest;

    var product = &manifest.products.items[manifest.products.items.len - 1];
    if (std.mem.eql(u8, key, "kind")) {
        const raw = try parseString(manifest.allocator, value);
        defer manifest.allocator.free(raw);
        product.kind = ProductKind.parse(raw) orelse return error.InvalidManifest;
    } else if (std.mem.eql(u8, key, "name")) {
        product.name = try parseString(manifest.allocator, value);
    } else if (std.mem.eql(u8, key, "root")) {
        product.root = try parseString(manifest.allocator, value);
    }
}

fn assignWorkspaceField(manifest: *Manifest, key: []const u8, value: []const u8) !void {
    if (!std.mem.eql(u8, key, "members")) return error.InvalidManifest;
    const members = try parseStringArray(manifest.allocator, value);
    var transferred = false;
    errdefer if (!transferred) {
        for (members) |member| manifest.allocator.free(member);
        manifest.allocator.free(members);
    };
    for (members) |member| {
        if (std.fs.path.isAbsolute(member)) return error.InvalidManifest;
        if (std.mem.indexOf(u8, member, "..") != null) return error.InvalidManifest;
    }
    try manifest.workspace_members.ensureUnusedCapacity(members.len);
    for (members) |member| {
        manifest.workspace_members.appendAssumeCapacity(member);
    }
    transferred = true;
    manifest.allocator.free(members);
}

fn assignBuildField(manifest: *Manifest, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "target")) {
        if (manifest.build_target != null) return error.InvalidManifest;
        manifest.build_target = try parseString(manifest.allocator, value);
    }
}

fn parseDependencyInlineTable(allocator: Allocator, dependency: *Dependency, value: []const u8) !void {
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return error.InvalidManifest;

    var entries = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
    while (entries.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t");
        if (entry.len == 0) continue;

        const eq_index = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidManifest;
        const key = std.mem.trim(u8, entry[0..eq_index], " \t");
        const field_value = std.mem.trim(u8, entry[eq_index + 1 ..], " \t");

        if (std.mem.eql(u8, key, "version")) {
            dependency.version = try parseString(allocator, field_value);
        } else if (std.mem.eql(u8, key, "path")) {
            dependency.path = try parseString(allocator, field_value);
        } else if (std.mem.eql(u8, key, "registry")) {
            dependency.registry = try parseString(allocator, field_value);
        } else if (std.mem.eql(u8, key, "edition")) {
            dependency.edition = try parseString(allocator, field_value);
        } else if (std.mem.eql(u8, key, "lang_version")) {
            dependency.lang_version = try parseString(allocator, field_value);
        } else {
            return error.InvalidManifest;
        }
    }
}

fn assignSourceLockField(allocator: Allocator, entry: *SourceIdentity, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "registry")) {
        allocator.free(entry.registry);
        entry.registry = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "name")) {
        allocator.free(entry.name);
        entry.name = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "version")) {
        allocator.free(entry.version);
        entry.version = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "edition")) {
        if (entry.edition) |old| allocator.free(old);
        entry.edition = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "lang_version")) {
        if (entry.lang_version) |old| allocator.free(old);
        entry.lang_version = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "checksum")) {
        if (entry.checksum) |old| allocator.free(old);
        entry.checksum = try parseString(allocator, value);
    } else {
        return error.InvalidLockfile;
    }
}

fn parseString(allocator: Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return error.InvalidManifest;
    return allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
}

fn parseStringArray(allocator: Allocator, raw: []const u8) ![][]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.InvalidManifest;

    var out = array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (out.items) |value| allocator.free(value);
        out.deinit();
    }

    var parts = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) continue;
        try out.append(try parseString(allocator, part));
    }
    return out.toOwnedSlice();
}

fn appendTomlField(out: *array_list.Managed(u8), key: []const u8, value: []const u8) !void {
    try out.appendSlice(key);
    try out.appendSlice(" = \"");
    try out.appendSlice(value);
    try out.appendSlice("\"\n");
}

fn copyFile(io: std.Io, allocator: Allocator, source_path: []const u8, dest_path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dest_path,
        .data = bytes,
    });
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

fn validateStoreRoot(io: std.Io, root: []const u8) !void {
    std.Io.Dir.cwd().access(io, root, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.MissingGlobalStoreRoot,
        else => return error.UnusableGlobalStoreRoot,
    };
}

fn isValidEdition(raw: []const u8) bool {
    if (raw.len != 4) return false;
    for (raw) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

fn isValidLangVersion(raw: []const u8) bool {
    if (raw.len != 4) return false;
    return raw[0] >= '0' and raw[0] <= '9' and
        raw[1] == '.' and
        raw[2] >= '0' and raw[2] <= '9' and
        raw[3] >= '0' and raw[3] <= '9';
}

pub fn isValidPackageName(raw: []const u8) bool {
    if (raw.len == 0) return false;
    if (raw[0] < 'a' or raw[0] > 'z') return false;
    for (raw) |byte| {
        const ok = (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '_' or byte == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn isValidRegistryName(raw: []const u8) bool {
    return isValidPackageName(raw);
}

fn trimCarriageReturn(raw: []const u8) []const u8 {
    if (raw.len != 0 and raw[raw.len - 1] == '\r') return raw[0 .. raw.len - 1];
    return raw;
}
