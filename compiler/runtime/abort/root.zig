const std = @import("std");
const array_list = std.array_list;
const Allocator = std.mem.Allocator;

pub const summary = "Fatal abort and termination leaf code.";
pub const failure_mode = "abort_only";

pub fn renderAbortSupport(allocator: Allocator) ![]const u8 {
    var out = array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice("static void runa_abort(void) {\n");
    try out.appendSlice("    abort();\n");
    try out.appendSlice("}\n\n");
    return out.toOwnedSlice();
}
