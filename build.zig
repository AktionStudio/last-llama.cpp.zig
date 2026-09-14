const std = @import("std");

const Backend = enum {
    cpu,
    cuda,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option(Backend, "backend", "Native engine backend: cpu or cuda") orelse .cpu;
    const engine_dir = b.option([]const u8, "engine-dir", "CMake output directory for the selected pinned engine") orelse b.fmt("build/engine/{s}/nmake", .{@tagName(backend)});
    const bindings_path = b.option([]const u8, "bindings", "Generated Zig translation of external/llama.cpp/include/llama.h") orelse "build/generated/llama.h.zig";
    const runtime_revision = b.option([]const u8, "runtime-revision", "Git revision of the Last-llama.cpp.zig source used for this runner") orelse "uncommitted";
    const llama_cpp_revision = b.option([]const u8, "llama-cpp-revision", "Pinned llama.cpp Git revision linked into this runner") orelse "d4abd573f6a360201799072384ceec6170fdb60c";

    const bindings = b.createModule(.{
        .root_source_file = .{ .cwd_relative = bindings_path },
        .target = target,
        .optimize = optimize,
    });
    const llama_c = b.createModule(.{
        .root_source_file = b.path("src/llama/c.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "llama.h", .module = bindings },
        },
    });
    const runtime_llama = b.createModule(.{
        .root_source_file = b.path("src/llama/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "llama_c", .module = llama_c },
        },
    });
    const schema = b.createModule(.{
        .root_source_file = b.path("src/schema/schema.zig"),
        .target = target,
        .optimize = optimize,
    });
    const contract = b.createModule(.{
        .root_source_file = b.path("src/runtime/contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_config = b.createModule(.{
        .root_source_file = b.path("src/cli/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "runtime_contract", .module = contract }},
    });
    const cli_worker = b.createModule(.{
        .root_source_file = b.path("src/cli/worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cli_protocol = b.createModule(.{
        .root_source_file = b.path("src/cli/protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime_contract", .module = contract },
            .{ .name = "cli_config", .module = cli_config },
        },
    });
    const runtime_options = b.addOptions();
    runtime_options.addOption([]const u8, "runtime_revision", runtime_revision);
    runtime_options.addOption([]const u8, "llama_cpp_revision", llama_cpp_revision);
    const support = b.createModule(.{
        .root_source_file = b.path("src/runtime/support.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "runtime_llama", .module = runtime_llama },
            .{ .name = "runtime_contract", .module = contract },
        },
    });
    support.addOptions("runtime_build_options", runtime_options);
    const runner = b.createModule(.{
        .root_source_file = b.path(if (backend == .cpu) "src/runtime/cpu_runner.zig" else "src/runtime/cuda_runner.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "runtime_llama", .module = runtime_llama },
            .{ .name = "schema", .module = schema },
            .{ .name = "runtime_contract", .module = contract },
            .{ .name = "runtime_support", .module = support },
        },
    });
    const schema_library = b.option([]const u8, "schema-lib", "Guarded JSON Schema bridge import library") orelse b.fmt("build/schema/{s}/nmake/last-llama-schema.lib", .{@tagName(backend)});
    for ([_][]const u8{ "src/llama.lib", "ggml/src/ggml.lib", "ggml/src/ggml-base.lib" }) |relative| {
        runner.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ engine_dir, relative }) });
    }
    runner.addObjectFile(.{ .cwd_relative = schema_library });
    const executable = b.addExecutable(.{
        .name = b.fmt("last-llama-{s}", .{@tagName(backend)}),
        .root_module = runner,
    });
    b.installArtifact(executable);

    const cli = b.addExecutable(.{
        .name = "last-llama",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime_contract", .module = contract },
                .{ .name = "cli_config", .module = cli_config },
                .{ .name = "cli_worker", .module = cli_worker },
                .{ .name = "cli_protocol", .module = cli_protocol },
            },
        }),
    });
    b.installArtifact(cli);
    const cli_step = b.step("cli", "Build the standalone human-facing CLI");
    cli_step.dependOn(&b.addInstallArtifact(cli, .{}).step);

    const token_replay = b.addExecutable(.{
        .name = "token-replay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/token_replay.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "runtime_llama", .module = runtime_llama }},
        }),
    });
    for ([_][]const u8{ "src/llama.lib", "ggml/src/ggml.lib", "ggml/src/ggml-base.lib" }) |relative| {
        token_replay.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ engine_dir, relative }) });
    }
    const token_replay_run = b.addRunArtifact(token_replay);
    if (b.option([]const u8, "token-replay-model", "GGUF model for the token replay step")) |model| token_replay_run.addArg(model);
    const token_replay_step = b.step("token-replay", "Replay frozen token and piece snapshots");
    token_replay_step.dependOn(&token_replay_run.step);

    const contract_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/contract_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "runtime_contract",
                    .module = b.createModule(.{
                        .root_source_file = b.path("src/runtime/contract.zig"),
                        .target = target,
                        .optimize = optimize,
                    }),
                },
            },
        }),
    });
    const test_step = b.step("test", "Run dependency-free runtime-boundary tests");
    test_step.dependOn(&b.addRunArtifact(contract_tests).step);

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/config.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "runtime_contract", .module = contract }},
        }),
    });
    const cli_test_step = b.step("cli-test", "Run dependency-free CLI tests");
    cli_test_step.dependOn(&b.addRunArtifact(cli_tests).step);
    const worker_tests = b.addTest(.{ .root_module = cli_worker });
    cli_test_step.dependOn(&b.addRunArtifact(worker_tests).step);
    const protocol_tests = b.addTest(.{ .root_module = cli_protocol });
    cli_test_step.dependOn(&b.addRunArtifact(protocol_tests).step);
    const cli_main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime_contract", .module = contract },
                .{ .name = "cli_config", .module = cli_config },
                .{ .name = "cli_worker", .module = cli_worker },
                .{ .name = "cli_protocol", .module = cli_protocol },
            },
        }),
    });
    cli_test_step.dependOn(&b.addRunArtifact(cli_main_tests).step);

    const fake_worker = b.addExecutable(.{
        .name = "fake-worker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fake_worker.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "runtime_contract", .module = contract }},
        }),
    });
    const fake_worker_step = b.step("fake-worker", "Build the CLI test worker");
    fake_worker_step.dependOn(&b.addInstallArtifact(fake_worker, .{}).step);

    const schema_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/schema_bridge_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "schema", .module = schema },
            },
        }),
    });
    schema_tests.root_module.addObjectFile(.{ .cwd_relative = schema_library });
    const schema_test_step = b.step("schema-test", "Exercise accepted and rejected guarded JSON Schema conversions");
    schema_test_step.dependOn(&b.addRunArtifact(schema_tests).step);
}
