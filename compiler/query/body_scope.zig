const query_types = @import("types.zig");
const typed = @import("../typed/root.zig");
const type_support = @import("type_support.zig");
const types = @import("../types/root.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ScopeEntry = struct {
    name: []const u8,
    ty: types.TypeRef,
    mutable: bool,
    origin: type_support.BoundaryType,
};

pub const ScopeStack = struct {
    entries: std.array_list.Managed(ScopeEntry),
    marks: std.array_list.Managed(usize),

    pub fn init(allocator: Allocator) ScopeStack {
        return .{
            .entries = std.array_list.Managed(ScopeEntry).init(allocator),
            .marks = std.array_list.Managed(usize).init(allocator),
        };
    }

    pub fn deinit(self: *ScopeStack) void {
        self.entries.deinit();
        self.marks.deinit();
    }

    pub fn push(self: *ScopeStack) !void {
        try self.marks.append(self.entries.items.len);
    }

    pub fn pop(self: *ScopeStack) void {
        const mark = self.marks.pop() orelse 0;
        self.entries.shrinkRetainingCapacity(mark);
    }

    pub fn put(self: *ScopeStack, name: []const u8, ty: types.TypeRef, mutable: bool) !void {
        try self.putWithOrigin(name, ty, mutable, type_support.boundaryFromTypeRef(ty));
    }

    pub fn putWithOrigin(self: *ScopeStack, name: []const u8, ty: types.TypeRef, mutable: bool, origin: type_support.BoundaryType) !void {
        try self.entries.append(.{
            .name = name,
            .ty = ty,
            .mutable = mutable,
            .origin = origin,
        });
    }

    pub fn get(self: *const ScopeStack, name: []const u8) ?types.TypeRef {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.entries.items[index];
            if (std.mem.eql(u8, entry.name, name)) return entry.ty;
        }
        return null;
    }

    pub fn contains(self: *const ScopeStack, name: []const u8) bool {
        return self.get(name) != null;
    }

    pub fn isMutable(self: *const ScopeStack, name: []const u8) bool {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.entries.items[index];
            if (std.mem.eql(u8, entry.name, name)) return entry.mutable;
        }
        return false;
    }

    pub fn getOrigin(self: *const ScopeStack, name: []const u8) ?type_support.BoundaryType {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.entries.items[index];
            if (std.mem.eql(u8, entry.name, name)) return entry.origin;
        }
        return null;
    }

    pub fn updateOrigin(self: *ScopeStack, name: []const u8, origin: type_support.BoundaryType) void {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            if (!std.mem.eql(u8, self.entries.items[index].name, name)) continue;
            self.entries.items[index].origin = origin;
            return;
        }
    }
};

pub fn seedModuleConsts(scope: *ScopeStack, body: query_types.CheckedBody) !void {
    for (body.module_consts) |binding| {
        try scope.putWithOrigin(binding.name, binding.ty, false, type_support.boundaryFromTypeRef(binding.ty));
    }
}

pub fn seedParameters(scope: *ScopeStack, parameters: []const typed.Parameter) !void {
    for (parameters) |parameter| {
        try scope.putWithOrigin(parameter.name, parameter.ty, parameter.mode != .read, type_support.boundaryFromParameter(parameter));
    }
}
