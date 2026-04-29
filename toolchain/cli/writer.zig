const std = @import("std");
const compiler = @import("compiler");

pub const Channel = enum {
    stdout,
    stderr,
};

pub fn writeLine(io: std.Io, channel: Channel, line: []const u8) !void {
    try writeLines(io, channel, &.{line});
}

pub fn writeLines(io: std.Io, channel: Channel, lines: []const []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(switch (channel) {
        .stdout => .stdout(),
        .stderr => .stderr(),
    }, io, &buffer);
    const out = &file_writer.interface;

    for (lines) |line| {
        try out.print("{s}\n", .{line});
    }

    try out.flush();
}

pub fn writeBlock(io: std.Io, channel: Channel, block: []const u8) !void {
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        try writeLine(io, channel, line);
    }
}

pub fn renderDiagnostics(
    allocator: std.mem.Allocator,
    io: std.Io,
    diagnostics: compiler.diag.Bag,
    sources: *const compiler.source.Table,
) !void {
    for (diagnostics.items.items, 0..) |_, index| {
        const line = try diagnostics.formatDiagnostic(allocator, index, sources);
        try writeLine(io, .stderr, line);
    }
}

pub const Capture = struct {
    allocator: std.mem.Allocator,
    stdout: std.array_list.Managed(u8),
    stderr: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) Capture {
        return .{
            .allocator = allocator,
            .stdout = std.array_list.Managed(u8).init(allocator),
            .stderr = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Capture) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }

    pub fn writeLine(self: *Capture, channel: Channel, line: []const u8) !void {
        const out = switch (channel) {
            .stdout => &self.stdout,
            .stderr => &self.stderr,
        };
        try out.appendSlice(line);
        try out.append('\n');
    }
};
