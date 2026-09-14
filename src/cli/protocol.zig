const std = @import("std");
const contract = @import("runtime_contract");
const config = @import("cli_config");

pub const Response = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(std.json.Value),
    line: []u8,

    pub fn deinit(self: *Response) void {
        self.parsed.deinit();
        self.allocator.free(self.line);
    }

    pub fn string(self: Response, name: []const u8) ?[]const u8 {
        if (self.parsed.value != .object) return null;
        const value = self.parsed.value.object.get(name) orelse return null;
        return if (value == .string) value.string else null;
    }

    pub fn integer(self: Response, name: []const u8) ?i64 {
        if (self.parsed.value != .object) return null;
        const value = self.parsed.value.object.get(name) orelse return null;
        return if (value == .integer) value.integer else null;
    }
};

pub fn makeRequest(resolved: config.Resolved, prompt: []const u8, schema_json: ?[]const u8) contract.Request {
    return .{
        .id = "cli-request",
        .prompt = prompt,
        .system = resolved.system,
        .context_size = resolved.generation.context_size,
        .max_tokens = resolved.generation.max_tokens,
        .temperature = resolved.generation.temperature,
        .top_p = resolved.generation.top_p,
        .seed = resolved.generation.seed,
        .timeout_ms = resolved.generation.timeout_ms,
        .schema_json = schema_json,
        .expect_json = schema_json != null,
        .backend = @tagName(resolved.backend),
        .gpu_layers = if (resolved.backend == .cpu) 0 else resolved.gpu_layers.?,
    };
}

pub fn encodeRequest(a: std.mem.Allocator, request: contract.Request) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(a, request, .{});
    var result = try a.realloc(json, json.len + 1);
    result[json.len] = '\n';
    return result;
}

pub fn parseOne(a: std.mem.Allocator, raw: []const u8) !Response {
    return parseRow(a, raw, true);
}

pub fn parseInspection(a: std.mem.Allocator, raw: []const u8) !Response {
    return parseRow(a, raw, false);
}

fn parseRow(a: std.mem.Allocator, raw: []const u8, require_status: bool) !Response {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyWorkerOutput;
    var tokens = std.mem.tokenizeAny(u8, trimmed, "\r\n");
    const line = tokens.next() orelse return error.EmptyWorkerOutput;
    if (tokens.next() != null) return error.MultipleWorkerRows;
    const owned_line = try a.dupe(u8, line);
    errdefer a.free(owned_line);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, owned_line, .{});
    if (parsed.value != .object) {
        var mutable = parsed;
        mutable.deinit();
        return error.InvalidWorkerResult;
    }
    if (require_status) {
        const status = parsed.value.object.get("status") orelse {
            var mutable = parsed;
            mutable.deinit();
            return error.InvalidWorkerResult;
        };
        if (status != .string) {
            var mutable = parsed;
            mutable.deinit();
            return error.InvalidWorkerResult;
        }
    }
    return .{ .allocator = a, .parsed = parsed, .line = owned_line };
}

test "request construction preserves contract and resolved values" {
    const resolved = config.Resolved{
        .selector = "x",
        .alias = null,
        .model_path = "model.gguf",
        .backend = .cuda,
        .gpu_layers = 33,
        .system = "system",
        .generation = .{ .max_tokens = 80, .temperature = 0.4, .top_p = 0.9, .seed = 7, .context_size = 1024, .timeout_ms = 20_000 },
    };
    const req = makeRequest(resolved, "hello", "{\"type\":\"object\"}");
    try std.testing.expectEqualStrings(contract.Boundary.protocol, req.protocol);
    try std.testing.expectEqualStrings("one-shot-v1", req.conversation);
    try std.testing.expectEqual(@as(u32, 33), req.gpu_layers);
    try std.testing.expect(req.expect_json);
}

test "worker response parser requires exactly one object row" {
    var ok = try parseOne(std.testing.allocator, "{\"status\":\"ok\",\"text\":\"hi\"}\n");
    defer ok.deinit();
    try std.testing.expectEqualStrings("ok", ok.string("status").?);
    try std.testing.expectError(error.MultipleWorkerRows, parseOne(std.testing.allocator, "{\"status\":\"ok\"}\n{\"status\":\"ok\"}\n"));
    try std.testing.expectError(error.EmptyWorkerOutput, parseOne(std.testing.allocator, " \r\n"));
    try std.testing.expectError(error.SyntaxError, parseOne(std.testing.allocator, "not-json\n"));
}
