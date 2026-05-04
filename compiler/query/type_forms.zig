const std = @import("std");
const ast = @import("../ast/root.zig");
const type_lowering = @import("type_lowering.zig");
const type_syntax_support = @import("../type_syntax_support.zig");
const types = @import("../types/root.zig");

const Allocator = std.mem.Allocator;

pub const View = struct {
    allocator: Allocator,
    syntax: ast.TypeSyntax,

    pub fn fromSyntax(allocator: Allocator, syntax: ast.TypeSyntax) !View {
        return .{
            .allocator = allocator,
            .syntax = if (syntax.isStructured()) try syntax.clone(allocator) else .{
                .source = syntax.source,
            },
        };
    }

    pub fn fromTypeRef(allocator: Allocator, ty: types.TypeRef) !View {
        const syntax = try type_lowering.clonedSyntaxForTypeRef(allocator, ty) orelse return error.UnregisteredStructuredTypeName;
        return .{
            .allocator = allocator,
            .syntax = syntax,
        };
    }

    pub fn deinit(self: *View) void {
        self.syntax.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn rootNode(self: View) ast.TypeNode {
        return self.syntax.rootNode();
    }

    pub fn rootChildren(self: View) []const u32 {
        return self.syntax.childNodeIndices(0);
    }

    pub fn typeRef(self: View, node_index: usize) !types.TypeRef {
        var syntax = try cloneSubtree(self.allocator, self.syntax, node_index);
        defer syntax.deinit(self.allocator);
        return type_lowering.typeRefFromSyntax(self.allocator, syntax);
    }
};

pub const BoundaryTypeKind = enum {
    value,
    ephemeral_read,
    ephemeral_edit,
    retained_read,
    retained_edit,
};

pub const BoundaryType = struct {
    kind: BoundaryTypeKind,
    inner_type: types.TypeRef,
    lifetime_name: ?[]const u8 = null,

    pub fn isBoundary(self: BoundaryType) bool {
        return self.kind != .value;
    }
};

pub const RawPointerAccess = enum {
    read,
    edit,
};

pub const RawPointer = struct {
    access: RawPointerAccess,
    pointee: types.TypeRef,
};

pub const Callable = struct {
    is_suspend: bool,
    input_type: types.TypeRef,
    output_type: types.TypeRef,
};

pub const ForeignCallable = struct {
    abi: types.CallableAbi,
    parameters: []types.TypeRef,
    return_type: types.TypeRef,
    variadic: bool = false,

    pub fn deinit(self: *ForeignCallable, allocator: Allocator) void {
        if (self.parameters.len != 0) allocator.free(self.parameters);
        self.* = .{
            .abi = .c,
            .parameters = &.{},
            .return_type = .unsupported,
        };
    }
};

pub const FixedArrayShape = struct {
    element_type: types.TypeRef,
    length_text: []const u8,
    length: ?u64,
};

pub fn boundaryFromView(view: View) BoundaryType {
    const whole_type = type_lowering.typeRefFromSyntax(view.allocator, view.syntax) catch .unsupported;
    if (type_syntax_support.containsInvalid(view.syntax)) {
        return .{ .kind = .value, .inner_type = whole_type };
    }
    const root = view.rootNode();
    if (root.payload != .borrow) {
        return .{ .kind = .value, .inner_type = whole_type };
    }
    const borrow = root.payload.borrow;
    const children = view.rootChildren();
    if (children.len == 0) {
        return .{ .kind = .value, .inner_type = whole_type };
    }
    const inner_type = view.typeRef(children[children.len - 1]) catch whole_type;
    return .{
        .kind = switch (borrow.access) {
            .read => if (borrow.lifetime != null) .retained_read else .ephemeral_read,
            .edit => if (borrow.lifetime != null) .retained_edit else .ephemeral_edit,
        },
        .inner_type = inner_type,
        .lifetime_name = if (borrow.lifetime) |lifetime| std.mem.trim(u8, lifetime.text, " \t\r\n") else null,
    };
}

pub fn rawPointerFromView(view: View) ?RawPointer {
    const root = view.rootNode();
    const pointer = switch (root.payload) {
        .raw_pointer => |pointer| pointer,
        else => return null,
    };
    const children = view.rootChildren();
    if (children.len == 0) return null;
    return .{
        .access = switch (pointer.access) {
            .read => .read,
            .edit => .edit,
        },
        .pointee = view.typeRef(children[children.len - 1]) catch return null,
    };
}

pub fn tupleElementTypeRefs(allocator: Allocator, view: View) !?[]types.TypeRef {
    if (view.rootNode().payload != .tuple) return null;
    const children = view.rootChildren();
    if (children.len < 2) return null;
    const refs = try allocator.alloc(types.TypeRef, children.len);
    for (children, 0..) |child_index, index| {
        refs[index] = try view.typeRef(child_index);
    }
    return refs;
}

pub fn projectionElementType(view: View, index: usize) ?types.TypeRef {
    if (view.rootNode().payload != .tuple) return null;
    const children = view.rootChildren();
    if (children.len < 2 or index >= children.len) return null;
    return view.typeRef(children[index]) catch return null;
}

pub fn callableFromView(view: View) ?Callable {
    const root = view.rootNode();
    if (root.payload != .apply) return null;
    const children = view.rootChildren();
    if (children.len != 3) return null;
    const base = view.syntax.nodes[children[0]];
    if (base.payload != .name_ref) return null;
    const base_name = std.mem.trim(u8, base.source.text, " \t\r\n");
    const is_suspend = if (std.mem.eql(u8, base_name, "__callread"))
        false
    else if (std.mem.eql(u8, base_name, "__suspend_callread"))
        true
    else
        return null;
    if (view.syntax.nodes[children[1]].payload == .lifetime or view.syntax.nodes[children[2]].payload == .lifetime) return null;
    return .{
        .is_suspend = is_suspend,
        .input_type = view.typeRef(children[1]) catch return null,
        .output_type = view.typeRef(children[2]) catch return null,
    };
}

pub fn foreignCallableFromView(allocator: Allocator, view: View) !?ForeignCallable {
    const root = view.rootNode();
    const callable = switch (root.payload) {
        .foreign_callable => |callable| callable,
        else => return null,
    };
    const abi = parseConvention(callable.abi.text) orelse return null;
    const children = view.rootChildren();
    const parameter_count: usize = @intCast(callable.parameter_count);
    if (children.len != parameter_count + 1) return null;
    const parameters = try allocator.alloc(types.TypeRef, parameter_count);
    errdefer allocator.free(parameters);
    for (0..parameter_count) |index| {
        parameters[index] = try view.typeRef(children[index]);
    }
    return .{
        .abi = abi,
        .parameters = parameters,
        .return_type = try view.typeRef(children[children.len - 1]),
        .variadic = callable.has_variadic_tail,
    };
}

pub fn fixedArrayShapeFromView(view: View) ?FixedArrayShape {
    const root = view.rootNode();
    const array = switch (root.payload) {
        .fixed_array => |array| array,
        else => return null,
    };
    const children = view.rootChildren();
    if (children.len != 1) return null;
    const length_text = std.mem.trim(u8, array.length.text, " \t\r\n");
    return .{
        .element_type = view.typeRef(children[0]) catch return null,
        .length_text = length_text,
        .length = std.fmt.parseInt(u64, length_text, 10) catch null,
    };
}

pub fn applicationArgs(allocator: Allocator, view: View, family_name: []const u8) !?[]types.TypeRef {
    const root = view.rootNode();
    if (root.payload != .apply) return null;
    const children = view.rootChildren();
    if (children.len < 2) return null;
    const base = view.syntax.nodes[children[0]];
    if (base.payload != .name_ref) return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, base.source.text, " \t\r\n"), family_name)) return null;
    const args = try allocator.alloc(types.TypeRef, children.len - 1);
    errdefer allocator.free(args);
    for (children[1..], 0..) |child_index, index| {
        if (view.syntax.nodes[child_index].payload == .lifetime) return null;
        args[index] = try view.typeRef(child_index);
    }
    return args;
}

pub fn baseName(view: View) ?[]const u8 {
    const root = view.rootNode();
    return switch (root.payload) {
        .name_ref => std.mem.trim(u8, root.source.text, " \t\r\n"),
        .apply => blk: {
            const children = view.rootChildren();
            if (children.len == 0) break :blk null;
            const base = view.syntax.nodes[children[0]];
            if (base.payload != .name_ref) break :blk null;
            break :blk std.mem.trim(u8, base.source.text, " \t\r\n");
        },
        else => null,
    };
}

pub fn assocPath(view: View) ?[]const u8 {
    const root = view.rootNode();
    if (root.payload != .assoc) return null;
    return std.mem.trim(u8, root.source.text, " \t\r\n");
}

pub fn typeRefsStructurallyEqual(allocator: Allocator, lhs: types.TypeRef, rhs: types.TypeRef) !bool {
    switch (lhs) {
        .builtin, .unsupported => return lhs.eql(rhs),
        .named => {},
    }
    switch (rhs) {
        .builtin, .unsupported => return lhs.eql(rhs),
        .named => {},
    }
    var lhs_view = try View.fromTypeRef(allocator, lhs);
    defer lhs_view.deinit();
    var rhs_view = try View.fromTypeRef(allocator, rhs);
    defer rhs_view.deinit();
    if (!lhs_view.syntax.isStructured() or !rhs_view.syntax.isStructured()) {
        return std.mem.eql(
            u8,
            std.mem.trim(u8, lhs_view.syntax.text(), " \t\r\n"),
            std.mem.trim(u8, rhs_view.syntax.text(), " \t\r\n"),
        );
    }
    return nodesEqual(lhs_view.syntax, 0, rhs_view.syntax, 0);
}

fn nodesEqual(
    lhs_syntax: ast.TypeSyntax,
    lhs_index: usize,
    rhs_syntax: ast.TypeSyntax,
    rhs_index: usize,
) bool {
    const lhs = lhs_syntax.nodes[lhs_index];
    const rhs = rhs_syntax.nodes[rhs_index];
    if (std.meta.activeTag(lhs.payload) != std.meta.activeTag(rhs.payload)) return false;

    switch (lhs.payload) {
        .invalid => return false,
        .name_ref, .lifetime => {
            if (!std.mem.eql(u8, std.mem.trim(u8, lhs.source.text, " \t\r\n"), std.mem.trim(u8, rhs.source.text, " \t\r\n"))) return false;
        },
        .borrow => |lhs_borrow| {
            const rhs_borrow = rhs.payload.borrow;
            if (lhs_borrow.access != rhs_borrow.access) return false;
            if (!optionalSpanTextEqual(lhs_borrow.lifetime, rhs_borrow.lifetime)) return false;
        },
        .raw_pointer => |lhs_pointer| {
            if (lhs_pointer.access != rhs.payload.raw_pointer.access) return false;
        },
        .assoc => |lhs_assoc| {
            if (!std.mem.eql(u8, std.mem.trim(u8, lhs_assoc.member.text, " \t\r\n"), std.mem.trim(u8, rhs.payload.assoc.member.text, " \t\r\n"))) return false;
        },
        .fixed_array => |lhs_array| {
            if (!std.mem.eql(u8, std.mem.trim(u8, lhs_array.length.text, " \t\r\n"), std.mem.trim(u8, rhs.payload.fixed_array.length.text, " \t\r\n"))) return false;
        },
        .foreign_callable => |lhs_callable| {
            const rhs_callable = rhs.payload.foreign_callable;
            if (!std.mem.eql(u8, std.mem.trim(u8, lhs_callable.abi.text, " \t\r\n"), std.mem.trim(u8, rhs_callable.abi.text, " \t\r\n"))) return false;
            if (lhs_callable.parameter_count != rhs_callable.parameter_count) return false;
            if (lhs_callable.has_variadic_tail != rhs_callable.has_variadic_tail) return false;
        },
        .apply, .tuple => {},
    }

    const lhs_children = lhs_syntax.childNodeIndices(lhs_index);
    const rhs_children = rhs_syntax.childNodeIndices(rhs_index);
    if (lhs_children.len != rhs_children.len) return false;
    for (lhs_children, rhs_children) |lhs_child, rhs_child| {
        if (!nodesEqual(lhs_syntax, lhs_child, rhs_syntax, rhs_child)) return false;
    }
    return true;
}

fn cloneSubtree(allocator: Allocator, syntax: ast.TypeSyntax, root_index: usize) !ast.TypeSyntax {
    var nodes = std.array_list.Managed(ast.TypeNode).init(allocator);
    errdefer nodes.deinit();
    var child_indices = std.array_list.Managed(u32).init(allocator);
    errdefer child_indices.deinit();

    _ = try appendSubtree(allocator, syntax, root_index, &nodes, &child_indices);

    return .{
        .source = syntax.nodes[root_index].source,
        .nodes = try nodes.toOwnedSlice(),
        .child_indices = try child_indices.toOwnedSlice(),
    };
}

fn optionalSpanTextEqual(lhs: ?ast.SpanText, rhs: ?ast.SpanText) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, std.mem.trim(u8, lhs.?.text, " \t\r\n"), std.mem.trim(u8, rhs.?.text, " \t\r\n"));
}

fn appendSubtree(
    allocator: Allocator,
    syntax: ast.TypeSyntax,
    node_index: usize,
    nodes: *std.array_list.Managed(ast.TypeNode),
    child_indices: *std.array_list.Managed(u32),
) !u32 {
    const new_index: u32 = @intCast(nodes.items.len);
    try nodes.append(.{
        .source = syntax.nodes[node_index].source,
        .payload = syntax.nodes[node_index].payload,
    });

    const children = syntax.childNodeIndices(node_index);
    const child_start: u32 = @intCast(child_indices.items.len);
    for (children) |child_index| {
        try child_indices.append(try appendSubtree(allocator, syntax, child_index, nodes, child_indices));
    }

    nodes.items[new_index].child_start = child_start;
    nodes.items[new_index].child_len = @intCast(children.len);
    return new_index;
}

fn parseConvention(raw: []const u8) ?types.CallableAbi {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return null;
    const name = trimmed[1 .. trimmed.len - 1];
    if (std.mem.eql(u8, name, "c")) return .c;
    if (std.mem.eql(u8, name, "system")) return .system;
    return null;
}
