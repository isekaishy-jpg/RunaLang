const std = @import("std");
const array_list = std.array_list;
const Allocator = std.mem.Allocator;

pub const summary = "Package, lockfile, publication, and managed-store workflows.";

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

    fn deinit(self: Dependency, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.version) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
        if (self.registry) |value| allocator.free(value);
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
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    lang_version: ?[]const u8 = null,
    dependencies: array_list.Managed(Dependency),
    products: array_list.Managed(Product),

    pub fn init(allocator: Allocator) Manifest {
        return .{
            .allocator = allocator,
            .dependencies = array_list.Managed(Dependency).init(allocator),
            .products = array_list.Managed(Product).init(allocator),
        };
    }

    pub fn deinit(self: *Manifest) void {
        if (self.name) |value| self.allocator.free(value);
        if (self.version) |value| self.allocator.free(value);
        if (self.edition) |value| self.allocator.free(value);
        if (self.lang_version) |value| self.allocator.free(value);

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
                current_section = .package;
                continue;
            }
            if (std.mem.eql(u8, line, "[dependencies]")) {
                current_section = .dependencies;
                continue;
            }
            if (std.mem.eql(u8, line, "[workspace]")) {
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
                .workspace, .build, .native_links, .none => {},
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

pub const ArtifactIdentity = struct {
    registry: []const u8,
    name: []const u8,
    version: []const u8,
    product: []const u8,
    kind: ProductKind,
    target: []const u8,
    checksum: ?[]const u8 = null,

    pub fn deinit(self: ArtifactIdentity, allocator: Allocator) void {
        allocator.free(self.registry);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.product);
        allocator.free(self.target);
        if (self.checksum) |value| allocator.free(value);
    }
};

pub const ManagedEntryKind = enum {
    source,
    artifact,
};

pub const ManagedEntry = union(ManagedEntryKind) {
    source: SourceIdentity,
    artifact: ArtifactIdentity,

    fn deinit(self: *ManagedEntry, allocator: Allocator) void {
        switch (self.*) {
            .source => |value| value.deinit(allocator),
            .artifact => |value| value.deinit(allocator),
        }
    }
};

pub const Lockfile = struct {
    allocator: Allocator,
    sources: array_list.Managed(SourceIdentity),
    artifacts: array_list.Managed(ArtifactIdentity),

    pub fn init(allocator: Allocator) Lockfile {
        return .{
            .allocator = allocator,
            .sources = array_list.Managed(SourceIdentity).init(allocator),
            .artifacts = array_list.Managed(ArtifactIdentity).init(allocator),
        };
    }

    pub fn deinit(self: *Lockfile) void {
        for (self.sources.items) |entry| entry.deinit(self.allocator);
        self.sources.deinit();
        for (self.artifacts.items) |entry| entry.deinit(self.allocator);
        self.artifacts.deinit();
    }

    pub fn loadAtPath(allocator: Allocator, io: std.Io, path: []const u8) !Lockfile {
        const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(contents);
        return parse(allocator, contents);
    }

    pub fn parse(allocator: Allocator, contents: []const u8) !Lockfile {
        var lockfile = Lockfile.init(allocator);
        errdefer lockfile.deinit();

        const Section = enum { none, source, artifact };
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
            if (std.mem.eql(u8, line, "[[artifacts]]")) {
                current_section = .artifact;
                try lockfile.artifacts.append(.{
                    .registry = try allocator.dupe(u8, ""),
                    .name = try allocator.dupe(u8, ""),
                    .version = try allocator.dupe(u8, ""),
                    .product = try allocator.dupe(u8, ""),
                    .kind = .bin,
                    .target = try allocator.dupe(u8, ""),
                });
                continue;
            }

            const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidLockfile;
            const key = std.mem.trim(u8, line[0..eq_index], " \t");
            const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

            switch (current_section) {
                .source => try assignSourceLockField(allocator, &lockfile.sources.items[lockfile.sources.items.len - 1], key, value),
                .artifact => try assignArtifactLockField(allocator, &lockfile.artifacts.items[lockfile.artifacts.items.len - 1], key, value),
                .none => return error.InvalidLockfile,
            }
        }

        try validateLockfile(&lockfile);
        return lockfile;
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
            return .{
                .root = try allocator.dupe(u8, value),
            };
        }

        const base = if (map.get("LOCALAPPDATA")) |value|
            try allocator.dupe(u8, value)
        else if (map.get("USERPROFILE")) |value|
            try allocator.dupe(u8, value)
        else if (map.get("HOME")) |value|
            try allocator.dupe(u8, value)
        else
            try std.process.currentPathAlloc(io, allocator);
        errdefer allocator.free(base);
        const root = try std.fs.path.join(allocator, &.{ base, "runa", "store" });
        allocator.free(base);
        return .{ .root = root };
    }

    pub fn deinit(self: *GlobalStore, allocator: Allocator) void {
        allocator.free(self.root);
    }

    pub fn pathForSource(self: *const GlobalStore, allocator: Allocator, source_id: SourceIdentity) ![]const u8 {
        return std.fs.path.join(allocator, &.{
            self.root,
            "source",
            source_id.registry,
            source_id.name,
            source_id.version,
        });
    }

    pub fn pathForArtifact(self: *const GlobalStore, allocator: Allocator, artifact_id: ArtifactIdentity) ![]const u8 {
        return std.fs.path.join(allocator, &.{
            self.root,
            "artifact",
            artifact_id.registry,
            artifact_id.name,
            artifact_id.version,
            artifact_id.product,
            @tagName(artifact_id.kind),
            artifact_id.target,
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

    pub fn publishBuiltArtifact(
        self: *const GlobalStore,
        allocator: Allocator,
        io: std.Io,
        artifact_id: ArtifactIdentity,
        artifact_source_path: []const u8,
        metadata_source_path: []const u8,
    ) ![]const u8 {
        const entry_root = try self.pathForArtifact(allocator, artifact_id);
        errdefer allocator.free(entry_root);

        if (std.Io.Dir.cwd().access(io, entry_root, .{})) |_| {
            return error.AlreadyPublished;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        try ensureDirPath(io, entry_root);

        const artifact_dest_path = try std.fs.path.join(allocator, &.{ entry_root, std.fs.path.basename(artifact_source_path) });
        defer allocator.free(artifact_dest_path);
        try copyFile(io, allocator, artifact_source_path, artifact_dest_path);

        const metadata_dest_path = try std.fs.path.join(allocator, &.{ entry_root, std.fs.path.basename(metadata_source_path) });
        defer allocator.free(metadata_dest_path);
        try copyFile(io, allocator, metadata_source_path, metadata_dest_path);

        var entry = array_list.Managed(u8).init(allocator);
        defer entry.deinit();
        try appendTomlField(&entry, "registry", artifact_id.registry);
        try appendTomlField(&entry, "name", artifact_id.name);
        try appendTomlField(&entry, "version", artifact_id.version);
        try appendTomlField(&entry, "product", artifact_id.product);
        try appendTomlField(&entry, "kind", @tagName(artifact_id.kind));
        try appendTomlField(&entry, "target", artifact_id.target);
        if (artifact_id.checksum) |checksum| try appendTomlField(&entry, "checksum", checksum);

        const entry_path = try std.fs.path.join(allocator, &.{ entry_root, "entry.toml" });
        defer allocator.free(entry_path);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = entry_path,
            .data = entry.items,
        });

        return entry_root;
    }
};

pub const PublicationKind = enum {
    source,
    artifact,
};

pub const LockfileArtifactRecord = struct {
    product: []const u8,
    kind: ProductKind,
    target: []const u8,
    checksum: ?[]const u8 = null,
};

pub const SourcePublication = struct {
    registry: []const u8,
    checksum: []const u8,
};

pub const ArtifactPublication = struct {
    registry: []const u8,
    product: []const u8,
    kind: ProductKind,
    target: []const u8,
    checksum: []const u8,
};

pub fn validateManifestForPublication(manifest: *const Manifest) !void {
    if (manifest.name == null or manifest.version == null or manifest.edition == null or manifest.lang_version == null) {
        return error.InvalidPublication;
    }
    for (manifest.dependencies.items) |dependency| {
        if (dependency.path != null) return error.InvalidPublication;
    }
}

pub fn validateArtifactPublication(manifest: *const Manifest, product_name: []const u8, kind: ProductKind, target: []const u8) !void {
    try validateManifestForPublication(manifest);
    _ = target;

    var matched = false;
    for (manifest.products.items) |product| {
        const resolved_name = product.name orelse manifest.name.?;
        if (!std.mem.eql(u8, resolved_name, product_name)) continue;
        if (product.kind != kind) return error.InvalidPublication;
        matched = true;
        break;
    }
    if (!matched and !(manifest.products.items.len == 0 and kind == .bin and std.mem.eql(u8, manifest.name.?, product_name))) {
        return error.InvalidPublication;
    }
}

pub fn effectiveRegistry(dependency: Dependency) []const u8 {
    return dependency.registry orelse "default";
}

pub fn renderRootLockfile(
    allocator: Allocator,
    manifest: *const Manifest,
    artifacts: []const LockfileArtifactRecord,
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

    for (artifacts) |artifact| {
        try out.appendSlice("\n[[artifacts]]\n");
        try appendTomlField(&out, "registry", "workspace");
        try appendTomlField(&out, "name", manifest.name.?);
        try appendTomlField(&out, "version", manifest.version.?);
        try appendTomlField(&out, "product", artifact.product);
        try appendTomlField(&out, "kind", @tagName(artifact.kind));
        try appendTomlField(&out, "target", artifact.target);
        if (artifact.checksum) |checksum| try appendTomlField(&out, "checksum", checksum);
    }

    return out.toOwnedSlice();
}

fn validateManifest(manifest: *Manifest) !void {
    if (manifest.name == null or manifest.version == null or manifest.edition == null or manifest.lang_version == null) {
        return error.InvalidManifest;
    }
    if (!isValidEdition(manifest.edition.?)) return error.InvalidManifest;
    if (!isValidLangVersion(manifest.lang_version.?)) return error.InvalidManifest;

    for (manifest.dependencies.items) |dependency| {
        if (dependency.path != null and dependency.registry != null) return error.InvalidManifest;
        if (dependency.path == null and dependency.version == null) return error.InvalidManifest;
    }
}

fn validateLockfile(lockfile: *Lockfile) !void {
    for (lockfile.sources.items) |entry| {
        if (entry.registry.len == 0 or entry.name.len == 0 or entry.version.len == 0) return error.InvalidLockfile;
    }
    for (lockfile.artifacts.items) |entry| {
        if (entry.registry.len == 0 or entry.name.len == 0 or entry.version.len == 0 or entry.product.len == 0 or entry.target.len == 0) {
            return error.InvalidLockfile;
        }
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

fn assignArtifactLockField(allocator: Allocator, entry: *ArtifactIdentity, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "registry")) {
        allocator.free(entry.registry);
        entry.registry = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "name")) {
        allocator.free(entry.name);
        entry.name = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "version")) {
        allocator.free(entry.version);
        entry.version = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "product")) {
        allocator.free(entry.product);
        entry.product = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "kind")) {
        const raw = try parseString(allocator, value);
        defer allocator.free(raw);
        entry.kind = ProductKind.parse(raw) orelse return error.InvalidLockfile;
    } else if (std.mem.eql(u8, key, "target")) {
        allocator.free(entry.target);
        entry.target = try parseString(allocator, value);
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

fn trimCarriageReturn(raw: []const u8) []const u8 {
    if (raw.len != 0 and raw[raw.len - 1] == '\r') return raw[0 .. raw.len - 1];
    return raw;
}
