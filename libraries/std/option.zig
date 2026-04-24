const std = @import("std");

pub fn Option(comptime T: type) type {
    return union(enum) {
        none,
        some: T,

        pub fn isSome(self: @This()) bool {
            return switch (self) {
                .some => true,
                .none => false,
            };
        }

        pub fn isNone(self: @This()) bool {
            return !self.isSome();
        }

        pub fn unwrapOr(self: @This(), fallback: T) T {
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
