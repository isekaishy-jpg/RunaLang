const std = @import("std");
const array_list = std.array_list;
const Allocator = std.mem.Allocator;

pub const public_api = true;
pub const runtime_metadata_opt_in = true;
pub const exported_only_runtime_metadata = true;

pub const ReflectionEntry = struct {
    name: []const u8,
    declaration_kind: []const u8,
    unsafe_item: bool = false,
    boundary_api: bool = false,

    fn deinit(self: ReflectionEntry, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.declaration_kind);
    }
};

pub const BoundaryApiEntry = struct {
    canonical_identity: []const u8,
    callable_kind: []const u8,
    input_type: []const u8,
    output_type: []const u8,
    export_name: ?[]const u8 = null,
    referenced_capability_families: [][]const u8,

    fn deinit(self: BoundaryApiEntry, allocator: Allocator) void {
        allocator.free(self.canonical_identity);
        allocator.free(self.callable_kind);
        allocator.free(self.input_type);
        allocator.free(self.output_type);
        if (self.export_name) |value| allocator.free(value);
        for (self.referenced_capability_families) |family| allocator.free(family);
        allocator.free(self.referenced_capability_families);
    }
};

pub const Metadata = struct {
    allocator: Allocator,
    package_name: ?[]const u8 = null,
    package_version: ?[]const u8 = null,
    product_name: ?[]const u8 = null,
    product_kind: ?[]const u8 = null,
    reflection: array_list.Managed(ReflectionEntry),
    boundary_apis: array_list.Managed(BoundaryApiEntry),

    pub fn init(allocator: Allocator) Metadata {
        return .{
            .allocator = allocator,
            .reflection = array_list.Managed(ReflectionEntry).init(allocator),
            .boundary_apis = array_list.Managed(BoundaryApiEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Metadata) void {
        if (self.package_name) |value| self.allocator.free(value);
        if (self.package_version) |value| self.allocator.free(value);
        if (self.product_name) |value| self.allocator.free(value);
        if (self.product_kind) |value| self.allocator.free(value);
        for (self.reflection.items) |entry| entry.deinit(self.allocator);
        self.reflection.deinit();
        for (self.boundary_apis.items) |entry| entry.deinit(self.allocator);
        self.boundary_apis.deinit();
    }
};

pub fn loadMetadataAtPath(allocator: Allocator, io: std.Io, path: []const u8) !Metadata {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(contents);
    return parseMetadata(allocator, contents);
}

pub fn parseMetadata(allocator: Allocator, contents: []const u8) !Metadata {
    var metadata = Metadata.init(allocator);
    errdefer metadata.deinit();

    const Section = enum { none, package, reflection, boundary_api };
    var current: Section = .none;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, trimCarriageReturn(raw_line), " \t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.eql(u8, line, "[package]")) {
            current = .package;
            continue;
        }
        if (std.mem.eql(u8, line, "[[reflection]]")) {
            current = .reflection;
            try metadata.reflection.append(.{
                .name = try allocator.dupe(u8, ""),
                .declaration_kind = try allocator.dupe(u8, ""),
            });
            continue;
        }
        if (std.mem.eql(u8, line, "[[boundary_apis]]")) {
            current = .boundary_api;
            try metadata.boundary_apis.append(.{
                .canonical_identity = try allocator.dupe(u8, ""),
                .callable_kind = try allocator.dupe(u8, ""),
                .input_type = try allocator.dupe(u8, ""),
                .output_type = try allocator.dupe(u8, ""),
                .referenced_capability_families = try allocator.alloc([]const u8, 0),
            });
            continue;
        }

        const eq_index = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidMetadata;
        const key = std.mem.trim(u8, line[0..eq_index], " \t");
        const value = std.mem.trim(u8, line[eq_index + 1 ..], " \t");

        switch (current) {
            .package => try assignPackageField(&metadata, key, value),
            .reflection => try assignReflectionField(allocator, &metadata.reflection.items[metadata.reflection.items.len - 1], key, value),
            .boundary_api => try assignBoundaryField(allocator, &metadata.boundary_apis.items[metadata.boundary_apis.items.len - 1], key, value),
            .none => return error.InvalidMetadata,
        }
    }

    return metadata;
}

fn assignPackageField(metadata: *Metadata, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "name")) {
        metadata.package_name = try parseString(metadata.allocator, value);
    } else if (std.mem.eql(u8, key, "version")) {
        metadata.package_version = try parseString(metadata.allocator, value);
    } else if (std.mem.eql(u8, key, "product")) {
        metadata.product_name = try parseString(metadata.allocator, value);
    } else if (std.mem.eql(u8, key, "kind")) {
        metadata.product_kind = try parseString(metadata.allocator, value);
    } else {
        return error.InvalidMetadata;
    }
}

fn assignReflectionField(allocator: Allocator, entry: *ReflectionEntry, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "name")) {
        allocator.free(entry.name);
        entry.name = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "declaration_kind")) {
        allocator.free(entry.declaration_kind);
        entry.declaration_kind = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "unsafe")) {
        entry.unsafe_item = try parseBool(value);
    } else if (std.mem.eql(u8, key, "boundary_api")) {
        entry.boundary_api = try parseBool(value);
    } else {
        return error.InvalidMetadata;
    }
}

fn assignBoundaryField(allocator: Allocator, entry: *BoundaryApiEntry, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "canonical_identity")) {
        allocator.free(entry.canonical_identity);
        entry.canonical_identity = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "callable_kind")) {
        allocator.free(entry.callable_kind);
        entry.callable_kind = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "input_type")) {
        allocator.free(entry.input_type);
        entry.input_type = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "output_type")) {
        allocator.free(entry.output_type);
        entry.output_type = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "export_name")) {
        if (entry.export_name) |old| allocator.free(old);
        entry.export_name = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "referenced_capability_families")) {
        for (entry.referenced_capability_families) |family| allocator.free(family);
        allocator.free(entry.referenced_capability_families);
        entry.referenced_capability_families = try parseStringArray(allocator, value);
    } else {
        return error.InvalidMetadata;
    }
}

fn parseString(allocator: Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return error.InvalidMetadata;
    return allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
}

fn parseBool(raw: []const u8) !bool {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (std.mem.eql(u8, trimmed, "true")) return true;
    if (std.mem.eql(u8, trimmed, "false")) return false;
    return error.InvalidMetadata;
}

fn parseStringArray(allocator: Allocator, raw: []const u8) ![][]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.InvalidMetadata;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return allocator.alloc([]const u8, 0);

    var values = array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit();
    }

    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |raw_part| {
        try values.append(try parseString(allocator, std.mem.trim(u8, raw_part, " \t")));
    }
    return values.toOwnedSlice();
}

fn trimCarriageReturn(raw: []const u8) []const u8 {
    if (raw.len != 0 and raw[raw.len - 1] == '\r') return raw[0 .. raw.len - 1];
    return raw;
}
