const std = @import("std");
const array_list = std.array_list;
const types = @import("../../types/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Program entry and startup leaf code.";

pub fn renderMainWrapper(allocator: Allocator, callee_symbol: []const u8, return_type: types.Builtin) ![]const u8 {
    var out = array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("int main(void) {\n");
    switch (return_type) {
        .unit => {
            try out.appendSlice("    ");
            try out.appendSlice(callee_symbol);
            try out.appendSlice("();\n");
            try out.appendSlice("    return 0;\n");
        },
        .i32 => {
            try out.appendSlice("    return ");
            try out.appendSlice(callee_symbol);
            try out.appendSlice("();\n");
        },
        else => return error.UnsupportedEntryReturn,
    }
    try out.appendSlice("}\n");

    return out.toOwnedSlice();
}
