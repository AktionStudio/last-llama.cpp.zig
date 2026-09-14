const std = @import("std");
const c = @import("llama_c").c;

pub const Token = c.llama_token;
pub const TokenData = c.llama_token_data;
pub const TokenDataArray = c.llama_token_data_array;

pub const Tokenizer = struct {
    allocator: std.mem.Allocator,
    tokens: std.array_list.Managed(Token),

    pub fn init(allocator: std.mem.Allocator) Tokenizer {
        return .{
            .allocator = allocator,
            .tokens = std.array_list.Managed(Token).init(allocator),
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.tokens.deinit();
    }

    pub fn tokenize(
        self: *Tokenizer,
        vocab: ?*const c.struct_llama_vocab,
        text: []const u8,
        add_special: bool,
        parse_special: bool,
    ) !void {
        if (text.len > std.math.maxInt(c_int)) return error.TokenizeTooLarge;
        self.tokens.clearRetainingCapacity();
        var needed = c.llama_tokenize(
            vocab,
            text.ptr,
            @as(c_int, @intCast(text.len)),
            null,
            0,
            add_special,
            parse_special,
        );
        if (needed < 0) {
            if (needed == std.math.minInt(c_int)) return error.TokenizeTooLarge;
            const required = @as(usize, @intCast(-needed));
            if (required == 0) return error.TokenizeFailed;
            try self.tokens.ensureTotalCapacity(required);
        } else if (needed == 0) {
            self.tokens.clearRetainingCapacity();
            return;
        } else {
            try self.tokens.ensureTotalCapacity(@as(usize, @intCast(needed)));
        }

        if (self.tokens.capacity > std.math.maxInt(c_int)) return error.TokenizeTooLarge;
        needed = c.llama_tokenize(
            vocab,
            text.ptr,
            @as(c_int, @intCast(text.len)),
            self.tokens.items.ptr,
            @as(c_int, @intCast(self.tokens.capacity)),
            add_special,
            parse_special,
        );
        if (needed < 0 or needed > @as(c_int, @intCast(self.tokens.capacity))) return error.TokenizeFailed;
        self.tokens.items.len = @intCast(needed);
    }

    pub fn getTokens(self: *const Tokenizer) []const Token {
        return self.tokens.items;
    }
};

pub const Detokenizer = struct {
    allocator: std.mem.Allocator,
    buffer: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) Detokenizer {
        return .{ .allocator = allocator, .buffer = std.array_list.Managed(u8).init(allocator) };
    }

    pub fn deinit(self: *Detokenizer) void {
        self.buffer.deinit();
    }

    pub fn detokenize(self: *Detokenizer, vocab: ?*const c.struct_llama_vocab, token: Token) ![]const u8 {
        if (self.buffer.items.len == self.buffer.capacity) try self.buffer.ensureTotalCapacity(self.buffer.items.len + 16);
        const start = self.buffer.items.len;
        if (self.buffer.capacity - start > std.math.maxInt(c_int)) return error.DetokenizeTooLarge;
        var needed = c.llama_token_to_piece(
            vocab,
            token,
            self.buffer.items.ptr + start,
            @as(c_int, @intCast(self.buffer.capacity - start)),
            0,
            true,
        );
        if (needed < 0) {
            if (needed == std.math.minInt(c_int)) return error.DetokenizeTooLarge;
            const target = @as(usize, @intCast(-needed));
            if (target == 0) return error.DetokenizeFailed;
            try self.buffer.ensureTotalCapacity(start + target);
            if (self.buffer.capacity - start > std.math.maxInt(c_int)) return error.DetokenizeTooLarge;
            needed = c.llama_token_to_piece(
                vocab,
                token,
                self.buffer.items.ptr + start,
                @as(c_int, @intCast(self.buffer.capacity - start)),
                0,
                true,
            );
        }
        if (needed < 0) return error.DetokenizeFailed;
        const count = @as(usize, @intCast(needed));
        self.buffer.items.len = start + count;
        return self.buffer.items[start .. start + count];
    }

    pub fn clearRetainingCapacity(self: *Detokenizer) void {
        self.buffer.clearRetainingCapacity();
    }
};

pub const TokenizerOrError = error{
    TokenizeFailed,
    DetokenizeFailed,
    TokenizeTooLarge,
    DetokenizeTooLarge,
};
