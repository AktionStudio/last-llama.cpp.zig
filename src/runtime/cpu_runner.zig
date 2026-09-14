const std = @import("std");
const llama = @import("runtime_llama");
const schema = @import("schema");
const contract = @import("runtime_contract");
const support = @import("runtime_support");
const c = llama.c;
const Request = contract.Request;
const Result = contract.Result;
const Control = struct {
    deadline: i64,
    checks: u32 = 0,
    timed_out: bool = false,
    cancel_limit: ?u32 = null,
    cancelled: bool = false,
    fn abort(raw: ?*anyopaque) callconv(.c) bool {
        const self: *Control = @ptrCast(@alignCast(raw.?));
        self.checks += 1;
        if (c.ggml_time_ms() >= self.deadline) self.timed_out = true;
        if (self.cancel_limit) |limit| if (self.checks >= limit) {
            self.cancelled = true;
        };
        return self.timed_out or self.cancelled;
    }
};
fn probeGrammar(a: std.mem.Allocator, model: *llama.Model, req: Request, out: *Result) !void {
    const vocab = model.vocab() orelse return error.MissingVocab;
    const grammar = req.grammar orelse return error.MissingGrammar;
    if (grammar.len == 0) return error.InvalidGrammar;
    const grammar_z = try a.dupeSentinel(u8, grammar, 0);
    const raw = c.llama_sampler_init_grammar(@ptrCast(vocab), grammar_z.ptr, "root");
    if (raw == null) return error.InvalidGrammar;
    const sampler: llama.SamplerPtr = @ptrCast(raw);
    defer {
        sampler.reset();
        out.sampler_reset = true;
        sampler.deinit();
        out.sampler_destroyed = true;
    }
    var tokenizer = llama.Tokenizer.init(a);
    defer tokenizer.deinit();
    try tokenizer.tokenize(@ptrCast(vocab), req.grammar_candidate.?, false, true);
    const tokens = tokenizer.getTokens();
    out.prompt_tokens = tokens.len;
    out.grammar_accepts = false;
    out.finish = "grammar_rejected";
    for (0..tokens.len + 1) |index| {
        const token = if (index == tokens.len) vocab.tokenEos() else tokens[index];
        var candidate = [_]llama.TokenData{.{ .id = token, .logit = 0, .p = 0 }};
        var candidates = llama.TokenDataArray{ .data = &candidate, .size = 1, .selected = -1, .sorted = false };
        sampler.apply(&candidates);
        if (!std.math.isFinite(candidate[0].logit)) {
            out.rejected_token_index = index;
            return;
        }
        sampler.accept(token);
    }
    out.grammar_accepts = true;
    out.finish = "grammar_accepted";
}
fn generate(a: std.mem.Allocator, model: *llama.Model, req: Request, out: *Result) !void {
    if (req.grammar_candidate != null) {
        if (req.schema_json != null) return error.SchemaCandidateUnsupported;
        return probeGrammar(a, model, req, out);
    }
    const start = c.ggml_time_ms();
    defer out.elapsed_ms = c.ggml_time_ms() - start;
    if (!std.mem.eql(u8, req.backend, "cpu")) return error.UnsupportedBackend;
    if (!std.mem.eql(u8, req.conversation, "one-shot-v1")) return error.UnsupportedConversation;
    if (req.grammar != null and req.schema_json != null) return error.AmbiguousConstraint;
    if (req.context_size < 32 or req.context_size > model.nCtxTrain() or req.max_tokens > 4096 or req.timeout_ms > contract.Boundary.max_timeout_ms or req.temperature < 0 or req.top_p <= 0 or req.top_p > 1) return error.UnsupportedConfiguration;
    if (!std.mem.eql(u8, req.reasoning, "none")) return error.UnsupportedReasoning;
    const vocab = model.vocab() orelse return error.MissingVocab;
    out.rendered_prompt = (try support.renderTemplate(a, model, req)).rendered_prompt;
    var tokenizer = llama.Tokenizer.init(a);
    defer tokenizer.deinit();
    try tokenizer.tokenize(@ptrCast(vocab), out.rendered_prompt, false, true);
    const tokens = tokenizer.getTokens();
    out.prompt_tokens = tokens.len;
    if (tokens.len == 0) return error.EmptyPrompt;
    if (tokens.len > req.context_size or req.max_tokens > req.context_size - tokens.len) return error.ContextOverflow;
    var control = Control{ .deadline = start + req.timeout_ms, .cancel_limit = req.cancel_after_abort_checks };
    defer out.abort_checks = control.checks;
    var params = llama.Context.defaultParams();
    params.n_ctx = req.context_size;
    params.n_batch = req.context_size;
    params.n_threads = 4;
    params.n_threads_batch = 4;
    params.offload_kqv = false;
    params.abort_callback = Control.abort;
    params.abort_callback_data = &control;
    const ctx = try llama.Context.initWithModel(model, params);
    defer {
        out.kv_after = c.llama_memory_seq_pos_max(c.llama_get_memory(@ptrCast(ctx)), 0);
        c.llama_memory_clear(c.llama_get_memory(@ptrCast(ctx)), true);
        out.kv_after_clear = c.llama_memory_seq_pos_max(c.llama_get_memory(@ptrCast(ctx)), 0);
        ctx.deinit();
        out.context_destroyed = true;
    }
    out.effective_context = ctx.nCtx();
    out.kv_before = c.llama_memory_seq_pos_max(c.llama_get_memory(@ptrCast(ctx)), 0);
    if (out.kv_before != -1) return error.DirtyContext;
    var sampler = try llama.Sampler.initChain(.{});
    defer {
        sampler.reset();
        out.sampler_reset = true;
        sampler.deinit();
        out.sampler_destroyed = true;
    }
    var compiled_grammar: ?schema.Grammar = null;
    defer if (compiled_grammar) |*grammar| grammar.deinit();
    if (req.schema_json) |raw_schema| {
        var diagnostic: [512]u8 = @splat(0);
        compiled_grammar = try schema.compile(raw_schema, &diagnostic);
    }
    const selected_grammar = if (compiled_grammar) |*grammar| grammar.bytes() else req.grammar;
    if (selected_grammar) |grammar| {
        if (grammar.len == 0) return error.InvalidGrammar;
        const grammar_z = try a.dupeSentinel(u8, grammar, 0);
        const grammar_sampler = c.llama_sampler_init_grammar(@ptrCast(vocab), grammar_z.ptr, "root");
        if (grammar_sampler == null) return error.InvalidGrammar;
        sampler.add(@ptrCast(grammar_sampler));
    }
    if (req.temperature == 0) sampler.add(try llama.Sampler.initGreedy()) else {
        sampler.add(try llama.Sampler.initTopP(req.top_p, 1));
        sampler.add(try llama.Sampler.initTemp(req.temperature));
        sampler.add(try llama.Sampler.initDist(req.seed));
    }
    var detok = llama.Detokenizer.init(a);
    defer detok.deinit();
    var text = std.array_list.Managed(u8).init(a);
    defer text.deinit();
    defer out.text = a.dupe(u8, text.items) catch "";
    var batch = llama.Batch.initOne(tokens);
    var next: [1]llama.Token = undefined;
    out.finish = "max_tokens";
    for (0..req.max_tokens) |_| {
        if (req.cancel_after_decodes) |limit| if (out.decode_calls >= limit) {
            out.finish = "cancelled";
            return;
        };
        if (req.fail_after_decodes) |limit| if (out.decode_calls >= limit) return error.InjectedFailure;
        if (Control.abort(&control)) {
            out.finish = if (control.cancelled) "cancelled" else "timeout";
            return;
        }
        batch.decode(ctx) catch |err| {
            if (control.cancelled) {
                out.finish = "cancelled";
                return;
            }
            if (control.timed_out) {
                out.finish = "timeout";
                return;
            }
            return err;
        };
        out.decode_calls += 1;
        const token = sampler.sample(ctx, -1);
        if (vocab.isEog(token)) {
            out.finish = "eog";
            return;
        }
        try text.appendSlice(try detok.detokenize(@ptrCast(vocab), token));
        detok.clearRetainingCapacity();
        out.generated_tokens += 1;
        next[0] = token;
        batch = llama.Batch.initOne(&next);
    }
}
fn extractFinal(a: std.mem.Allocator, req: Request, out: *Result) !void {
    if (req.grammar_candidate != null) {
        out.output_classification = "diagnostic";
        return;
    }
    if (!std.mem.eql(u8, out.status, "ok")) {
        out.output_classification = "runtime_error";
        return;
    }
    if (!std.mem.eql(u8, out.finish, "eog")) {
        out.output_classification = out.finish;
        return;
    }
    if (std.mem.trim(u8, out.text, " \r\n\t").len == 0) {
        out.output_classification = "empty";
        return;
    }
    if (req.expect_json) {
        const parsed = std.json.parseFromSlice(std.json.Value, a, out.text, .{}) catch {
            out.output_classification = "malformed_json";
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            out.output_classification = "invalid_json_root";
            return;
        }
    }
    out.final_text = out.text;
    out.output_classification = "final_answer";
}
pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{ .enable_memory_limit = true, .safety = true }){};
    defer if (gpa.deinit() != .ok) @panic("allocator leak");
    const a = gpa.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--inspect-runtime")) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const inspection_allocator = arena.allocator();
        llama.Backend.init();
        defer llama.Backend.deinit();
        const request = Request{ .id = "runtime-inspection", .backend = "cpu" };
        const selection = try support.resolveDevice(request, .cpu);
        const inspection = try support.inspectRuntime(inspection_allocator, init.io, .cpu, selection);
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        try std.json.Stringify.value(inspection, .{}, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
        return;
    }
    if (args.len != 2 and args.len != 3 and args.len != 4) return error.ExpectedModelAndRequestsFile;
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);
    const raw = if (args.len == 2)
        try stdin_reader.interface.allocRemaining(a, .limited(8 * 1024 * 1024))
    else
        try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], a, .limited(8 * 1024 * 1024));
    defer a.free(raw);
    const parsed_many = if (args.len == 2) null else try std.json.parseFromSlice([]Request, a, raw, .{});
    defer if (parsed_many) |value| value.deinit();
    const parsed_one = if (args.len == 2) try std.json.parseFromSlice(Request, a, raw, .{}) else null;
    defer if (parsed_one) |value| value.deinit();
    const one = [_]Request{if (parsed_one) |value| value.value else undefined};
    const requests = if (parsed_many) |value| value.value else one[0..];
    if (requests.len == 0) return error.EmptyRequestSet;
    llama.Backend.init();
    defer {
        llama.Backend.deinit();
        std.debug.print("LAB_RUNTIME_SHUTDOWN\n", .{});
    }
    var mp = llama.Model.defaultParams();
    mp.n_gpu_layers = 0;
    const cycles = if (args.len == 4) try std.fmt.parseInt(u32, args[3], 10) else 1;
    if (cycles == 0 or cycles > 16) return error.InvalidCycleCount;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    for (0..cycles) |cycle| {
        const selection = try support.resolveDevice(requests[0], .cpu);
        var offload = support.Offload{};
        c.llama_log_set(support.Offload.callback, &offload);
        defer c.llama_log_set(null, null);
        const model = try llama.Model.initFromFile(args[1], mp);
        defer {
            model.deinit();
            std.debug.print("LAB_MODEL_UNLOADED cycle={d}\n", .{cycle});
            std.Io.sleep(init.io, .fromMilliseconds(100), .awake) catch {};
        }
        const effective_offload = try offload.verify(.cpu, requests[0].gpu_layers, @intCast(model.nLayer() + 1));
        for (requests) |req| {
            const before = gpa.total_requested_bytes;
            {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                var result = Result{
                    .id = req.id,
                    .model_cycle = @intCast(cycle),
                    .backend = "cpu",
                    .cancellation_granularity = "abort-callback-and-between-decodes",
                    .timeout_semantics = "abort-callback-and-between-decodes",
                };
                const rendered = support.renderTemplate(arena.allocator(), model, req) catch |err| blk: {
                    result.status = @errorName(err);
                    result.finish = "error";
                    break :blk null;
                };
                if (rendered) |template| {
                    result.attestation = support.attest(arena.allocator(), init.io, args[1], model, req, .cpu, selection, template.identity, effective_offload) catch |err| blk: {
                        result.status = @errorName(err);
                        result.finish = "error";
                        break :blk null;
                    };
                }
                if (std.mem.eql(u8, result.status, "ok")) {
                    if (req.operation == .inspect_model) {
                        result.finish = "inspected";
                        result.output_classification = "diagnostic";
                    } else if (req.operation != .generate) {
                        result.status = "UnsupportedOperation";
                        result.finish = "error";
                    } else {
                        generate(arena.allocator(), model, req, &result) catch |err| {
                            result.status = @errorName(err);
                            result.finish = "error";
                        };
                        try extractFinal(arena.allocator(), req, &result);
                    }
                }
                try std.json.Stringify.value(result, .{}, stdout);
                try stdout.writeByte('\n');
                try stdout.flush();
            }
            std.debug.print("LAB_REQUEST_RELEASED cycle={d} before={d} after={d}\n", .{ cycle, before, gpa.total_requested_bytes });
            if (gpa.total_requested_bytes != before) return error.RequestAllocationLeak;
        }
    }
}
