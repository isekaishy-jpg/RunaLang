const source = @import("../source/root.zig");

pub const TriviaKind = enum {
    whitespace,
    comment,
};

pub const Trivia = struct {
    kind: TriviaKind,
    span: source.Span,
    lexeme: []const u8,
};

pub const TriviaRange = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub fn slice(self: TriviaRange, all: []const Trivia) []const Trivia {
        return all[self.start .. self.start + self.len];
    }
};
