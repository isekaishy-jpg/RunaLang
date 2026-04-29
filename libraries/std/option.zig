const std = @import("std");

pub fn Option(comptime T: type) type {
    return union(enum) {
        none,
        some: T,

        pub fn is_some(self: @This()) bool {
            return switch (self) {
                .some => true,
                .none => false,
            };
        }

        pub fn is_none(self: @This()) bool {
            return !self.is_some();
        }

        pub fn unwrap_or(self: @This(), fallback: T) T {
            return switch (self) {
                .some => |value| value,
                .none => fallback,
            };
        }
    };
}

pub fn some(comptime T: type, value: T) Option(T) {
    return .{ .some = value };
}

pub fn none(comptime T: type) Option(T) {
    return .none;
}
