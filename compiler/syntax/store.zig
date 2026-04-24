const std = @import("std");
const token_mod = @import("token.zig");
const trivia_mod = @import("trivia.zig");
const Allocator = std.mem.Allocator;

pub const TriviaChunk = struct {
    ref_count: usize = 1,
    items: []trivia_mod.Trivia,

    pub fn retain(self: *TriviaChunk) void {
        self.ref_count += 1;
    }

    pub fn release(self: *TriviaChunk, allocator: Allocator) void {
        std.debug.assert(self.ref_count != 0);
        self.ref_count -= 1;
        if (self.ref_count != 0) return;
        allocator.free(self.items);
        allocator.destroy(self);
    }
};

pub const TokenChunk = struct {
    ref_count: usize = 1,
    items: []token_mod.Token,
    trivia_chunk: *TriviaChunk,

    pub fn retain(self: *TokenChunk) void {
        self.ref_count += 1;
    }

    pub fn release(self: *TokenChunk, allocator: Allocator) void {
        std.debug.assert(self.ref_count != 0);
        self.ref_count -= 1;
        if (self.ref_count != 0) return;
        allocator.free(self.items);
        allocator.destroy(self);
    }
};

pub const TokenRef = struct {
    chunk: *const TokenChunk,
    index: u32,
};

pub const TriviaSegment = struct {
    chunk: *TriviaChunk,
    start: u32,
    len: u32,
    global_start: usize,
    span_delta: isize = 0,
    source_contents: ?[]const u8 = null,
};

pub const TokenSegment = struct {
    chunk: *TokenChunk,
    start: u32,
    len: u32,
    global_start: usize,
    span_delta: isize = 0,
    source_contents: ?[]const u8 = null,
};

pub const TriviaStore = struct {
    segments: []TriviaSegment,
    chunks: []*TriviaChunk,
    total_len: usize,

    pub fn empty() TriviaStore {
        return .{
            .segments = &.{},
            .chunks = &.{},
            .total_len = 0,
        };
    }

    pub fn deinit(self: *TriviaStore, allocator: Allocator) void {
        for (self.chunks) |chunk| chunk.release(allocator);
        allocator.free(self.segments);
        allocator.free(self.chunks);
        self.* = empty();
    }

    pub fn len(self: TriviaStore) usize {
        return self.total_len;
    }

    pub fn segmentCount(self: TriviaStore) usize {
        return self.segments.len;
    }

    pub fn get(self: TriviaStore, index: usize) trivia_mod.Trivia {
        const segment = self.segmentForIndex(index);
        const local_index = index - segment.global_start;
        return shiftTrivia(segment, segment.chunk.items[segment.start + local_index]);
    }

    pub fn initFromSegments(allocator: Allocator, source_segments: []const TriviaSegment) !TriviaStore {
        const segments = try allocator.alloc(TriviaSegment, source_segments.len);
        errdefer allocator.free(segments);

        const chunks = try collectUniqueTriviaChunks(allocator, source_segments);
        errdefer allocator.free(chunks);

        var total_len: usize = 0;
        for (source_segments, 0..) |segment, index| {
            segments[index] = .{
                .chunk = segment.chunk,
                .start = segment.start,
                .len = segment.len,
                .global_start = total_len,
                .span_delta = segment.span_delta,
                .source_contents = segment.source_contents,
            };
            total_len += segment.len;
        }

        for (chunks) |chunk| chunk.retain();
        return .{
            .segments = segments,
            .chunks = chunks,
            .total_len = total_len,
        };
    }

    fn segmentForIndex(self: TriviaStore, index: usize) TriviaSegment {
        std.debug.assert(index < self.total_len);
        for (self.segments) |segment| {
            if (index >= segment.global_start and index < segment.global_start + segment.len) return segment;
        }
        unreachable;
    }
};

pub const TokenStore = struct {
    segments: []TokenSegment,
    chunks: []*TokenChunk,
    total_len: usize,

    pub fn empty() TokenStore {
        return .{
            .segments = &.{},
            .chunks = &.{},
            .total_len = 0,
        };
    }

    pub fn deinit(self: *TokenStore, allocator: Allocator) void {
        for (self.chunks) |chunk| chunk.release(allocator);
        allocator.free(self.segments);
        allocator.free(self.chunks);
        self.* = empty();
    }

    pub fn len(self: TokenStore) usize {
        return self.total_len;
    }

    pub fn segmentCount(self: TokenStore) usize {
        return self.segments.len;
    }

    pub fn get(self: TokenStore, index: usize) token_mod.Token {
        return self.getRef(self.refAt(index));
    }

    pub fn getRef(self: TokenStore, token_ref: TokenRef) token_mod.Token {
        const segment = self.segmentForRef(token_ref);
        return shiftToken(segment, token_ref.chunk.items[token_ref.index]);
    }

    pub fn refAt(self: TokenStore, index: usize) TokenRef {
        const segment = self.segmentForIndex(index);
        const local_index = index - segment.global_start;
        return .{
            .chunk = segment.chunk,
            .index = segment.start + @as(u32, @intCast(local_index)),
        };
    }

    pub fn spanAt(self: TokenStore, index: usize) @TypeOf(token_mod.Token.span) {
        return self.get(index).span;
    }

    pub fn lexemeAt(self: TokenStore, index: usize) []const u8 {
        return self.get(index).lexeme;
    }

    pub fn indexOfRef(self: TokenStore, token_ref: TokenRef) ?usize {
        for (self.segments) |segment| {
            if (segment.chunk != token_ref.chunk) continue;
            if (token_ref.index < segment.start) continue;
            if (token_ref.index >= segment.start + segment.len) continue;
            return segment.global_start + (token_ref.index - segment.start);
        }
        return null;
    }

    pub fn leadingTriviaIterator(self: TokenStore, token_ref: TokenRef) TriviaIterator {
        const segment = self.segmentForRef(token_ref);
        const token = self.getRef(token_ref);
        return .{
            .chunk = token_ref.chunk.trivia_chunk,
            .range = token.leading_trivia,
            .segment = segment,
        };
    }

    pub fn trailingTriviaIterator(self: TokenStore, token_ref: TokenRef) TriviaIterator {
        const segment = self.segmentForRef(token_ref);
        const token = self.getRef(token_ref);
        return .{
            .chunk = token_ref.chunk.trivia_chunk,
            .range = token.trailing_trivia,
            .segment = segment,
        };
    }

    pub fn iterateRange(self: TokenStore, start: usize, end: usize) RangeIterator {
        return .{
            .store = self,
            .index = start,
            .end = end,
        };
    }

    pub fn initFromSegments(allocator: Allocator, source_segments: []const TokenSegment) !TokenStore {
        const segments = try allocator.alloc(TokenSegment, source_segments.len);
        errdefer allocator.free(segments);

        const chunks = try collectUniqueTokenChunks(allocator, source_segments);
        errdefer allocator.free(chunks);

        var total_len: usize = 0;
        for (source_segments, 0..) |segment, index| {
            segments[index] = .{
                .chunk = segment.chunk,
                .start = segment.start,
                .len = segment.len,
                .global_start = total_len,
                .span_delta = segment.span_delta,
                .source_contents = segment.source_contents,
            };
            total_len += segment.len;
        }

        for (chunks) |chunk| chunk.retain();
        return .{
            .segments = segments,
            .chunks = chunks,
            .total_len = total_len,
        };
    }

    fn segmentForIndex(self: TokenStore, index: usize) TokenSegment {
        std.debug.assert(index < self.total_len);
        for (self.segments) |segment| {
            if (index >= segment.global_start and index < segment.global_start + segment.len) return segment;
        }
        unreachable;
    }

    fn segmentForRef(self: TokenStore, token_ref: TokenRef) TokenSegment {
        for (self.segments) |segment| {
            if (segment.chunk != token_ref.chunk) continue;
            if (token_ref.index < segment.start) continue;
            if (token_ref.index >= segment.start + segment.len) continue;
            return segment;
        }
        unreachable;
    }

    pub const RangeIterator = struct {
        store: TokenStore,
        index: usize,
        end: usize,

        pub fn next(self: *RangeIterator) ?TokenRef {
            if (self.index >= self.end) return null;
            const token_ref = self.store.refAt(self.index);
            self.index += 1;
            return token_ref;
        }
    };

    pub const TriviaIterator = struct {
        chunk: *const TriviaChunk,
        range: trivia_mod.TriviaRange,
        segment: TokenSegment,
        index: u32 = 0,

        pub fn next(self: *TriviaIterator) ?trivia_mod.Trivia {
            if (self.index >= self.range.len) return null;
            const trivia = shiftTrivia(tokenSegmentAsTriviaSegment(self.segment), self.chunk.items[self.range.start + self.index]);
            self.index += 1;
            return trivia;
        }
    };
};

pub const LexedFile = struct {
    tokens: TokenStore,
    trivia: TriviaStore,

    pub fn deinit(self: *LexedFile, allocator: Allocator) void {
        self.tokens.deinit(allocator);
        self.trivia.deinit(allocator);
    }

    pub fn fromOwnedSlices(
        allocator: Allocator,
        tokens: []token_mod.Token,
        trivia: []trivia_mod.Trivia,
    ) !LexedFile {
        const trivia_chunk = try allocator.create(TriviaChunk);
        errdefer allocator.destroy(trivia_chunk);
        trivia_chunk.* = .{
            .items = trivia,
        };

        const token_chunk = try allocator.create(TokenChunk);
        errdefer allocator.destroy(token_chunk);
        token_chunk.* = .{
            .items = tokens,
            .trivia_chunk = trivia_chunk,
        };

        var token_store = try TokenStore.initFromSegments(allocator, &.{
            .{
                .chunk = token_chunk,
                .start = 0,
                .len = @intCast(tokens.len),
                .global_start = 0,
            },
        });
        errdefer token_store.deinit(allocator);

        var trivia_store = try TriviaStore.initFromSegments(allocator, &.{
            .{
                .chunk = trivia_chunk,
                .start = 0,
                .len = @intCast(trivia.len),
                .global_start = 0,
            },
        });
        errdefer trivia_store.deinit(allocator);

        token_chunk.release(allocator);
        trivia_chunk.release(allocator);

        return .{
            .tokens = token_store,
            .trivia = trivia_store,
        };
    }
};

fn triviaSegmentForTokenRange(store: TokenStore, start: usize, end: usize) TriviaSegment {
    std.debug.assert(start <= end);
    if (start == end) {
        const token_ref = if (store.len() == 0) null else if (start == store.len()) store.refAt(store.len() - 1) else store.refAt(start);
        if (token_ref) |ref| {
            const segment = store.segmentForRef(ref);
            return .{
                .chunk = ref.chunk.trivia_chunk,
                .start = 0,
                .len = 0,
                .global_start = 0,
                .span_delta = segment.span_delta,
                .source_contents = segment.source_contents,
            };
        }
        unreachable;
    }

    const first_ref = store.refAt(start);
    const last_ref = store.refAt(end - 1);
    const first_token = store.getRef(first_ref);
    const last_token = store.getRef(last_ref);
    const first_segment = store.segmentForRef(first_ref);
    const trivia_start = first_token.leading_trivia.start;
    const trivia_end = last_token.leading_trivia.start + last_token.leading_trivia.len;
    std.debug.assert(first_ref.chunk.trivia_chunk == last_ref.chunk.trivia_chunk);
    return .{
        .chunk = first_ref.chunk.trivia_chunk,
        .start = trivia_start,
        .len = trivia_end - trivia_start,
        .global_start = 0,
        .span_delta = first_segment.span_delta,
        .source_contents = first_segment.source_contents,
    };
}

pub fn tokenSegmentsForRange(
    allocator: Allocator,
    store: TokenStore,
    start_token: usize,
    end_token: usize,
    source_contents: ?[]const u8,
    span_delta: isize,
) ![]TokenSegment {
    if (start_token >= end_token) return allocator.alloc(TokenSegment, 0);

    var segments = std.array_list.Managed(TokenSegment).init(allocator);
    defer segments.deinit();

    for (store.segments) |segment| {
        const segment_start = segment.global_start;
        const segment_end = segment.global_start + segment.len;
        const overlap_start = @max(segment_start, start_token);
        const overlap_end = @min(segment_end, end_token);
        if (overlap_start >= overlap_end) continue;

        try segments.append(.{
            .chunk = segment.chunk,
            .start = segment.start + @as(u32, @intCast(overlap_start - segment_start)),
            .len = @intCast(overlap_end - overlap_start),
            .global_start = overlap_start,
            .span_delta = segment.span_delta + span_delta,
            .source_contents = source_contents orelse segment.source_contents,
        });
    }

    return try segments.toOwnedSlice();
}

pub fn triviaSegmentsForTokenSegments(
    allocator: Allocator,
    store: TokenStore,
    token_segments: []const TokenSegment,
) ![]TriviaSegment {
    var segments = std.array_list.Managed(TriviaSegment).init(allocator);
    defer segments.deinit();

    for (token_segments) |segment| {
        if (segment.len == 0) continue;
        var trivia_segment = triviaSegmentForTokenRange(store, segment.global_start, segment.global_start + segment.len);
        trivia_segment.span_delta = segment.span_delta;
        trivia_segment.source_contents = segment.source_contents;
        try segments.append(trivia_segment);
    }

    return try segments.toOwnedSlice();
}

fn collectUniqueTriviaChunks(
    allocator: Allocator,
    segments: []const TriviaSegment,
) ![]*TriviaChunk {
    var chunks = std.array_list.Managed(*TriviaChunk).init(allocator);
    defer chunks.deinit();

    for (segments) |segment| {
        if (containsTriviaChunk(chunks.items, segment.chunk)) continue;
        try chunks.append(segment.chunk);
    }

    return try chunks.toOwnedSlice();
}

fn containsTriviaChunk(chunks: []const *TriviaChunk, target: *TriviaChunk) bool {
    for (chunks) |chunk| {
        if (chunk == target) return true;
    }
    return false;
}

fn collectUniqueTokenChunks(
    allocator: Allocator,
    segments: []const TokenSegment,
) ![]*TokenChunk {
    var chunks = std.array_list.Managed(*TokenChunk).init(allocator);
    defer chunks.deinit();

    for (segments) |segment| {
        if (containsTokenChunk(chunks.items, segment.chunk)) continue;
        try chunks.append(segment.chunk);
    }

    return try chunks.toOwnedSlice();
}

fn containsTokenChunk(chunks: []const *TokenChunk, target: *TokenChunk) bool {
    for (chunks) |chunk| {
        if (chunk == target) return true;
    }
    return false;
}

fn shiftToken(segment: TokenSegment, token: token_mod.Token) token_mod.Token {
    if (segment.span_delta == 0 and segment.source_contents == null) return token;

    const source_contents = segment.source_contents orelse return token;
    const start = applyOffsetDelta(token.span.start, segment.span_delta);
    const end = applyOffsetDelta(token.span.end, segment.span_delta);
    return .{
        .kind = token.kind,
        .span = .{
            .file_id = token.span.file_id,
            .start = start,
            .end = end,
        },
        .lexeme = source_contents[start..end],
        .leading_trivia = token.leading_trivia,
        .trailing_trivia = token.trailing_trivia,
    };
}

fn shiftTrivia(segment: TriviaSegment, trivia: trivia_mod.Trivia) trivia_mod.Trivia {
    if (segment.span_delta == 0 and segment.source_contents == null) return trivia;

    const source_contents = segment.source_contents orelse return trivia;
    const start = applyOffsetDelta(trivia.span.start, segment.span_delta);
    const end = applyOffsetDelta(trivia.span.end, segment.span_delta);
    return .{
        .kind = trivia.kind,
        .span = .{
            .file_id = trivia.span.file_id,
            .start = start,
            .end = end,
        },
        .lexeme = source_contents[start..end],
    };
}

fn applyOffsetDelta(offset: usize, delta: isize) usize {
    return @intCast(@as(isize, @intCast(offset)) + delta);
}

fn tokenSegmentAsTriviaSegment(segment: TokenSegment) TriviaSegment {
    return .{
        .chunk = segment.chunk.trivia_chunk,
        .start = 0,
        .len = 0,
        .global_start = 0,
        .span_delta = segment.span_delta,
        .source_contents = segment.source_contents,
    };
}

test "token store supports mixed old and new chunk access" {
    var first = try LexedFile.fromOwnedSlices(
        std.testing.allocator,
        try std.testing.allocator.dupe(token_mod.Token, &.{
            .{
                .kind = .identifier,
                .span = .{ .file_id = 0, .start = 0, .end = 1 },
                .lexeme = "a",
            },
            .{
                .kind = .identifier,
                .span = .{ .file_id = 0, .start = 2, .end = 3 },
                .lexeme = "c",
            },
        }),
        try std.testing.allocator.alloc(trivia_mod.Trivia, 0),
    );
    defer first.deinit(std.testing.allocator);

    var second = try LexedFile.fromOwnedSlices(
        std.testing.allocator,
        try std.testing.allocator.dupe(token_mod.Token, &.{
            .{
                .kind = .identifier,
                .span = .{ .file_id = 0, .start = 1, .end = 2 },
                .lexeme = "bb",
            },
        }),
        try std.testing.allocator.alloc(trivia_mod.Trivia, 0),
    );
    defer second.deinit(std.testing.allocator);

    var merged_tokens = try TokenStore.initFromSegments(std.testing.allocator, &.{
        .{
            .chunk = first.tokens.segments[0].chunk,
            .start = 0,
            .len = 1,
            .global_start = 0,
        },
        .{
            .chunk = second.tokens.segments[0].chunk,
            .start = 0,
            .len = 1,
            .global_start = 1,
        },
        .{
            .chunk = first.tokens.segments[0].chunk,
            .start = 1,
            .len = 1,
            .global_start = 2,
        },
    });
    defer merged_tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), merged_tokens.len());
    try std.testing.expectEqualStrings("a", merged_tokens.lexemeAt(0));
    try std.testing.expectEqualStrings("bb", merged_tokens.lexemeAt(1));
    try std.testing.expectEqualStrings("c", merged_tokens.lexemeAt(2));

    const middle_ref = merged_tokens.refAt(1);
    try std.testing.expect(middle_ref.chunk == second.tokens.segments[0].chunk);
    try std.testing.expectEqual(@as(?usize, 1), merged_tokens.indexOfRef(middle_ref));
}
