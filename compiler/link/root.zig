const std = @import("std");
const diag = @import("../diag/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Final artifact linkage.";

pub const OutputKind = enum {
    bin,
    cdylib,
};

pub fn linkGeneratedC(
    allocator: Allocator,
    io: std.Io,
    c_path: []const u8,
    output_path: []const u8,
    kind: OutputKind,
    diagnostics: *diag.Bag,
) !void {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("zig");
    try argv.append("cc");
    if (kind == .cdylib) try argv.append("-shared");
    try argv.append(c_path);
    try argv.append("-o");
    try argv.append(output_path);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .inherit,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return;
            try diagnostics.add(.@"error", "link.zig_cc", null, "zig cc failed with exit code {d}: {s}", .{
                code,
                std.mem.trim(u8, result.stderr, " \t\r\n"),
            });
            return error.LinkFailed;
        },
        else => {
            try diagnostics.add(.@"error", "link.zig_cc", null, "zig cc did not exit normally", .{});
            return error.LinkFailed;
        },
    }
}
