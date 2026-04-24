const std = @import("std");
const Io = std.Io;

pub fn writeLine(io: Io, line: []const u8) !void {
    try writeLines(io, &.{line});
}

pub fn writeLines(io: Io, lines: []const []const u8) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    for (lines) |line| {
        try stdout.print("{s}\n", .{line});
    }

    try stdout.flush();
}
