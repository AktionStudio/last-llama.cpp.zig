const std = @import("std");
const contract = @import("runtime_contract");
const config = @import("cli_config");
const worker = @import("cli_worker");
const protocol = @import("cli_protocol");

const version = "0.1.0";

const common_runtime_dlls = [_][]const u8{ "llama.dll", "llama-common.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll", "last-llama-schema.dll" };
const cuda_runtime_dlls = [_][]const u8{ "ggml-cuda.dll", "cublas64_13.dll", "cublasLt64_13.dll" };
const optional_cuda_dlls = [_][]const u8{"cudart64_13.dll"};
const all_runtime_dlls = common_runtime_dlls ++ cuda_runtime_dlls ++ optional_cuda_dlls;

const Common = struct {
    config_path: ?[]const u8 = null,
    json: bool = false,
    verbose: bool = false,
};

const RunOptions = struct {
    common: Common = .{},
    model: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    prompt_file: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    overrides: config.Overrides = .{},
};

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        if (err != error.Reported) std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 1 or isHelp(args[1])) return printHelp(init.io);
    if (args.len == 3 and isHelp(args[2])) return printHelp(init.io);
    if (std.mem.eql(u8, args[1], "version")) {
        if (args.len != 2) return report("version accepts no options", .{});
        return printVersion(init.io);
    }
    const exe_dir = try std.process.executableDirPathAlloc(init.io, a);

    if (std.mem.eql(u8, args[1], "run")) return runCommand(init, exe_dir, try parseRun(args[2..]));
    if (std.mem.eql(u8, args[1], "models")) {
        if (args.len >= 3 and std.mem.eql(u8, args[2], "show")) return describeCommand(init, exe_dir, args[3..]);
        return modelsCommand(init, exe_dir, try parseCommon(args[2..], false));
    }
    if (std.mem.eql(u8, args[1], "describe")) return describeCommand(init, exe_dir, args[2..]);
    if (std.mem.eql(u8, args[1], "doctor")) return doctorCommand(init, exe_dir, try parseCommon(args[2..], false));
    if (std.mem.eql(u8, args[1], "inspect")) return inspectCommand(init, exe_dir, args[2..]);
    std.debug.print("error: unknown command '{s}'; run 'last-llama help'\n", .{args[1]});
    return error.Reported;
}

fn runCommand(init: std.process.Init, exe_dir: []const u8, options: RunOptions) !void {
    const a = init.arena.allocator();
    const loaded = try config.discover(a, init.io, exe_dir, options.common.config_path);
    var resolved = try config.resolveModel(a, loaded, options.model, options.overrides);
    try config.validateResolved(resolved);
    if (!config.fileExists(init.io, resolved.model_path)) {
        std.debug.print("error: model '{s}' is neither a configured alias with an existing file nor an existing model path (resolved '{s}')\n", .{ resolved.selector, resolved.model_path });
        return error.Reported;
    }
    resolved.backend = try selectBackend(init, exe_dir, loaded, resolved);
    if (resolved.backend == .cpu) resolved.gpu_layers = null;

    const prompt = try readPrompt(a, init.io, options);
    const schema_json = if (options.schema) |schema| try readSchema(a, init.io, schema) else null;
    const request = protocol.makeRequest(resolved, prompt, schema_json);
    const encoded = try protocol.encodeRequest(a, request);
    if (encoded.len > 8 * 1024 * 1024) return report("serialized request exceeds the worker's 8 MiB input limit", .{});
    const selected_worker = try config.resolveWorker(a, exe_dir, loaded, resolved.backend);
    const worker_path = selected_worker.path.?;
    if (!config.fileExists(init.io, worker_path)) return report("{s} worker is missing: {s}", .{ @tagName(resolved.backend), worker_path });
    if (try workerDirectoryContamination(a, init.io, selected_worker)) |name| return report("worker directory contains '{s}' outside the selected library directories; keep package DLLs under runtime\\{s}", .{ name, @tagName(resolved.backend) });

    if (options.common.verbose) {
        std.debug.print("model: {s}\nbackend: {s}\ngpu_layers: {s}\nworker: {s}\nsettings: context={d} max_tokens={d} temperature={d} top_p={d} seed={d} timeout_ms={d}\n", .{
            resolved.model_path,
            @tagName(resolved.backend),
            if (resolved.gpu_layers) |n| try std.fmt.allocPrint(a, "{d}", .{n}) else "n/a",
            worker_path,
            resolved.generation.context_size,
            resolved.generation.max_tokens,
            resolved.generation.temperature,
            resolved.generation.top_p,
            resolved.generation.seed,
            resolved.generation.timeout_ms,
        });
    }

    const capture = worker.invoke(a, init.io, init.environ_map, worker_path, &.{resolved.model_path}, selected_worker.library_dirs, encoded) catch |err| {
        std.debug.print("error: failed to launch {s} worker '{s}': {s}\n", .{ @tagName(resolved.backend), worker_path, @errorName(err) });
        return error.Reported;
    };
    defer capture.deinit(a);
    if (!worker.successful(capture.term)) return workerFailure(capture);

    var response = protocol.parseOne(a, capture.stdout) catch |err| {
        std.debug.print("error: malformed worker output: {s}\n", .{@errorName(err)});
        if (capture.stderr.len != 0) std.debug.print("worker diagnostics:\n{s}", .{capture.stderr});
        return error.Reported;
    };
    defer response.deinit();
    if (options.common.json) {
        try writeLine(init.io, response.line);
    } else if (std.mem.eql(u8, response.string("status") orelse "", "ok")) {
        try writeHumanResult(init.io, response);
    }
    if (options.common.verbose) std.debug.print("finish: {s}; generated_tokens: {d}; elapsed_ms: {d}\n", .{ response.string("finish") orelse "unknown", response.integer("generated_tokens") orelse 0, response.integer("elapsed_ms") orelse 0 });
    if (!std.mem.eql(u8, response.string("status") orelse "", "ok")) return report("runtime returned status '{s}' (finish '{s}')", .{ response.string("status") orelse "missing", response.string("finish") orelse "missing" });
    if (response.string("final_text") == null) return report("runtime did not return a final answer (finish '{s}', classification '{s}')", .{ response.string("finish") orelse "missing", response.string("output_classification") orelse "missing" });
}

fn modelsCommand(init: std.process.Init, exe_dir: []const u8, common: Common) !void {
    const a = init.arena.allocator();
    const loaded = try config.discover(a, init.io, exe_dir, common.config_path);
    var it = loaded.value.models.map.iterator();
    if (loaded.value.models.map.count() == 0) return std.Io.File.stdout().writeStreamingAll(init.io, "No configured model aliases.\n");
    while (it.next()) |item| {
        const path = try resolveConfigPath(a, loaded.base_dir, item.value_ptr.path);
        const backend = if (item.value_ptr.backend) |b| @tagName(b) else "default";
        const line = try std.fmt.allocPrint(a, "{s}\t{s}\t{s}\n", .{ item.key_ptr.*, path, backend });
        try std.Io.File.stdout().writeStreamingAll(init.io, line);
    }
}

fn describeCommand(init: std.process.Init, exe_dir: []const u8, args: []const []const u8) !void {
    var common: Common = .{};
    var model: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config")) common.config_path = try nextValue(args, &i, "--config") else if (std.mem.startsWith(u8, args[i], "-")) return unknownOption(args[i]) else if (model == null) model = args[i] else return report("describe accepts one model", .{});
    }
    const a = init.arena.allocator();
    const loaded = try config.discover(a, init.io, exe_dir, common.config_path);
    var resolved = try config.resolveModel(a, loaded, model, .{});
    try config.validateResolved(resolved);
    const configured_backend = resolved.backend;
    resolved.backend = try selectBackend(init, exe_dir, loaded, resolved);
    if (resolved.backend == .cpu) resolved.gpu_layers = null;
    const text = try std.fmt.allocPrint(
        a,
        "model: {s}\nalias: {s}\npath: {s}\nexists: {s}\nbackend: {s}{s}\ngpu_layers: {s}\nsystem: {s}\nmax_tokens: {d}\ntemperature: {d}\ntop_p: {d}\nseed: {d}\ncontext_size: {d}\ntimeout_ms: {d}\nconfig: {s}\n",
        .{ resolved.selector, resolved.alias orelse "direct path", resolved.model_path, yesNo(config.fileExists(init.io, resolved.model_path)), @tagName(resolved.backend), if (configured_backend == .auto) " (resolved from auto)" else "", if (resolved.gpu_layers) |n| try std.fmt.allocPrint(a, "{d}", .{n}) else "not configured", resolved.system, resolved.generation.max_tokens, resolved.generation.temperature, resolved.generation.top_p, resolved.generation.seed, resolved.generation.context_size, resolved.generation.timeout_ms, loaded.source_path orelse "built-in defaults" },
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, text);
}

fn inspectCommand(init: std.process.Init, exe_dir: []const u8, args: []const []const u8) !void {
    var common: Common = .{};
    var backend: ?config.Backend = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config")) common.config_path = try nextValue(args, &i, "--config") else if (std.mem.eql(u8, args[i], "--json")) common.json = true else if (std.mem.startsWith(u8, args[i], "-")) return unknownOption(args[i]) else if (backend == null) backend = try parseBackend(args[i], false) else return report("inspect accepts one backend", .{});
    }
    const selected = backend orelse return report("inspect requires cpu or cuda", .{});
    const loaded = try config.discover(init.arena.allocator(), init.io, exe_dir, common.config_path);
    var response = try inspectWorker(init, exe_dir, loaded, selected);
    defer response.deinit();
    if (common.json) return writeLine(init.io, response.line);
    const compute = response.parsed.value.object.get("compute") orelse return report("inspection response is missing compute", .{});
    const runtime = response.parsed.value.object.get("runtime") orelse return report("inspection response is missing runtime", .{});
    if (compute != .object or runtime != .object) return report("inspection response has invalid structure", .{});
    const text = try std.fmt.allocPrint(init.arena.allocator(), "backend: {s}\ndevice: {s}\ndevice_id: {s}\nprotocol: {s}\nruntime_revision: {s}\nllama_cpp_revision: {s}\n", .{
        jsonString(compute.object, "effective_backend") orelse "missing",
        jsonString(compute.object, "device_description") orelse "missing",
        jsonString(compute.object, "device_id") orelse "missing",
        jsonString(runtime.object, "protocol") orelse "missing",
        jsonString(runtime.object, "revision") orelse "missing",
        jsonString(runtime.object, "llama_cpp_revision") orelse "missing",
    });
    try std.Io.File.stdout().writeStreamingAll(init.io, text);
}

fn doctorCommand(init: std.process.Init, exe_dir: []const u8, common: Common) !void {
    const a = init.arena.allocator();
    var failures: u32 = 0;
    const loaded = config.discover(a, init.io, exe_dir, common.config_path) catch {
        try doctorLine(init.io, "FAIL", "config", "discovery or parsing failed");
        return error.Reported;
    };
    try doctorLine(init.io, "PASS", "config", loaded.source_path orelse "built-in defaults");

    var model_it = loaded.value.models.map.iterator();
    while (model_it.next()) |item| {
        const path = try resolveConfigPath(a, loaded.base_dir, item.value_ptr.path);
        if (config.fileExists(init.io, path)) try doctorLine(init.io, "PASS", item.key_ptr.*, path) else {
            failures += 1;
            try doctorLine(init.io, "FAIL", item.key_ptr.*, "model file missing");
        }
    }

    for ([_]config.Backend{ .cpu, .cuda }) |backend| {
        const selected_worker = try config.resolveWorker(a, exe_dir, loaded, backend);
        if (!config.fileExists(init.io, selected_worker.path.?)) {
            if (backend == .cpu) failures += 1;
            try doctorLine(init.io, if (backend == .cpu) "FAIL" else "WARN", @tagName(backend), "worker missing");
            continue;
        }
        if (try workerDirectoryContamination(a, init.io, selected_worker)) |name| {
            failures += 1;
            try doctorLine(init.io, "FAIL", @tagName(backend), try std.fmt.allocPrint(a, "worker directory contains unselected runtime DLL: {s}", .{name}));
            continue;
        }
        try checkWorkerLibraries(init, selected_worker, backend, &failures);
        var inspection = inspectWorker(init, exe_dir, loaded, backend) catch |err| {
            failures += 1;
            try doctorLine(init.io, "FAIL", @tagName(backend), try std.fmt.allocPrint(a, "worker inspection failed ({s}); check backend DLLs and device availability", .{@errorName(err)}));
            continue;
        };
        defer inspection.deinit();
        try doctorLine(init.io, "PASS", @tagName(backend), "worker launch and runtime inspection");
        try checkInspectionModules(init, inspection, selected_worker, backend, &failures);
    }
    if (failures != 0) return report("doctor found {d} failure(s)", .{failures});
}

fn checkWorkerLibraries(init: std.process.Init, selected_worker: config.Worker, backend: config.Backend, failures: *u32) !void {
    for (common_runtime_dlls) |name| try checkRequiredLibrary(init, selected_worker, backend, name, failures);
    if (backend == .cuda) {
        for (cuda_runtime_dlls) |name| try checkRequiredLibrary(init, selected_worker, backend, name, failures);
        for (optional_cuda_dlls) |name| if (try findLibrary(init.arena.allocator(), init.io, selected_worker, name)) |path| {
            try doctorLine(init.io, "WARN", @tagName(backend), try std.fmt.allocPrint(init.arena.allocator(), "non-required DLL present: {s} ({s})", .{ name, path }));
        };
    }
}

fn checkRequiredLibrary(init: std.process.Init, selected_worker: config.Worker, backend: config.Backend, name: []const u8, failures: *u32) !void {
    if (try findLibrary(init.arena.allocator(), init.io, selected_worker, name)) |path| {
        try doctorLine(init.io, "PASS", @tagName(backend), try std.fmt.allocPrint(init.arena.allocator(), "required DLL present: {s} ({s})", .{ name, path }));
    } else {
        failures.* += 1;
        try doctorLine(init.io, "FAIL", @tagName(backend), try std.fmt.allocPrint(init.arena.allocator(), "required DLL missing: {s}", .{name}));
    }
}

fn findLibrary(a: std.mem.Allocator, io: std.Io, selected_worker: config.Worker, name: []const u8) !?[]const u8 {
    for (selected_worker.library_dirs) |dir| {
        const candidate = try std.fs.path.join(a, &.{ dir, name });
        if (config.fileExists(io, candidate)) return candidate;
    }
    return null;
}

fn checkInspectionModules(init: std.process.Init, response: protocol.Response, selected_worker: config.Worker, backend: config.Backend, failures: *u32) !void {
    const runtime = response.parsed.value.object.get("runtime") orelse return;
    if (runtime != .object) return;
    const modules = runtime.object.get("loaded_modules") orelse return;
    if (modules != .array) return;
    const expected: []const []const u8 = if (backend == .cuda) &.{ "llama.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll", "ggml-cuda.dll", "last-llama-schema.dll" } else &.{ "llama.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll", "last-llama-schema.dll" };
    for (expected) |name| {
        var found = false;
        var allowed_origin = false;
        for (modules.array.items) |module| if (module == .object) {
            if (jsonString(module.object, "name")) |actual| {
                if (std.ascii.eqlIgnoreCase(actual, name)) {
                    found = true;
                    if (jsonString(module.object, "path")) |path| allowed_origin = moduleOriginAllowed(path, selected_worker.library_dirs);
                }
            }
        };
        if (!found) {
            failures.* += 1;
            try doctorLine(init.io, "FAIL", @tagName(backend), try std.fmt.allocPrint(init.arena.allocator(), "required loaded module missing: {s}", .{name}));
        } else if (!allowed_origin) {
            failures.* += 1;
            try doctorLine(init.io, "FAIL", @tagName(backend), try std.fmt.allocPrint(init.arena.allocator(), "loaded module is outside selected library directories: {s}", .{name}));
        } else {
            try doctorLine(init.io, "PASS", @tagName(backend), try std.fmt.allocPrint(init.arena.allocator(), "loaded module origin: {s}", .{name}));
        }
    }
}

fn moduleOriginAllowed(path: []const u8, library_dirs: []const []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return false;
    for (library_dirs) |dir| if (std.ascii.eqlIgnoreCase(parent, dir)) return true;
    return false;
}

fn workerDirectoryContamination(a: std.mem.Allocator, io: std.Io, selected_worker: config.Worker) !?[]const u8 {
    const worker_dir = std.fs.path.dirname(selected_worker.path.?) orelse ".";
    for (selected_worker.library_dirs) |dir| if (std.ascii.eqlIgnoreCase(worker_dir, dir)) return null;
    for (all_runtime_dlls) |name| {
        const candidate = try std.fs.path.join(a, &.{ worker_dir, name });
        if (config.fileExists(io, candidate)) return name;
    }
    return null;
}

fn inspectWorker(init: std.process.Init, exe_dir: []const u8, loaded: config.Loaded, backend: config.Backend) !protocol.Response {
    const a = init.arena.allocator();
    const selected_worker = try config.resolveWorker(a, exe_dir, loaded, backend);
    if (!config.fileExists(init.io, selected_worker.path.?)) return error.WorkerMissing;
    if (try workerDirectoryContamination(a, init.io, selected_worker) != null) return error.WorkerDirectoryContaminated;
    const capture = try worker.invoke(a, init.io, init.environ_map, selected_worker.path.?, &.{"--inspect-runtime"}, selected_worker.library_dirs, null);
    defer capture.deinit(a);
    if (!worker.successful(capture.term)) return error.WorkerInspectionFailed;
    var response = try protocol.parseInspection(a, capture.stdout);
    errdefer response.deinit();
    const compute = response.parsed.value.object.get("compute") orelse return error.InvalidWorkerInspection;
    const runtime = response.parsed.value.object.get("runtime") orelse return error.InvalidWorkerInspection;
    if (compute != .object or runtime != .object) return error.InvalidWorkerInspection;
    const effective = jsonString(compute.object, "effective_backend") orelse return error.InvalidWorkerInspection;
    if (!std.mem.eql(u8, effective, @tagName(backend))) return error.InspectionBackendMismatch;
    const observed_protocol = jsonString(runtime.object, "protocol") orelse return error.InvalidWorkerInspection;
    if (!std.mem.eql(u8, observed_protocol, contract.Boundary.protocol)) return error.InspectionProtocolMismatch;
    return response;
}

fn selectBackend(init: std.process.Init, exe_dir: []const u8, loaded: config.Loaded, resolved: config.Resolved) !config.Backend {
    const cpu_worker = try config.resolveWorker(init.arena.allocator(), exe_dir, loaded, .cpu);
    const cpu_present = config.fileExists(init.io, cpu_worker.path.?);
    if (resolved.backend == .cpu) {
        if (resolved.gpu_layers != null) return report("gpu_layers cannot be used with backend cpu", .{});
        return config.chooseBackend(.cpu, false, false, cpu_present) catch return report("CPU worker is missing", .{});
    }
    if (resolved.backend == .cuda) {
        if (resolved.gpu_layers == null) return report("CUDA requires --gpu-layers or configured gpu_layers", .{});
        var inspection = inspectWorker(init, exe_dir, loaded, .cuda) catch |err| {
            std.debug.print("error: explicitly requested CUDA is unavailable: {s}\n", .{@errorName(err)});
            return error.Reported;
        };
        inspection.deinit();
        return config.chooseBackend(.cuda, true, true, cpu_present);
    }
    var cuda_usable = false;
    if (resolved.gpu_layers != null) {
        if (inspectWorker(init, exe_dir, loaded, .cuda)) |value| {
            var inspection = value;
            inspection.deinit();
            cuda_usable = true;
        } else |_| {}
    }
    return config.chooseBackend(.auto, resolved.gpu_layers != null, cuda_usable, cpu_present) catch return report("auto backend could not find a usable CUDA worker or a CPU worker", .{});
}

fn readPrompt(a: std.mem.Allocator, io: std.Io, options: RunOptions) ![]const u8 {
    if (options.prompt != null and options.prompt_file != null) return report("use exactly one of --prompt or --prompt-file", .{});
    if (options.prompt) |prompt| return prompt;
    const path = options.prompt_file orelse return report("run requires --prompt or --prompt-file", .{});
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(8 * 1024 * 1024)) catch |err| {
        std.debug.print("error: cannot read prompt file '{s}': {s}\n", .{ path, @errorName(err) });
        return error.Reported;
    };
}

fn readSchema(a: std.mem.Allocator, io: std.Io, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const inline_json = trimmed.len != 0 and trimmed[0] == '{';
    const raw = if (!inline_json and config.fileExists(io, value)) std.Io.Dir.cwd().readFileAlloc(io, value, a, .limited(1024 * 1024)) catch |err| {
        std.debug.print("error: cannot read schema '{s}': {s}\n", .{ value, @errorName(err) });
        return error.Reported;
    } else value;
    var parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch return report("--schema must be an existing JSON file or valid inline JSON", .{});
    defer parsed.deinit();
    if (parsed.value != .object) return report("--schema JSON root must be an object", .{});
    return if (raw.ptr == value.ptr) value else a.dupe(u8, raw);
}

fn parseRun(args: []const []const u8) !RunOptions {
    var out: RunOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config")) out.common.config_path = try nextValue(args, &i, arg) else if (std.mem.eql(u8, arg, "--prompt")) out.prompt = try nextValue(args, &i, arg) else if (std.mem.eql(u8, arg, "--prompt-file")) out.prompt_file = try nextValue(args, &i, arg) else if (std.mem.eql(u8, arg, "--schema")) out.schema = try nextValue(args, &i, arg) else if (std.mem.eql(u8, arg, "--backend")) out.overrides.backend = try parseBackend(try nextValue(args, &i, arg), true) else if (std.mem.eql(u8, arg, "--gpu-layers")) out.overrides.gpu_layers = try parseU32(try nextValue(args, &i, arg), arg) else if (std.mem.eql(u8, arg, "--system")) out.overrides.system = try nextValue(args, &i, arg) else if (std.mem.eql(u8, arg, "--max-tokens")) out.overrides.generation.max_tokens = try parseU32(try nextValue(args, &i, arg), arg) else if (std.mem.eql(u8, arg, "--temperature")) out.overrides.generation.temperature = try parseF32(try nextValue(args, &i, arg), arg) else if (std.mem.eql(u8, arg, "--top-p")) out.overrides.generation.top_p = try parseF32(try nextValue(args, &i, arg), arg) else if (std.mem.eql(u8, arg, "--seed")) out.overrides.generation.seed = try parseU32(try nextValue(args, &i, arg), arg) else if (std.mem.eql(u8, arg, "--context-size")) out.overrides.generation.context_size = try parseU32(try nextValue(args, &i, arg), arg) else if (std.mem.eql(u8, arg, "--timeout-ms")) out.overrides.generation.timeout_ms = try parseU32(try nextValue(args, &i, arg), arg) else if (std.mem.eql(u8, arg, "--json")) out.common.json = true else if (std.mem.eql(u8, arg, "--verbose")) out.common.verbose = true else if (std.mem.startsWith(u8, arg, "-")) return unknownOption(arg) else if (out.model == null) out.model = arg else return report("run accepts at most one model alias or path", .{});
    }
    return out;
}

fn parseCommon(args: []const []const u8, allow_json: bool) !Common {
    var out: Common = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config")) out.config_path = try nextValue(args, &i, args[i]) else if (allow_json and std.mem.eql(u8, args[i], "--json")) out.json = true else return unknownOption(args[i]);
    }
    return out;
}

fn nextValue(args: []const []const u8, i: *usize, option: []const u8) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return report("{s} requires a value", .{option});
    return args[i.*];
}

fn parseBackend(value: []const u8, allow_auto: bool) !config.Backend {
    if (std.mem.eql(u8, value, "cpu")) return .cpu;
    if (std.mem.eql(u8, value, "cuda")) return .cuda;
    if (allow_auto and std.mem.eql(u8, value, "auto")) return .auto;
    return report("invalid backend '{s}'", .{value});
}

fn parseU32(value: []const u8, option: []const u8) !u32 {
    return std.fmt.parseInt(u32, value, 10) catch return report("{s} requires an unsigned integer", .{option});
}

fn parseF32(value: []const u8, option: []const u8) !f32 {
    return std.fmt.parseFloat(f32, value) catch return report("{s} requires a number", .{option});
}

fn writeHumanResult(io: std.Io, response: protocol.Response) !void {
    const text = response.string("final_text") orelse response.string("text") orelse "";
    try writeLine(io, text);
}

fn writeLine(io: std.Io, value: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, value);
    if (value.len == 0 or value[value.len - 1] != '\n') try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn workerFailure(capture: worker.Capture) error{Reported} {
    switch (capture.term) {
        .exited => |code| std.debug.print("error: worker exited with code {d}\n", .{code}),
        else => std.debug.print("error: worker terminated abnormally\n", .{}),
    }
    if (capture.stderr.len != 0) std.debug.print("worker diagnostics:\n{s}", .{capture.stderr});
    return error.Reported;
}

fn doctorLine(io: std.Io, status: []const u8, name: []const u8, detail: []const u8) !void {
    var buffer: [2048]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{s}\t{s}\t{s}\n", .{ status, name, detail });
    try std.Io.File.stdout().writeStreamingAll(io, line);
}

fn jsonString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn resolveConfigPath(a: std.mem.Allocator, base: []const u8, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return a.dupe(u8, path);
    return std.fs.path.resolve(a, &.{ base, path });
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn unknownOption(option: []const u8) error{Reported} {
    return report("unknown option '{s}'", .{option});
}

fn report(comptime message: []const u8, args: anytype) error{Reported} {
    std.debug.print("error: " ++ message ++ "\n", args);
    return error.Reported;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn printVersion(io: std.Io) !void {
    var buffer: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "last-llama {s}\nprotocol {s}\n", .{ version, contract.Boundary.protocol });
    try std.Io.File.stdout().writeStreamingAll(io, text);
}

fn printHelp(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\last-llama - reference client for the qualified one-shot runtime
        \\
        \\Usage:
        \\  last-llama run [MODEL] (--prompt TEXT | --prompt-file PATH) [OPTIONS]
        \\  last-llama models [--config PATH]
        \\  last-llama models show MODEL [--config PATH]
        \\  last-llama describe MODEL [--config PATH]
        \\  last-llama doctor [--config PATH]
        \\  last-llama inspect cpu|cuda [--config PATH] [--json]
        \\  last-llama version
        \\  last-llama help
        \\
        \\Run options:
        \\  --backend auto|cpu|cuda  --gpu-layers N  --system TEXT
        \\  --max-tokens N  --temperature N  --top-p N  --seed N
        \\  --context-size N  --timeout-ms N  --schema FILE-OR-JSON
        \\  --json  --verbose  --config PATH
        \\
        \\CUDA requires --gpu-layers or configured gpu_layers.
        \\
    );
}

test "run parser accepts model and generation overrides" {
    const args = [_][]const u8{ "qwen", "--prompt", "hello", "--backend", "cuda", "--gpu-layers", "33", "--temperature", "0.2" };
    const parsed = try parseRun(&args);
    try std.testing.expectEqualStrings("qwen", parsed.model.?);
    try std.testing.expectEqual(config.Backend.cuda, parsed.overrides.backend.?);
    try std.testing.expectEqual(@as(u32, 33), parsed.overrides.gpu_layers.?);
    try std.testing.expectEqual(@as(f32, 0.2), parsed.overrides.generation.temperature.?);
}

test "explicit CUDA and auto are distinct parser values" {
    try std.testing.expectEqual(config.Backend.cuda, try parseBackend("cuda", true));
    try std.testing.expectEqual(config.Backend.auto, try parseBackend("auto", true));
}
