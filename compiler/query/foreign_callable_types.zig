const std = @import("std");
const session = @import("../session/root.zig");
const typed_text = @import("text.zig");
const types = @import("../types/root.zig");

const Allocator = std.mem.Allocator;
const findMatchingDelimiter = typed_text.findMatchingDelimiter;
const findTopLevelHeaderScalar = typed_text.findTopLevelHeaderScalar;
const splitTopLevelCommaParts = typed_text.splitTopLevelCommaParts;

pub const Syntax = struct {
    abi: types.CallableAbi,
    parameters: []const []const u8,
    return_type: []const u8,
    variadic_tail: ?[]const u8 = null,

    pub fn deinit(self: *Syntax, allocator: Allocator) void {
        if (self.parameters.len != 0) allocator.free(self.parameters);
        self.* = .{
            .abi = .c,
            .parameters = &.{},
            .return_type = "",
        };
    }
};

pub const Parsed = struct {
    callable: types.CallableType,

    pub fn deinit(self: *Parsed, allocator: Allocator) void {
        if (self.callable.parameters.len != 0) allocator.free(self.callable.parameters);
        self.callable = .{
            .abi = .c,
            .parameters = &.{},
            .return_type = .{ .index = 0 },
        };
    }
};

pub const Resolvers = struct {
    canonical_type_expression: *const fn (*session.Session, session.ModuleId, []const u8) anyerror!types.CanonicalTypeId,
};

pub fn startsForeignCallableType(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "extern[");
}

pub fn parseSyntax(allocator: Allocator, raw: []const u8) !?Syntax {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "extern[")) return null;

    const convention_open = "extern".len;
    const convention_close = findMatchingDelimiter(trimmed, convention_open, '[', ']') orelse return null;
    const abi = parseConvention(trimmed[convention_open + 1 .. convention_close]) orelse return null;

    var rest = std.mem.trim(u8, trimmed[convention_close + 1 ..], " \t\r\n");
    if (!std.mem.startsWith(u8, rest, "fn")) return null;
    rest = std.mem.trim(u8, rest["fn".len..], " \t\r\n");
    if (rest.len == 0 or rest[0] != '(') return null;

    const params_close = findMatchingDelimiter(rest, 0, '(', ')') orelse return null;
    const params_raw = rest[1..params_close];
    const after_params = std.mem.trim(u8, rest[params_close + 1 ..], " \t\r\n");
    if (!std.mem.startsWith(u8, after_params, "->")) return null;

    const return_type = std.mem.trim(u8, after_params["->".len..], " \t\r\n");
    if (return_type.len == 0) return null;

    const parts = try splitTopLevelCommaParts(allocator, params_raw);
    defer allocator.free(parts);

    var parameters = std.array_list.Managed([]const u8).init(allocator);
    errdefer parameters.deinit();

    var variadic_tail: ?[]const u8 = null;
    const empty_parameter_list = parts.len == 1 and parts[0].len == 0;
    if (!empty_parameter_list) {
        for (parts, 0..) |part, index| {
            if (part.len == 0) return null;
            if (std.mem.startsWith(u8, part, "...")) {
                if (index + 1 != parts.len or variadic_tail != null) return null;
                const tail = parseVariadicTail(part) orelse return null;
                if (!std.mem.eql(u8, tail, "CVaList")) return null;
                variadic_tail = tail;
                continue;
            }
            if (variadic_tail != null) return null;
            try parameters.append(part);
        }
    }

    return .{
        .abi = abi,
        .parameters = try parameters.toOwnedSlice(),
        .return_type = return_type,
        .variadic_tail = variadic_tail,
    };
}

pub fn parseCanonical(
    active: *session.Session,
    module_id: session.ModuleId,
    raw: []const u8,
    resolvers: Resolvers,
) !?Parsed {
    var syntax = try parseSyntax(active.allocator, raw) orelse return null;
    defer syntax.deinit(active.allocator);

    var parameters: []types.CallableParameter = &.{};
    if (syntax.parameters.len != 0) {
        parameters = try active.allocator.alloc(types.CallableParameter, syntax.parameters.len);
    }
    errdefer if (parameters.len != 0) active.allocator.free(parameters);

    for (syntax.parameters, 0..) |parameter_type, index| {
        parameters[index] = .{
            .mode = .owned,
            .ty = try resolvers.canonical_type_expression(active, module_id, parameter_type),
        };
    }

    const return_type = try resolvers.canonical_type_expression(active, module_id, syntax.return_type);
    const variadic_tail = if (syntax.variadic_tail) |tail|
        try resolvers.canonical_type_expression(active, module_id, tail)
    else
        null;

    return .{ .callable = .{
        .abi = syntax.abi,
        .parameters = parameters,
        .return_type = return_type,
        .variadic_tail = variadic_tail,
    } };
}

fn parseConvention(raw: []const u8) ?types.CallableAbi {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return null;
    const name = trimmed[1 .. trimmed.len - 1];
    if (std.mem.eql(u8, name, "c")) return .c;
    if (std.mem.eql(u8, name, "system")) return .system;
    return null;
}

fn parseVariadicTail(raw: []const u8) ?[]const u8 {
    const after_marker = std.mem.trim(u8, raw["...".len..], " \t\r\n");
    if (after_marker.len == 0) return null;
    if (findTopLevelHeaderScalar(after_marker, ':')) |colon| {
        const name = std.mem.trim(u8, after_marker[0..colon], " \t\r\n");
        const type_name = std.mem.trim(u8, after_marker[colon + 1 ..], " \t\r\n");
        if (name.len == 0 or type_name.len == 0) return null;
        return type_name;
    }
    return after_marker;
}
