const std = @import("std");
const contract = @import("runtime_contract");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--inspect-runtime")) return inspect(init, args[0]);
    if (args.len != 2) return error.ExpectedModel;
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
    const raw = try reader.interface.allocRemaining(a, .limited(8 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(contract.Request, a, raw, .{});
    defer parsed.deinit();
    const request = parsed.value;
    if (std.mem.eql(u8, request.prompt, "MALFORMED")) return std.Io.File.stdout().writeStreamingAll(init.io, "not-json\n");
    if (std.mem.eql(u8, request.prompt, "MULTIPLE")) return std.Io.File.stdout().writeStreamingAll(init.io, "{\"status\":\"ok\"}\n{\"status\":\"ok\"}\n");
    if (std.mem.eql(u8, request.prompt, "FAIL")) return error.DeliberateFailure;
    const result = .{
        .id = request.id,
        .status = "ok",
        .finish = "eog",
        .text = "fake response",
        .final_text = "fake response",
        .output_classification = "final_answer",
        .generated_tokens = @as(u32, 2),
        .elapsed_ms = @as(i64, 1),
        .backend = request.backend,
        .observed_temperature = request.temperature,
        .observed_max_tokens = request.max_tokens,
        .observed_context_size = request.context_size,
        .observed_schema = request.schema_json != null,
        .observed_expect_json = request.expect_json,
    };
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buffer);
    try std.json.Stringify.value(result, .{}, &out.interface);
    try out.interface.writeByte('\n');
    try out.interface.flush();
}

fn inspect(init: std.process.Init, executable: []const u8) !void {
    const a = init.arena.allocator();
    const backend = if (std.mem.indexOf(u8, executable, "cuda") != null) "cuda" else "cpu";
    const process_path = init.environ_map.get("PATH") orelse "";
    const library_dir = firstPathEntry(process_path);
    const modules_cpu = [_]Module{
        try fakeModule(a, library_dir, "llama.dll"), try fakeModule(a, library_dir, "ggml.dll"), try fakeModule(a, library_dir, "ggml-base.dll"), try fakeModule(a, library_dir, "ggml-cpu.dll"), try fakeModule(a, library_dir, "last-llama-schema.dll"),
    };
    const modules_cuda = [_]Module{
        try fakeModule(a, library_dir, "llama.dll"), try fakeModule(a, library_dir, "ggml.dll"), try fakeModule(a, library_dir, "ggml-base.dll"), try fakeModule(a, library_dir, "ggml-cpu.dll"), try fakeModule(a, library_dir, "ggml-cuda.dll"), try fakeModule(a, library_dir, "last-llama-schema.dll"),
    };
    const value = .{
        .format_version = 1,
        .runtime = .{
            .implementation = "fake-worker",
            .revision = "test",
            .llama_cpp_revision = "test",
            .protocol = contract.Boundary.protocol,
            .loaded_modules = if (std.mem.eql(u8, backend, "cuda")) modules_cuda[0..] else modules_cpu[0..],
        },
        .compute = .{
            .effective_backend = backend,
            .device_id = if (std.mem.eql(u8, backend, "cuda")) "fake-gpu" else "CPU",
            .device_description = if (std.mem.eql(u8, backend, "cuda")) "Fake CUDA" else "Fake CPU",
            .device_identity_source = "fake",
        },
        .observed_path = process_path,
    };
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    try std.json.Stringify.value(value, .{}, &out.interface);
    try out.interface.writeByte('\n');
    try out.interface.flush();
}

fn firstPathEntry(path: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, path, ';')) |end| path[0..end] else path;
}

fn fakeModule(a: std.mem.Allocator, directory: []const u8, name: []const u8) !Module {
    return .{ .name = name, .path = try std.fs.path.join(a, &.{ directory, name }) };
}

const Module = struct {
    name: []const u8,
    path: []const u8,
    sha256: []const u8 = "fake",
};
