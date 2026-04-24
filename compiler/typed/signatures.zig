const std = @import("std");
const diag = @import("../diag/root.zig");
const source = @import("../source/root.zig");
const typed_text = @import("text.zig");
const Allocator = std.mem.Allocator;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const findTopLevelHeaderScalar = typed_text.findTopLevelHeaderScalar;
const isPlainIdentifier = typed_text.isPlainIdentifier;
const splitTopLevelCommaParts = typed_text.splitTopLevelCommaParts;

pub const GenericParamKind = enum {
    type_param,
    lifetime_param,
};

pub const GenericParam = struct {
    name: []const u8,
    kind: GenericParamKind,
};

pub const BoundPredicate = struct {
    subject_name: []const u8,
    contract_name: []const u8,
};

pub const ProjectionEqualityPredicate = struct {
    subject_name: []const u8,
    associated_name: []const u8,
    value_type_name: []const u8,
};

pub const LifetimeOutlivesPredicate = struct {
    longer_name: []const u8,
    shorter_name: []const u8,
};

pub const TypeOutlivesPredicate = struct {
    type_name: []const u8,
    lifetime_name: []const u8,
};

pub const WherePredicate = union(enum) {
    bound: BoundPredicate,
    projection_equality: ProjectionEqualityPredicate,
    lifetime_outlives: LifetimeOutlivesPredicate,
    type_outlives: TypeOutlivesPredicate,
};

pub const NamedHeader = struct {
    name: []const u8,
    generic_params: []GenericParam,
};

pub const LeadingGenericParams = struct {
    remaining_source: []const u8,
    generic_params: []GenericParam,
};

pub fn isLifetimeName(raw: []const u8) bool {
    if (raw.len < 2 or raw[0] != '\'') return false;
    const body = raw[1..];
    if (std.mem.eql(u8, body, "static")) return true;
    if (!(std.ascii.isAlphabetic(body[0]) or body[0] == '_')) return false;
    for (body[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

pub fn isBuiltinLifetime(raw: []const u8) bool {
    return std.mem.eql(u8, raw, "'static");
}

pub fn parseGenericParams(allocator: Allocator, raw: []const u8, span: source.Span, diagnostics: *diag.Bag) ![]GenericParam {
    const inner = std.mem.trim(u8, raw, " \t");
    if (inner.len == 0) {
        try diagnostics.add(.@"error", "type.generic.param", span, "generic and lifetime parameter lists may not be empty", .{});
        return allocator.alloc(GenericParam, 0);
    }

    const parts = try splitTopLevelCommaParts(allocator, inner);
    defer allocator.free(parts);

    var generic_params = std.array_list.Managed(GenericParam).init(allocator);
    errdefer generic_params.deinit();

    for (parts) |part| {
        if (part.len == 0) {
            try diagnostics.add(.@"error", "type.generic.param", span, "malformed mixed generic and lifetime parameter list", .{});
            continue;
        }

        const param = if (isLifetimeName(part)) blk: {
            if (isBuiltinLifetime(part)) {
                try diagnostics.add(.@"error", "type.lifetime.param", span, "lifetime parameter list may not declare builtin lifetime '{s}'", .{part});
                continue;
            }
            break :blk GenericParam{ .name = part, .kind = .lifetime_param };
        } else blk: {
            if (!isPlainIdentifier(part)) {
                try diagnostics.add(.@"error", "type.generic.param", span, "malformed mixed generic and lifetime parameter list", .{});
                continue;
            }
            break :blk GenericParam{ .name = part, .kind = .type_param };
        };

        var duplicate = false;
        for (generic_params.items) |existing| {
            if (std.mem.eql(u8, existing.name, param.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.generic.param_duplicate", span, "duplicate generic or lifetime parameter '{s}'", .{param.name});
            continue;
        }

        try generic_params.append(param);
    }

    return generic_params.toOwnedSlice();
}

pub fn parseNamedHeader(allocator: Allocator, raw: []const u8, span: source.Span, diagnostics: *diag.Bag) !NamedHeader {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return error.InvalidParse;

    if (std.mem.indexOfScalar(u8, trimmed, '[')) |open_index| {
        const close_index = findMatchingDelimiter(trimmed, open_index, '[', ']') orelse {
            try diagnostics.add(.@"error", "type.generic.param", span, "malformed mixed generic and lifetime parameter list", .{});
            return .{ .name = std.mem.trim(u8, trimmed[0..open_index], " \t"), .generic_params = try allocator.alloc(GenericParam, 0) };
        };
        const name = std.mem.trim(u8, trimmed[0..open_index], " \t");
        const trailing = std.mem.trim(u8, trimmed[close_index + 1 ..], " \t");
        if (!isPlainIdentifier(name) or trailing.len != 0) {
            try diagnostics.add(.@"error", "type.generic.param", span, "malformed mixed generic and lifetime parameter list", .{});
        }
        return .{
            .name = name,
            .generic_params = try parseGenericParams(allocator, trimmed[open_index + 1 .. close_index], span, diagnostics),
        };
    }

    return .{
        .name = trimmed,
        .generic_params = try allocator.alloc(GenericParam, 0),
    };
}

pub fn parseLeadingGenericParams(allocator: Allocator, raw: []const u8, span: source.Span, diagnostics: *diag.Bag) !LeadingGenericParams {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0 or trimmed[0] != '[') {
        return .{
            .remaining_source = trimmed,
            .generic_params = try allocator.alloc(GenericParam, 0),
        };
    }

    const close_index = findMatchingDelimiter(trimmed, 0, '[', ']') orelse {
        try diagnostics.add(.@"error", "type.generic.param", span, "malformed mixed generic and lifetime parameter list", .{});
        return .{
            .remaining_source = trimmed,
            .generic_params = try allocator.alloc(GenericParam, 0),
        };
    };

    return .{
        .remaining_source = std.mem.trim(u8, trimmed[close_index + 1 ..], " \t"),
        .generic_params = try parseGenericParams(allocator, trimmed[1..close_index], span, diagnostics),
    };
}

pub fn mergeGenericParams(
    allocator: Allocator,
    inherited: []const GenericParam,
    local: []const GenericParam,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]GenericParam {
    var combined = std.array_list.Managed(GenericParam).init(allocator);
    errdefer combined.deinit();

    for (inherited) |param| {
        try combined.append(param);
    }
    for (local) |param| {
        var duplicate = false;
        for (combined.items) |existing| {
            if (std.mem.eql(u8, existing.name, param.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            try diagnostics.add(.@"error", "type.generic.param_duplicate", span, "duplicate generic or lifetime parameter '{s}'", .{param.name});
            continue;
        }
        try combined.append(param);
    }

    return combined.toOwnedSlice();
}

pub fn genericParamExists(generic_params: []const GenericParam, name: []const u8, kind: GenericParamKind) bool {
    for (generic_params) |param| {
        if (param.kind != kind) continue;
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

pub fn validateLifetimeReference(name: []const u8, generic_params: []const GenericParam, span: source.Span, diagnostics: *diag.Bag) !void {
    if (!isLifetimeName(name)) {
        try diagnostics.add(.@"error", "type.lifetime.syntax", span, "malformed lifetime name '{s}'", .{name});
        return;
    }
    if (isBuiltinLifetime(name) or genericParamExists(generic_params, name, .lifetime_param)) return;
    try diagnostics.add(.@"error", "type.lifetime.unknown", span, "unknown lifetime name '{s}'", .{name});
}

pub fn parseWherePredicates(
    allocator: Allocator,
    raw: []const u8,
    generic_params: []const GenericParam,
    allow_self: bool,
    span: source.Span,
    diagnostics: *diag.Bag,
) ![]WherePredicate {
    if (!std.mem.startsWith(u8, raw, "where ")) return allocator.alloc(WherePredicate, 0);

    var body = std.mem.trim(u8, raw["where ".len..], " \t");
    if (std.mem.endsWith(u8, body, ":")) body = std.mem.trim(u8, body[0 .. body.len - 1], " \t");
    if (body.len == 0) {
        try diagnostics.add(.@"error", "type.where.syntax", span, "where clauses require at least one predicate", .{});
        return allocator.alloc(WherePredicate, 0);
    }

    const parts = try splitTopLevelCommaParts(allocator, body);
    defer allocator.free(parts);

    var predicates = std.array_list.Managed(WherePredicate).init(allocator);
    errdefer predicates.deinit();

    for (parts) |part| {
        if (part.len == 0) {
            try diagnostics.add(.@"error", "type.where.syntax", span, "malformed where predicate list", .{});
            continue;
        }

        if (findTopLevelHeaderScalar(part, '=')) |equal_index| {
            const left = std.mem.trim(u8, part[0..equal_index], " \t");
            const right = std.mem.trim(u8, part[equal_index + 1 ..], " \t");
            const dot_index = std.mem.lastIndexOfScalar(u8, left, '.') orelse {
                try diagnostics.add(.@"error", "type.where.projection", span, "malformed projection equality predicate '{s}'", .{part});
                continue;
            };
            const subject_name = std.mem.trim(u8, left[0..dot_index], " \t");
            const associated_name = std.mem.trim(u8, left[dot_index + 1 ..], " \t");
            if ((subject_name.len == 0 or (!allow_self or !std.mem.eql(u8, subject_name, "Self")) and !genericParamExists(generic_params, subject_name, .type_param)) or
                !isPlainIdentifier(associated_name) or
                right.len == 0)
            {
                try diagnostics.add(.@"error", "type.where.projection", span, "malformed projection equality predicate '{s}'", .{part});
                continue;
            }
            try predicates.append(.{ .projection_equality = .{
                .subject_name = subject_name,
                .associated_name = associated_name,
                .value_type_name = right,
            } });
            continue;
        }

        if (findTopLevelHeaderScalar(part, ':')) |colon_index| {
            const left = std.mem.trim(u8, part[0..colon_index], " \t");
            const right = std.mem.trim(u8, part[colon_index + 1 ..], " \t");
            if (left.len == 0 or right.len == 0) {
                try diagnostics.add(.@"error", "type.where.syntax", span, "malformed where predicate '{s}'", .{part});
                continue;
            }

            if (isLifetimeName(left) and isLifetimeName(right)) {
                try predicates.append(.{ .lifetime_outlives = .{
                    .longer_name = left,
                    .shorter_name = right,
                } });
                continue;
            }

            if (isLifetimeName(right)) {
                if ((!allow_self or !std.mem.eql(u8, left, "Self")) and !genericParamExists(generic_params, left, .type_param)) {
                    try diagnostics.add(.@"error", "type.where.unknown_name", span, "unknown constrained name '{s}'", .{left});
                    continue;
                }
                try predicates.append(.{ .type_outlives = .{
                    .type_name = left,
                    .lifetime_name = right,
                } });
                continue;
            }

            if ((!allow_self or !std.mem.eql(u8, left, "Self")) and !genericParamExists(generic_params, left, .type_param)) {
                try diagnostics.add(.@"error", "type.where.unknown_name", span, "unknown constrained name '{s}'", .{left});
                continue;
            }
            try predicates.append(.{ .bound = .{
                .subject_name = left,
                .contract_name = right,
            } });
            continue;
        }

        try diagnostics.add(.@"error", "type.where.syntax", span, "malformed where predicate '{s}'", .{part});
    }

    return predicates.toOwnedSlice();
}
