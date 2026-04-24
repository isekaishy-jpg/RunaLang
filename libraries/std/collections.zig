const std = @import("std");
const option = @import("option.zig");

pub fn List(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        items: std.array_list.Managed(T),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .items = std.array_list.Managed(T).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.items.deinit();
        }

        pub fn count(self: *@This()) usize {
            return self.items.items.len;
        }

        pub fn isEmpty(self: *@This()) bool {
            return self.items.items.len == 0;
        }

        pub fn push(self: *@This(), value: T) !void {
            try self.items.append(value);
        }

        pub fn pop(self: *@This()) option.Option(T) {
            if (self.items.items.len == 0) return .none;
            return .{ .some = self.items.pop().? };
        }

        pub fn insert(self: *@This(), at: usize, value: T) !void {
            try self.items.insert(at, value);
        }

        pub fn remove(self: *@This(), at: usize) T {
            return self.items.orderedRemove(at);
        }

        pub fn clear(self: *@This()) void {
            self.items.clearRetainingCapacity();
        }

        pub fn reserve(self: *@This(), additional: usize) !void {
            try self.items.ensureUnusedCapacity(additional);
        }
    };
}

pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
        allocator: std.mem.Allocator,
        inner: std.AutoHashMap(K, V),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
                .inner = std.AutoHashMap(K, V).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
        }

        pub fn count(self: *@This()) usize {
            return self.inner.count();
        }

        pub fn isEmpty(self: *@This()) bool {
            return self.inner.count() == 0;
        }

        pub fn containsKey(self: *@This(), key: K) bool {
            return self.inner.contains(key);
        }

        pub fn insert(self: *@This(), key: K, value: V) !option.Option(V) {
            const existing = self.inner.get(key);
            try self.inner.put(key, value);
            if (existing) |old| return .{ .some = old };
            return .none;
        }

        pub fn remove(self: *@This(), key: K) option.Option(V) {
            if (self.inner.fetchRemove(key)) |removed| {
                return .{ .some = removed.value };
            }
            return .none;
        }

        pub fn clear(self: *@This()) void {
            self.inner.clearRetainingCapacity();
        }

        pub fn reserve(self: *@This(), additional: usize) !void {
            try self.inner.ensureUnusedCapacity(additional);
        }
    };
}
