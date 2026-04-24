const std = @import("std");
const array_list = std.array_list;
const Allocator = std.mem.Allocator;

pub const summary = "Source files, spans, and maps.";

pub const FileId = u32;

pub const Span = struct {
    file_id: FileId,
    start: usize,
    end: usize,
};

pub const LineColumn = struct {
    line: usize,
    column: usize,
};

pub const File = struct {
    id: FileId,
    path: []const u8,
    contents: []const u8,
    line_starts: []usize,

    fn deinit(self: File, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.contents);
        allocator.free(self.line_starts);
    }

    pub fn lineColumnAt(self: *const File, offset: usize) LineColumn {
        var line_index: usize = 0;
        while (line_index + 1 < self.line_starts.len and self.line_starts[line_index + 1] <= offset) : (line_index += 1) {}

        return .{
            .line = line_index + 1,
            .column = (offset - self.line_starts[line_index]) + 1,
        };
    }
};

pub const Table = struct {
    allocator: Allocator,
    files: array_list.Managed(File),

    pub fn init(allocator: Allocator) Table {
        return .{
            .allocator = allocator,
            .files = array_list.Managed(File).init(allocator),
        };
    }

    pub fn deinit(self: *Table) void {
        for (self.files.items) |file| file.deinit(self.allocator);
        self.files.deinit();
    }

    pub fn get(self: *const Table, file_id: FileId) *const File {
        return &self.files.items[file_id];
    }

    pub fn loadFile(self: *Table, io: std.Io, path: []const u8) !FileId {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.path, path)) return file.id;
        }

        const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(4 * 1024 * 1024));
        errdefer self.allocator.free(contents);

        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        return try self.addOwnedFile(owned_path, contents);
    }

    pub fn addVirtualFile(self: *Table, path: []const u8, contents: []const u8) !FileId {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);

        const owned_contents = try self.allocator.dupe(u8, contents);
        errdefer self.allocator.free(owned_contents);

        return try self.addOwnedFile(owned_path, owned_contents);
    }

    fn addOwnedFile(self: *Table, owned_path: []const u8, owned_contents: []const u8) !FileId {
        var line_starts_list = array_list.Managed(usize).init(self.allocator);
        defer line_starts_list.deinit();

        try line_starts_list.append(0);
        for (owned_contents, 0..) |byte, index| {
            if (byte == '\n') try line_starts_list.append(index + 1);
        }

        const file_id: FileId = @intCast(self.files.items.len);
        try self.files.append(.{
            .id = file_id,
            .path = owned_path,
            .contents = owned_contents,
            .line_starts = try line_starts_list.toOwnedSlice(),
        });
        return file_id;
    }
};
