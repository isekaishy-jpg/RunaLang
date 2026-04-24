pub fn Result(comptime T: type, comptime E: type) type {
    return union(enum) {
        ok: T,
        err: E,

        pub fn isOk(self: @This()) bool {
            return switch (self) {
                .ok => true,
                .err => false,
            };
        }

        pub fn isErr(self: @This()) bool {
            return !self.isOk();
        }
    };
}

pub fn ok(comptime T: type, comptime E: type, value: T) Result(T, E) {
    return .{ .ok = value };
}

pub fn err(comptime T: type, comptime E: type, value: E) Result(T, E) {
    return .{ .err = value };
}
