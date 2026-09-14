const std = @import("std");
pub const c = @import("llama_c").c;
const text = @import("./text.zig");

pub const Token = c.llama_token;
pub const TokenData = c.llama_token_data;
pub const TokenDataArray = c.llama_token_data_array;
pub const BackendState = struct {
    pub fn init() void {
        c.llama_backend_init();
    }

    pub fn deinit() void {
        c.llama_backend_free();
    }
};
pub const Backend = BackendState;

pub const Vocab = opaque {
    pub fn tokenEos(self: *const Vocab) Token {
        return c.llama_vocab_eos(@ptrCast(self));
    }

    pub fn isEog(self: *const Vocab, token: Token) bool {
        return c.llama_vocab_is_eog(@ptrCast(self), token);
    }
};

pub const Model = opaque {
    pub const Params = c.llama_model_params;

    pub fn defaultParams() Params {
        return c.llama_model_default_params();
    }

    pub fn initFromFile(path: [:0]const u8, params: Params) !*Model {
        const raw = c.llama_model_load_from_file(path.ptr, params);
        if (raw == null) return error.FailedToLoadModel;
        return @ptrCast(raw.?);
    }

    pub fn deinit(self: *Model) void {
        c.llama_model_free(@ptrCast(self));
    }

    pub fn cCPtr(self: *const Model) *const c.struct_llama_model {
        return selfPtr(self);
    }

    pub fn nCtxTrain(self: *const Model) i32 {
        return c.llama_model_n_ctx_train(self.cCPtr());
    }

    pub fn nLayer(self: *const Model) i32 {
        return c.llama_model_n_layer(self.cCPtr());
    }

    pub fn vocab(self: *const Model) ?*const Vocab {
        return @ptrCast(c.llama_model_get_vocab(self.cCPtr()));
    }

    pub fn metaValStr(self: *const Model, key: [:0]const u8, out: *[4096]u8) !?[]const u8 {
        const size = c.llama_model_meta_val_str(self.cCPtr(), key, out, out.len);
        if (size < 0) return null;
        // llama.cpp requires one spare byte for the NUL terminator. A returned
        // length equal to the buffer therefore means truncation, not a value.
        if (size >= out.len) return error.MetadataValueTooLong;
        return out[0..@as(usize, @intCast(size))];
    }

    fn selfPtr(self: *const Model) *const c.struct_llama_model {
        return @ptrCast(self);
    }
};

pub const Context = opaque {
    pub const Params = c.llama_context_params;

    pub fn defaultParams() Params {
        return c.llama_context_default_params();
    }

    pub fn initWithModel(model: *const Model, params: Params) !*Context {
        const raw = c.llama_init_from_model(@ptrCast(@constCast(model)), params);
        if (raw == null) return error.ContextCreationFailed;
        return @ptrCast(raw.?);
    }

    pub fn deinit(self: *Context) void {
        c.llama_free(@ptrCast(self));
    }

    pub fn cPtr(self: *Context) *c.struct_llama_context {
        return @ptrCast(self);
    }

    pub fn cCPtr(self: *const Context) *const c.struct_llama_context {
        return @ptrCast(self);
    }

    pub fn nCtx(self: *const Context) u32 {
        return c.llama_n_ctx(self.cCPtr());
    }
};

pub const Batch = struct {
    inner: c.llama_batch,

    pub fn initOne(tokens: []const Token) Batch {
        return .{
            .inner = c.llama_batch_get_one(
                @constCast(tokens.ptr),
                @intCast(tokens.len),
            ),
        };
    }

    pub fn decode(self: *const Batch, ctx: *const Context) !void {
        const status = c.llama_decode(@ptrCast(@constCast(ctx)), self.inner);
        return switch (status) {
            0 => {},
            1 => error.NoKvSlotWarning,
            2...std.math.maxInt(i32) => error.UnknownWarning,
            else => error.DecodeError,
        };
    }
};

pub const SamplerPtr = *align(8) Sampler;
pub const Sampler = opaque {
    pub fn initChain(params: c.llama_sampler_chain_params) !SamplerPtr {
        const raw = c.llama_sampler_chain_init(params);
        if (raw == null) return error.SamplerAllocation;
        return @ptrCast(raw.?);
    }

    pub fn initGreedy() !SamplerPtr {
        const raw = c.llama_sampler_init_greedy();
        if (raw == null) return error.SamplerAllocation;
        return @ptrCast(raw.?);
    }

    pub fn initTopP(top_p: f32, min_keep: usize) !SamplerPtr {
        const raw = c.llama_sampler_init_top_p(top_p, min_keep);
        if (raw == null) return error.SamplerAllocation;
        return @ptrCast(raw.?);
    }

    pub fn initTemp(temperature: f32) !SamplerPtr {
        const raw = c.llama_sampler_init_temp(temperature);
        if (raw == null) return error.SamplerAllocation;
        return @ptrCast(raw.?);
    }

    pub fn initDist(seed: u32) !SamplerPtr {
        const raw = c.llama_sampler_init_dist(seed);
        if (raw == null) return error.SamplerAllocation;
        return @ptrCast(raw.?);
    }

    pub fn add(self: SamplerPtr, next: SamplerPtr) void {
        c.llama_sampler_chain_add(@ptrCast(self), @ptrCast(next));
    }

    pub fn sample(self: SamplerPtr, ctx: *const Context, index: i32) Token {
        return c.llama_sampler_sample(@ptrCast(self), @ptrCast(@constCast(ctx)), index);
    }

    pub fn reset(self: SamplerPtr) void {
        c.llama_sampler_reset(@ptrCast(self));
    }

    pub fn deinit(self: SamplerPtr) void {
        c.llama_sampler_free(@ptrCast(self));
    }

    pub fn apply(self: SamplerPtr, candidates: *TokenDataArray) void {
        c.llama_sampler_apply(@ptrCast(self), candidates);
    }

    pub fn accept(self: SamplerPtr, token: Token) void {
        c.llama_sampler_accept(@ptrCast(self), token);
    }
};

pub const Tokenizer = text.Tokenizer;
pub const Detokenizer = text.Detokenizer;
