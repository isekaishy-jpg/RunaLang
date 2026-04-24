const std = @import("std");
const array_list = std.array_list;
const source = @import("../source/root.zig");
const Allocator = std.mem.Allocator;

pub const summary = "Type, ownership, and reflection diagnostics.";

pub const Severity = enum {
    warning,
    @"error",
};

pub const Diagnostic = struct {
    severity: Severity,
    code: []const u8,
    span: ?source.Span,
    message: []const u8,
};

pub const Bag = struct {
    allocator: Allocator,
    items: array_list.Managed(Diagnostic),

    pub fn init(allocator: Allocator) Bag {
        return .{
            .allocator = allocator,
            .items = array_list.Managed(Diagnostic).init(allocator),
        };
    }

    pub fn deinit(self: *Bag) void {
        for (self.items.items) |item| self.allocator.free(item.message);
        self.items.deinit();
    }

    pub fn add(self: *Bag, severity: Severity, code: []const u8, span: ?source.Span, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(message);

        try self.items.append(.{
            .severity = severity,
            .code = code,
            .span = span,
            .message = message,
        });
    }

    pub fn errorCount(self: *const Bag) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            if (item.severity == .@"error") count += 1;
        }
        return count;
    }

    pub fn warningCount(self: *const Bag) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            if (item.severity == .warning) count += 1;
        }
        return count;
    }

    pub fn hasErrors(self: *const Bag) bool {
        return self.errorCount() != 0;
    }

    pub fn formatDiagnostic(self: *const Bag, allocator: Allocator, index: usize, sources: ?*const source.Table) ![]const u8 {
        const item = self.items.items[index];

        if (item.span) |span| {
            if (sources) |table| {
                const file = table.get(span.file_id);
                const lc = file.lineColumnAt(span.start);
                return std.fmt.allocPrint(allocator, "{s}[{s}] {s}:{d}:{d}: {s}", .{
                    @tagName(item.severity),
                    item.code,
                    file.path,
                    lc.line,
                    lc.column,
                    item.message,
                });
            }
        }

        return std.fmt.allocPrint(allocator, "{s}[{s}]: {s}", .{
            @tagName(item.severity),
            item.code,
            item.message,
        });
    }
};
