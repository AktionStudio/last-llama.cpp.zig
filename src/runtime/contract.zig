const std = @import("std");

pub const Backend = enum {
    cpu,
    cuda,
};

pub const Operation = enum {
    initialize,
    inspect_runtime,
    inspect_model,
    load_model,
    generate,
    cancel,
    unload_model,
    shutdown,
};

pub const Boundary = struct {
    pub const protocol = "last-llama-jsonl-v1";
    pub const conversation = "one-shot-v1";
    pub const max_timeout_ms: u32 = 300_000;

    pub fn executableName(backend: Backend) []const u8 {
        return switch (backend) {
            .cpu => "last-llama-cpu",
            .cuda => "last-llama-cuda",
        };
    }
};

pub const Treatment = struct {
    pub const model_template_default = "model-template-default-v1";
    pub const qwen3_no_think_directive = "qwen3-no-think-directive-v1";

    pub fn userPromptSuffix(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, model_template_default)) return "";
        if (std.mem.eql(u8, name, qwen3_no_think_directive)) return " /no_think";
        return null;
    }
};

pub const ModuleIdentity = struct {
    name: []const u8,
    path: []const u8,
    sha256: []const u8,
};

pub const ExpectedModule = struct {
    name: []const u8,
    sha256: []const u8,
};

pub const RuntimeIdentity = struct {
    implementation: []const u8 = "Last-llama.cpp.zig",
    revision: []const u8,
    llama_cpp_revision: []const u8,
    protocol: []const u8 = Boundary.protocol,
    executable_sha256: []const u8,
    loaded_modules: []const ModuleIdentity,
};

pub const ModelIdentity = struct {
    resolved_path: []const u8,
    sha256: []const u8,
    architecture: []const u8,
    quantization: ?[]const u8,
    context_capability: u32,
};

pub const TemplateIdentity = struct {
    renderer: []const u8 = "llama-chat-apply-template-v1",
    treatment: []const u8,
    source_sha256: []const u8,
    effective_sha256: []const u8,
};

pub const ComputeIdentity = struct {
    requested_backend: []const u8,
    effective_backend: []const u8,
    device_id: []const u8,
    device_description: []const u8,
    device_identity_source: []const u8,
    requested_offload: u32,
    effective_offload: u32,
    total_layers: u32,
};

pub const Attestation = struct {
    runtime: RuntimeIdentity,
    model: ModelIdentity,
    template: TemplateIdentity,
    compute: ComputeIdentity,
};

pub const RuntimeComputeIdentity = struct {
    effective_backend: []const u8,
    device_id: []const u8,
    device_description: []const u8,
    device_identity_source: []const u8,
};

pub const RuntimeInspection = struct {
    format_version: u32 = 1,
    runtime: RuntimeIdentity,
    compute: RuntimeComputeIdentity,
};

pub const Request = struct {
    id: []const u8,
    operation: Operation = .generate,
    protocol: []const u8 = Boundary.protocol,
    prompt: []const u8 = "",
    system: []const u8 = "You are a helpful assistant.",
    context_size: u32 = 512,
    max_tokens: u32 = 32,
    temperature: f32 = 0,
    top_p: f32 = 1,
    seed: u32 = 1,
    timeout_ms: u32 = 10000,
    cancel_after_decodes: ?u32 = null,
    fail_after_decodes: ?u32 = null,
    cancel_after_abort_checks: ?u32 = null,
    grammar: ?[]const u8 = null,
    schema_json: ?[]const u8 = null,
    grammar_candidate: ?[]const u8 = null,
    raw_prompt: bool = false,
    backend: []const u8,
    conversation: []const u8 = Boundary.conversation,
    reasoning: []const u8 = "none",
    treatment: []const u8 = "model-template-default-v1",
    expect_json: bool = false,
    device_id: ?[]const u8 = null,
    device_description: ?[]const u8 = null,
    gpu_layers: u32 = 0,
    expected_runtime_revision: ?[]const u8 = null,
    expected_llama_cpp_revision: ?[]const u8 = null,
    expected_executable_sha256: ?[]const u8 = null,
    expected_model_sha256: ?[]const u8 = null,
    expected_model_architecture: ?[]const u8 = null,
    expected_template_sha256: ?[]const u8 = null,
    expected_modules: []const ExpectedModule = &.{},
};

pub const Result = struct {
    id: []const u8,
    status: []const u8 = "ok",
    finish: []const u8 = "not_started",
    text: []const u8 = "",
    final_text: ?[]const u8 = null,
    output_classification: []const u8 = "not_extracted",
    reasoning_configuration: []const u8 = "none",
    extraction: []const u8 = "whole-final-answer-v1",
    cancellation_granularity: []const u8,
    timeout_semantics: []const u8,
    model_cycle: u32 = 0,
    rendered_prompt: []const u8 = "",
    prompt_tokens: usize = 0,
    generated_tokens: u32 = 0,
    effective_context: u32 = 0,
    grammar_accepts: ?bool = null,
    rejected_token_index: ?usize = null,
    kv_before: i32 = -1,
    kv_after: i32 = -1,
    kv_after_clear: i32 = -1,
    context_destroyed: bool = false,
    sampler_reset: bool = false,
    sampler_destroyed: bool = false,
    decode_calls: u32 = 0,
    abort_checks: u32 = 0,
    elapsed_ms: i64 = 0,
    backend: []const u8,
    attestation: ?Attestation = null,
};
