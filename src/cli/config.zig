const std = @import("std");
const contract = @import("runtime_contract");

pub const Backend = enum { auto, cpu, cuda };

pub const Generation = struct {
    max_tokens: ?u32 = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
    seed: ?u32 = null,
    context_size: ?u32 = null,
    timeout_ms: ?u32 = null,
};

pub const Worker = struct {
    path: ?[]const u8 = null,
    library_dirs: []const []const u8 = &.{},
};

pub const Workers = struct {
    cpu: Worker = .{},
    cuda: Worker = .{},
};

pub const Model = struct {
    path: []const u8,
    backend: ?Backend = null,
    gpu_layers: ?u32 = null,
    system: ?[]const u8 = null,
    generation: Generation = .{},
    description: ?[]const u8 = null,
};

pub const File = struct {
    default_model: ?[]const u8 = null,
    backend: ?Backend = null,
    gpu_layers: ?u32 = null,
    system: ?[]const u8 = null,
    generation: Generation = .{},
    workers: Workers = .{},
    models: std.json.ArrayHashMap(Model) = .{},
};

pub const Loaded = struct {
    value: File,
    source_path: ?[]const u8,
    base_dir: []const u8,
};

pub const Overrides = struct {
    backend: ?Backend = null,
    gpu_layers: ?u32 = null,
    system: ?[]const u8 = null,
    generation: Generation = .{},
};

pub const Resolved = struct {
    selector: []const u8,
    alias: ?[]const u8,
    model_path: []const u8,
    backend: Backend,
    gpu_layers: ?u32,
    system: []const u8,
    generation: EffectiveGeneration,
};

pub const EffectiveGeneration = struct {
    max_tokens: u32,
    temperature: f32,
    top_p: f32,
    seed: u32,
    context_size: u32,
    timeout_ms: u32,
};

pub fn discover(a: std.mem.Allocator, io: std.Io, exe_dir: []const u8, explicit: ?[]const u8) !Loaded {
    if (explicit) |path| {
        const absolute = try absoluteFrom(a, try std.process.currentPathAlloc(io, a), path);
        return load(a, io, absolute);
    }
    const candidate = try std.fs.path.join(a, &.{ exe_dir, "last-llama.json" });
    if (fileExists(io, candidate)) return load(a, io, candidate);
    return .{ .value = .{}, .source_path = null, .base_dir = exe_dir };
}

pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) !Loaded {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| {
        std.debug.print("error: cannot read config '{s}': {s}\n", .{ path, @errorName(err) });
        return error.Reported;
    };
    const parsed = std.json.parseFromSliceLeaky(File, a, raw, .{}) catch |err| {
        std.debug.print("error: invalid config '{s}': {s}\n", .{ path, @errorName(err) });
        return error.Reported;
    };
    const absolute = try absoluteFrom(a, try std.process.currentPathAlloc(io, a), path);
    const base = std.fs.path.dirname(absolute) orelse ".";
    try validateFile(parsed);
    return .{ .value = parsed, .source_path = absolute, .base_dir = base };
}

pub fn resolveModel(a: std.mem.Allocator, loaded: Loaded, positional: ?[]const u8, cli: Overrides) !Resolved {
    const selector = positional orelse loaded.value.default_model orelse {
        std.debug.print("error: no model supplied and no default_model is configured\n", .{});
        return error.Reported;
    };
    const entry = loaded.value.models.map.get(selector);
    const path_value = if (entry) |model| model.path else selector;
    const path = try absoluteFrom(a, loaded.base_dir, path_value);
    const model_generation = if (entry) |model| model.generation else Generation{};
    const model_backend = if (entry) |model| model.backend else null;
    const model_layers = if (entry) |model| model.gpu_layers else null;
    const model_system = if (entry) |model| model.system else null;
    return .{
        .selector = selector,
        .alias = if (entry != null) selector else null,
        .model_path = path,
        .backend = cli.backend orelse model_backend orelse loaded.value.backend orelse .auto,
        .gpu_layers = cli.gpu_layers orelse model_layers orelse loaded.value.gpu_layers,
        .system = cli.system orelse model_system orelse loaded.value.system orelse "You are a helpful assistant.",
        .generation = .{
            .max_tokens = cli.generation.max_tokens orelse model_generation.max_tokens orelse loaded.value.generation.max_tokens orelse 32,
            .temperature = cli.generation.temperature orelse model_generation.temperature orelse loaded.value.generation.temperature orelse 0,
            .top_p = cli.generation.top_p orelse model_generation.top_p orelse loaded.value.generation.top_p orelse 1,
            .seed = cli.generation.seed orelse model_generation.seed orelse loaded.value.generation.seed orelse 1,
            .context_size = cli.generation.context_size orelse model_generation.context_size orelse loaded.value.generation.context_size orelse 512,
            .timeout_ms = cli.generation.timeout_ms orelse model_generation.timeout_ms orelse loaded.value.generation.timeout_ms orelse 10_000,
        },
    };
}

pub fn validateResolved(resolved: Resolved) !void {
    const g = resolved.generation;
    if (g.context_size < 32) return report("context_size must be at least 32", .{});
    if (g.max_tokens > 4096) return report("max_tokens must be at most 4096", .{});
    if (g.temperature < 0 or !std.math.isFinite(g.temperature)) return report("temperature must be finite and non-negative", .{});
    if (g.top_p <= 0 or g.top_p > 1 or !std.math.isFinite(g.top_p)) return report("top_p must be greater than 0 and at most 1", .{});
    if (g.timeout_ms == 0 or g.timeout_ms > contract.Boundary.max_timeout_ms) return report("timeout_ms must be between 1 and {d}", .{contract.Boundary.max_timeout_ms});
    if (resolved.gpu_layers) |layers| if (layers == 0 or layers > 1000) return report("gpu_layers must be between 1 and 1000 when configured", .{});
}

pub fn validateFile(value: File) !void {
    if (value.gpu_layers) |layers| if (layers == 0 or layers > 1000) return report("config gpu_layers must be between 1 and 1000", .{});
    if (value.backend == .cpu and value.gpu_layers != null) return report("global gpu_layers cannot be combined with backend cpu", .{});
    try validateGeneration(value.generation, "global generation");
    var it = value.models.map.iterator();
    while (it.next()) |item| {
        if (item.key_ptr.*.len == 0) return report("model aliases cannot be empty", .{});
        if (item.value_ptr.path.len == 0) return report("model '{s}' has an empty path", .{item.key_ptr.*});
        if (item.value_ptr.gpu_layers) |layers| if (layers == 0 or layers > 1000) return report("model '{s}' has invalid gpu_layers", .{item.key_ptr.*});
        if (item.value_ptr.backend == .cpu and item.value_ptr.gpu_layers != null) return report("model '{s}' combines backend cpu with gpu_layers", .{item.key_ptr.*});
        try validateGeneration(item.value_ptr.generation, item.key_ptr.*);
    }
}

fn validateGeneration(value: Generation, scope: []const u8) !void {
    if (value.context_size) |n| if (n < 32) return report("{s} context_size must be at least 32", .{scope});
    if (value.max_tokens) |n| if (n > 4096) return report("{s} max_tokens must be at most 4096", .{scope});
    if (value.temperature) |n| if (n < 0 or !std.math.isFinite(n)) return report("{s} temperature must be finite and non-negative", .{scope});
    if (value.top_p) |n| if (n <= 0 or n > 1 or !std.math.isFinite(n)) return report("{s} top_p must be greater than 0 and at most 1", .{scope});
    if (value.timeout_ms) |n| if (n == 0 or n > contract.Boundary.max_timeout_ms) return report("{s} timeout_ms is outside the runtime range", .{scope});
}

pub fn chooseBackend(requested: Backend, gpu_layers_configured: bool, cuda_usable: bool, cpu_present: bool) !Backend {
    return switch (requested) {
        .cpu => if (gpu_layers_configured) error.CpuLayersNotAllowed else if (cpu_present) .cpu else error.CpuUnavailable,
        .cuda => if (!gpu_layers_configured) error.CudaLayersRequired else if (cuda_usable) .cuda else error.CudaUnavailable,
        .auto => if (gpu_layers_configured and cuda_usable) .cuda else if (cpu_present) .cpu else error.NoUsableBackend,
    };
}

pub fn resolveWorker(a: std.mem.Allocator, exe_dir: []const u8, loaded: Loaded, backend: Backend) !Worker {
    const name = switch (backend) {
        .cpu => "last-llama-cpu.exe",
        .cuda => "last-llama-cuda.exe",
        .auto => return error.UnresolvedBackend,
    };
    const configured = switch (backend) {
        .cpu => loaded.value.workers.cpu,
        .cuda => loaded.value.workers.cuda,
        .auto => unreachable,
    };
    const worker_path = try absoluteFrom(a, if (configured.path != null) loaded.base_dir else exe_dir, configured.path orelse name);
    if (configured.library_dirs.len != 0) {
        var dirs = try a.alloc([]const u8, configured.library_dirs.len);
        for (configured.library_dirs, 0..) |dir, i| dirs[i] = try absoluteFrom(a, loaded.base_dir, dir);
        return .{ .path = worker_path, .library_dirs = dirs };
    }
    const runtime_dir = try std.fs.path.join(a, &.{ exe_dir, "runtime", @tagName(backend) });
    const dirs = try a.alloc([]const u8, 1);
    dirs[0] = runtime_dir;
    return .{ .path = worker_path, .library_dirs = dirs };
}

pub fn fileExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn absoluteFrom(a: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return a.dupe(u8, path);
    return std.fs.path.resolve(a, &.{ base, path });
}

fn report(comptime message: []const u8, args: anytype) error{Reported} {
    std.debug.print("error: " ++ message ++ "\n", args);
    return error.Reported;
}

test "precedence is CLI then model then global then runtime default" {
    var models: std.json.ArrayHashMap(Model) = .{};
    try models.map.put(std.testing.allocator, "qwen", .{ .path = "model.gguf", .generation = .{ .temperature = 0.5, .max_tokens = 512 } });
    defer models.deinit(std.testing.allocator);
    const loaded = Loaded{ .value = .{ .generation = .{ .temperature = 0.7 }, .models = models }, .source_path = null, .base_dir = "C:\\config" };
    const resolved = try resolveModel(std.testing.allocator, loaded, "qwen", .{ .generation = .{ .temperature = 0.2 } });
    defer std.testing.allocator.free(resolved.model_path);
    try std.testing.expectEqual(@as(f32, 0.2), resolved.generation.temperature);
    try std.testing.expectEqual(@as(u32, 512), resolved.generation.max_tokens);
    try std.testing.expectEqual(@as(u32, 512), resolved.generation.context_size);
}

test "alias paths resolve from config directory and direct paths fall back" {
    var models: std.json.ArrayHashMap(Model) = .{};
    try models.map.put(std.testing.allocator, "smol", .{ .path = "models\\smol.gguf" });
    defer models.deinit(std.testing.allocator);
    const loaded = Loaded{ .value = .{ .models = models }, .source_path = null, .base_dir = "C:\\package" };
    const alias = try resolveModel(std.testing.allocator, loaded, "smol", .{});
    defer std.testing.allocator.free(alias.model_path);
    try std.testing.expectEqualStrings("C:\\package\\models\\smol.gguf", alias.model_path);
    const direct = try resolveModel(std.testing.allocator, loaded, "D:\\models\\direct.gguf", .{});
    defer std.testing.allocator.free(direct.model_path);
    try std.testing.expect(direct.alias == null);
    try std.testing.expectEqualStrings("D:\\models\\direct.gguf", direct.model_path);
}

test "strict config rejects unknown and duplicate fields" {
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(File, std.testing.allocator, "{\"backed\":\"cpu\"}", .{}));
    try std.testing.expectError(error.DuplicateField, std.json.parseFromSlice(File, std.testing.allocator, "{\"backend\":\"cpu\",\"backend\":\"cuda\"}", .{}));
}

test "config loading resolves its source directory" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "settings.json", .data = "{\"default_model\":\"x\",\"models\":{\"x\":{\"path\":\"models\\\\x.gguf\"}}}" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ root_buffer[0..root_len], "settings.json" });
    defer std.testing.allocator.free(config_path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loaded = try load(arena.allocator(), std.testing.io, config_path);
    const resolved = try resolveModel(arena.allocator(), loaded, null, .{});
    const expected = try std.fs.path.join(std.testing.allocator, &.{ root_buffer[0..root_len], "models", "x.gguf" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved.model_path);
}

test "backend selection never falls back from explicit CUDA" {
    try std.testing.expectError(error.CudaUnavailable, chooseBackend(.cuda, true, false, true));
    try std.testing.expectError(error.CudaLayersRequired, chooseBackend(.cuda, false, true, true));
    try std.testing.expectEqual(Backend.cpu, try chooseBackend(.auto, true, false, true));
    try std.testing.expectEqual(Backend.cuda, try chooseBackend(.auto, true, true, true));
    try std.testing.expectEqual(Backend.cpu, try chooseBackend(.auto, false, true, true));
    try std.testing.expectError(error.CpuLayersNotAllowed, chooseBackend(.cpu, true, false, true));
}
