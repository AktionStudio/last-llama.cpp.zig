const std = @import("std");
const contract = @import("runtime_contract");

test "standalone boundary names both explicit backends" {
    try std.testing.expectEqualStrings("last-llama-cpu", contract.Boundary.executableName(.cpu));
    try std.testing.expectEqualStrings("last-llama-cuda", contract.Boundary.executableName(.cuda));
    try std.testing.expectEqualStrings("one-shot-v1", contract.Boundary.conversation);
    try std.testing.expectEqual(@as(u32, 300_000), contract.Boundary.max_timeout_ms);
}

test "runtime boundary lists the complete lifecycle" {
    const operations = [_]contract.Operation{
        .initialize,
        .inspect_runtime,
        .inspect_model,
        .load_model,
        .generate,
        .cancel,
        .unload_model,
        .shutdown,
    };
    try std.testing.expectEqual(@as(usize, 8), operations.len);
}

test "attestation contract separates runtime model template and compute identity" {
    const modules = [_]contract.ModuleIdentity{.{ .name = "llama.dll", .path = "C:\\runtime\\llama.dll", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }};
    const value = contract.Attestation{
        .runtime = .{
            .revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            .llama_cpp_revision = "cccccccccccccccccccccccccccccccccccccccc",
            .executable_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            .loaded_modules = &modules,
        },
        .model = .{
            .resolved_path = "C:\\models\\model.gguf",
            .sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            .architecture = "qwen3",
            .quantization = "15",
            .context_capability = 32768,
        },
        .template = .{
            .treatment = "qwen3-no-think-directive-v1",
            .source_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            .effective_sha256 = "1111111111111111111111111111111111111111111111111111111111111111",
        },
        .compute = .{
            .requested_backend = "cuda",
            .effective_backend = "cuda",
            .device_id = "0000:0b:00.0",
            .device_description = "NVIDIA GeForce RTX 3090",
            .device_identity_source = "ggml-device-id",
            .requested_offload = 65,
            .effective_offload = 65,
            .total_layers = 65,
        },
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
    defer std.testing.allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(contract.Attestation, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(contract.Boundary.protocol, parsed.value.runtime.protocol);
    try std.testing.expectEqualStrings("qwen3-no-think-directive-v1", parsed.value.template.treatment);
    try std.testing.expectEqual(@as(u32, 65), parsed.value.compute.effective_offload);
}

test "request pins every admission identity under additive v1" {
    const expected = [_]contract.ExpectedModule{.{ .name = "llama.dll", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }};
    const request = contract.Request{
        .id = "fixture",
        .backend = "cpu",
        .operation = .inspect_model,
        .treatment = "model-template-default-v1",
        .expected_runtime_revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .expected_llama_cpp_revision = "cccccccccccccccccccccccccccccccccccccccc",
        .expected_executable_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .expected_model_sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        .expected_model_architecture = "llama",
        .expected_template_sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        .expected_modules = &expected,
    };
    try std.testing.expectEqualStrings("last-llama-jsonl-v1", request.protocol);
    try std.testing.expectEqual(contract.Operation.inspect_model, request.operation);
    try std.testing.expectEqual(@as(usize, 1), request.expected_modules.len);
}

test "Qwen treatment names and applies the validated no-think directive" {
    try std.testing.expectEqualStrings(" /no_think", contract.Treatment.userPromptSuffix(contract.Treatment.qwen3_no_think_directive).?);
    try std.testing.expectEqualStrings("", contract.Treatment.userPromptSuffix(contract.Treatment.model_template_default).?);
    try std.testing.expect(contract.Treatment.userPromptSuffix("reasoning=none") == null);
}
