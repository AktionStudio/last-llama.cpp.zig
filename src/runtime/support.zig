const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("runtime_build_options");
const contract = @import("runtime_contract");
const llama = @import("runtime_llama");
const c = llama.c;

const W = std.os.windows;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?W.HMODULE;
extern "kernel32" fn GetModuleFileNameW(module: ?W.HMODULE, path: [*]u16, size: u32) callconv(.winapi) u32;

pub const runtime_revision = build_options.runtime_revision;
pub const llama_cpp_revision = build_options.llama_cpp_revision;

pub const Selection = struct {
    devices: [2]c.ggml_backend_dev_t = .{ null, null },
    device_id: []const u8,
    description: []const u8,
    identity_source: []const u8,
};

pub const Offload = struct {
    observations: u32 = 0,
    valid: bool = false,
    layers: u32 = 0,
    total: u32 = 0,

    pub fn callback(_: c.ggml_log_level, text: [*c]const u8, raw: ?*anyopaque) callconv(.c) void {
        const self: *Offload = @ptrCast(@alignCast(raw.?));
        const line = std.mem.span(text);
        self.observe(line);
        std.debug.print("{s}", .{line});
    }

    fn observe(self: *Offload, line: []const u8) void {
        const start = std.mem.indexOf(u8, line, "offloaded ") orelse return;
        self.observations += 1;
        self.valid = false;
        const rest = line[start + 10 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return;
        const suffix = std.mem.indexOf(u8, rest, " layers to GPU") orelse return;
        if (slash >= suffix) return;
        self.layers = std.fmt.parseInt(u32, rest[0..slash], 10) catch return;
        self.total = std.fmt.parseInt(u32, rest[slash + 1 .. suffix], 10) catch return;
        self.valid = true;
    }

    pub fn verify(self: Offload, backend: contract.Backend, requested: u32, total: u32) !u32 {
        return switch (backend) {
            .cpu => if (self.observations == 0 and requested == 0) 0 else error.UnexpectedGpuOffload,
            .cuda => if (requested <= total and self.observations == 1 and self.valid and self.layers == requested and self.total == total) self.layers else error.OffloadMismatch,
        };
    }
};

pub fn sha256File(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [1024 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositionalAll(io, &buffer, offset);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        offset += count;
        if (count != buffer.len) break;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(a, "{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

fn sha256Parts(a: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| hasher.update(part);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(a, "{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

pub fn resolveDevice(req: contract.Request, backend: contract.Backend) !Selection {
    if (!std.mem.eql(u8, req.backend, @tagName(backend))) return error.UnsupportedBackend;
    if (backend == .cpu and (req.gpu_layers != 0 or req.device_id != null or req.device_description != null)) return error.CpuOffloadConfiguration;
    if (backend == .cuda and req.gpu_layers == 0) return error.InvalidGpuLayers;
    var found: ?Selection = null;
    for (0..c.ggml_backend_dev_count()) |index| {
        const device = c.ggml_backend_dev_get(index);
        const kind = c.ggml_backend_dev_type(device);
        if (backend == .cpu and kind != c.GGML_BACKEND_DEVICE_TYPE_CPU) continue;
        if (backend == .cuda and kind != c.GGML_BACKEND_DEVICE_TYPE_GPU) continue;
        var props: c.ggml_backend_dev_props = undefined;
        c.ggml_backend_dev_get_props(device, &props);
        const name = if (props.name == null) return error.MissingDeviceName else std.mem.span(props.name);
        const description = if (props.description == null) return error.MissingDeviceDescription else std.mem.span(props.description);
        if (backend == .cuda and !std.mem.startsWith(u8, name, "CUDA")) continue;
        const id = if (props.device_id == null) name else std.mem.span(props.device_id);
        const source = if (props.device_id == null) "ggml-backend-name" else "ggml-device-id";
        if (req.device_id) |expected| if (!std.mem.eql(u8, expected, id)) continue;
        if (req.device_description) |expected| if (!std.mem.eql(u8, expected, description)) return error.DeviceDescriptionMismatch;
        if (found != null) return error.AmbiguousDeviceIdentity;
        found = .{
            .devices = if (backend == .cuda) .{ device, null } else .{ null, null },
            .device_id = id,
            .description = description,
            .identity_source = source,
        };
    }
    return found orelse error.RequestedDeviceUnavailable;
}

fn moduleIdentity(a: std.mem.Allocator, io: std.Io, name: []const u8) !?contract.ModuleIdentity {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const wide_name = try std.unicode.utf8ToUtf16LeAllocZ(a, name);
    defer a.free(wide_name);
    const handle = GetModuleHandleW(wide_name.ptr) orelse return null;
    const path = try modulePath(a, handle);
    return .{ .name = try a.dupe(u8, name), .path = path, .sha256 = try sha256File(a, io, path) };
}

fn modulePath(a: std.mem.Allocator, handle: ?W.HMODULE) ![]u8 {
    var wide_path: [32768]u16 = undefined;
    const count = GetModuleFileNameW(handle, &wide_path, wide_path.len);
    if (count == 0 or count == wide_path.len) return error.ModulePathUnavailable;
    return std.unicode.utf16LeToUtf8Alloc(a, wide_path[0..count]);
}

pub fn loadedModules(a: std.mem.Allocator, io: std.Io, backend: contract.Backend) ![]const contract.ModuleIdentity {
    const names = [_][]const u8{ "llama.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll", "ggml-cuda.dll", "last-llama-schema.dll" };
    var modules = std.array_list.Managed(contract.ModuleIdentity).init(a);
    for (names) |name| {
        if (backend == .cpu and std.mem.eql(u8, name, "ggml-cuda.dll")) continue;
        if (try moduleIdentity(a, io, name)) |identity| try modules.append(identity);
    }
    return modules.toOwnedSlice();
}

pub fn inspectRuntime(a: std.mem.Allocator, io: std.Io, backend: contract.Backend, selection: Selection) !contract.RuntimeInspection {
    const executable_path = try modulePath(a, null);
    return .{
        .runtime = .{
            .revision = runtime_revision,
            .llama_cpp_revision = llama_cpp_revision,
            .executable_sha256 = try sha256File(a, io, executable_path),
            .loaded_modules = try loadedModules(a, io, backend),
        },
        .compute = .{
            .effective_backend = @tagName(backend),
            .device_id = selection.device_id,
            .device_description = selection.description,
            .device_identity_source = selection.identity_source,
        },
    };
}

fn modelMetadata(a: std.mem.Allocator, model: *llama.Model, key: [:0]const u8) !?[]const u8 {
    var buffer: [4096]u8 = undefined;
    const value = (try model.metaValStr(key, &buffer)) orelse return null;
    return try a.dupe(u8, value);
}

pub const Template = struct {
    rendered_prompt: []const u8,
    identity: contract.TemplateIdentity,
};

pub fn renderTemplate(a: std.mem.Allocator, model: *llama.Model, req: contract.Request) !Template {
    if (req.raw_prompt) {
        if (!std.mem.eql(u8, req.treatment, "raw-prompt-v1")) return error.TreatmentMismatch;
        const hash = try sha256Parts(a, &.{ "raw-prompt-v1", req.prompt });
        return .{ .rendered_prompt = req.prompt, .identity = .{ .renderer = "raw-prompt-v1", .treatment = req.treatment, .source_sha256 = hash, .effective_sha256 = hash } };
    }
    const raw_template = c.llama_model_chat_template(model.cCPtr(), null) orelse return error.MissingTemplate;
    const template = std.mem.span(raw_template);
    const source_hash = try sha256Parts(a, &.{template});
    if (req.expected_template_sha256) |expected| if (!std.mem.eql(u8, expected, source_hash)) return error.TemplateIdentityMismatch;
    const suffix = contract.Treatment.userPromptSuffix(req.treatment) orelse return error.UnsupportedTreatment;
    const user = if (suffix.len == 0) req.prompt else try std.fmt.allocPrint(a, "{s}{s}", .{ req.prompt, suffix });
    const prompt = try a.dupeSentinel(u8, user, 0);
    const system = try a.dupeSentinel(u8, req.system, 0);
    const messages = [_]c.llama_chat_message{ .{ .role = "system", .content = system.ptr }, .{ .role = "user", .content = prompt.ptr } };
    const needed = c.llama_chat_apply_template(raw_template, &messages, messages.len, true, null, 0);
    if (needed < 0) return error.UnsupportedTemplate;
    const rendered = try a.alloc(u8, @intCast(needed));
    const actual = c.llama_chat_apply_template(raw_template, &messages, messages.len, true, rendered.ptr, @intCast(rendered.len));
    if (actual != needed) return error.TemplateSizeMismatch;
    const effective_hash = try sha256Parts(a, &.{ template, "\x00", req.treatment });
    return .{ .rendered_prompt = rendered, .identity = .{ .treatment = req.treatment, .source_sha256 = source_hash, .effective_sha256 = effective_hash } };
}

pub fn attest(
    a: std.mem.Allocator,
    io: std.Io,
    model_path: []const u8,
    model: *llama.Model,
    req: contract.Request,
    backend: contract.Backend,
    selection: Selection,
    template: contract.TemplateIdentity,
    effective_offload: u32,
) !contract.Attestation {
    if (!std.mem.eql(u8, req.protocol, contract.Boundary.protocol)) return error.UnsupportedProtocol;
    if (!std.mem.eql(u8, req.backend, @tagName(backend))) return error.UnsupportedBackend;
    if (req.gpu_layers != effective_offload) return error.OffloadMismatch;
    if (req.device_id) |expected| if (!std.mem.eql(u8, expected, selection.device_id)) return error.DeviceIdentityMismatch;
    if (req.device_description) |expected| if (!std.mem.eql(u8, expected, selection.description)) return error.DeviceDescriptionMismatch;
    if (req.expected_runtime_revision) |expected| if (!std.mem.eql(u8, expected, runtime_revision)) return error.RuntimeRevisionMismatch;
    if (req.expected_llama_cpp_revision) |expected| if (!std.mem.eql(u8, expected, llama_cpp_revision)) return error.LlamaRevisionMismatch;
    const executable_path = try std.process.executablePathAlloc(io, a);
    const executable_sha = try sha256File(a, io, executable_path);
    if (req.expected_executable_sha256) |expected| if (!std.mem.eql(u8, expected, executable_sha)) return error.ExecutableIdentityMismatch;
    const resolved_model_path = try std.Io.Dir.cwd().realPathFileAlloc(io, model_path, a);
    const model_sha = try sha256File(a, io, resolved_model_path);
    if (req.expected_model_sha256) |expected| if (!std.mem.eql(u8, expected, model_sha)) return error.ModelIdentityMismatch;
    const architecture = (try modelMetadata(a, model, "general.architecture")) orelse return error.MissingModelArchitecture;
    if (req.expected_model_architecture) |expected| if (!std.mem.eql(u8, expected, architecture)) return error.ModelArchitectureMismatch;
    if (std.mem.eql(u8, req.treatment, "qwen3-no-think-directive-v1") and !std.mem.eql(u8, architecture, "qwen3")) return error.TreatmentArchitectureMismatch;
    const modules = try loadedModules(a, io, backend);
    for (req.expected_modules) |expected| {
        const observed = for (modules) |module| {
            if (std.ascii.eqlIgnoreCase(module.name, expected.name)) break module;
        } else return error.ExpectedModuleNotLoaded;
        if (!std.mem.eql(u8, observed.sha256, expected.sha256)) return error.ModuleIdentityMismatch;
    }
    return .{
        .runtime = .{
            .revision = runtime_revision,
            .llama_cpp_revision = llama_cpp_revision,
            .executable_sha256 = executable_sha,
            .loaded_modules = modules,
        },
        .model = .{
            .resolved_path = resolved_model_path,
            .sha256 = model_sha,
            .architecture = architecture,
            .quantization = try modelMetadata(a, model, "general.file_type"),
            .context_capability = @intCast(model.nCtxTrain()),
        },
        .template = template,
        .compute = .{
            .requested_backend = req.backend,
            .effective_backend = @tagName(backend),
            .device_id = selection.device_id,
            .device_description = selection.description,
            .device_identity_source = selection.identity_source,
            .requested_offload = req.gpu_layers,
            .effective_offload = effective_offload,
            .total_layers = @intCast(model.nLayer() + 1),
        },
    };
}

pub fn validateTreatmentForModel(req: contract.Request, architecture: []const u8) !void {
    if (std.mem.eql(u8, req.treatment, "qwen3-no-think-directive-v1") and !std.mem.eql(u8, architecture, "qwen3")) return error.TreatmentModelMismatch;
}

test "effective template identity binds treatment" {
    const a = std.testing.allocator;
    const first = try sha256Parts(a, &.{ "template", "\x00", "model-template-default-v1" });
    defer a.free(first);
    const second = try sha256Parts(a, &.{ "template", "\x00", "qwen3-no-think-directive-v1" });
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}
