const std = @import("std");
const array_list = std.array_list;
const string_hash_map = std.StringHashMapUnmanaged;
const Allocator = std.mem.Allocator;

pub const summary = "Interning for identifiers and stable compiler data.";

pub const SymbolId = u32;

pub const Interner = struct {
    allocator: Allocator,
    ids: string_hash_map(SymbolId) = .empty,
    values: array_list.Managed([]const u8),

    pub fn init(allocator: Allocator) Interner {
        return .{
            .allocator = allocator,
            .values = array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Interner) void {
        var iterator = self.ids.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.ids.deinit(self.allocator);
        self.values.deinit();
    }

    pub fn intern(self: *Interner, value: []const u8) !SymbolId {
        if (self.ids.get(value)) |id| return id;

        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);

        const id: SymbolId = @intCast(self.values.items.len);
        try self.values.append(owned);
        try self.ids.put(self.allocator, owned, id);
        return id;
    }

    pub fn lookup(self: *const Interner, id: SymbolId) ?[]const u8 {
        if (id >= self.values.items.len) return null;
        return self.values.items[id];
    }

    pub fn count(self: *const Interner) usize {
        return self.values.items.len;
    }
};
