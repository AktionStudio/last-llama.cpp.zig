# CLI usage and reference

`last-llama.exe` is a human-facing, one-shot client for the existing
`last-llama-jsonl-v1` CPU and CUDA worker processes. It does not link to
llama.cpp, load models itself, render templates, tokenize, sample, maintain a
conversation, or reinterpret runtime results.

Start with the [package quick start](../README.md#try-it), then use this reference for everyday settings. For programmatic use, see [application integration](INTEGRATION.md).

## Commands

PowerShell requires `.\` for an executable in the current directory:

```powershell
.\last-llama.exe help
.\last-llama.exe version
.\last-llama.exe doctor
.\last-llama.exe models
.\last-llama.exe models show qwen3-8b
.\last-llama.exe describe qwen3-8b
.\last-llama.exe inspect cuda
.\last-llama.exe run qwen3-8b --prompt "Say hello"
.\last-llama.exe run qwen3-8b --prompt "Say hello" --json
.\last-llama.exe run D:\models\model.gguf --prompt-file .\prompt.txt
```

The equivalent Command Prompt syntax uses the bare executable name:

```bat
last-llama.exe doctor
last-llama.exe models
last-llama.exe models show qwen3-8b
last-llama.exe run qwen3-8b --prompt "Say hello"
last-llama.exe run qwen3-8b --backend cpu --prompt "Say hello"
last-llama.exe run qwen3-8b --backend cuda --gpu-layers 37 --prompt "Say hello"
```

`models show MODEL` and `describe MODEL` report the same fully resolved model
settings without loading the model.

`run` accepts `--backend auto|cpu|cuda`, `--gpu-layers`, `--system`,
`--max-tokens`, `--temperature`, `--top-p`, `--seed`, `--context-size`,
`--timeout-ms`, `--schema`, `--json`, `--verbose`, and `--config`.

`--prompt` and `--prompt-file` are mutually exclusive. `--schema` accepts an
existing JSON file or inline JSON. The CLI validates the JSON and sends it as
the runtime's existing `schema_json` field with `expect_json=true`; guarded
schema conversion remains runtime-owned.

Normal output is only generated text. `--verbose` adds the selected model,
backend, worker, effective generation settings, finish reason, token count,
and runtime-reported generation time on stderr. It does not print the prompt.
`--json` writes the single validated runtime result row. Multiple rows,
malformed output, nonzero worker exits, non-`ok` runtime status, and incomplete
results fail explicitly.

## Configuration

Configuration discovery is:

1. `--config <path>`;
2. `last-llama.json` beside `last-llama.exe`;
3. built-in defaults.

All relative model, worker, and worker-library paths are resolved relative to
the configuration file. The parser is strict: unknown or duplicate fields,
wrong types, invalid enum values, and invalid numeric ranges are errors.

The updated v0.1.0 Windows package includes
[`last-llama.json.example`](../last-llama.json.example) beside the executables
and includes the model guide at `models\README.md`. Copy the example as
`last-llama.json`, place the named GGUF in
`models\`, and edit the filename or settings as needed. The tracked copy at
[`examples/last-llama.example.json`](../examples/last-llama.example.json) is
kept byte-identical for readers who browse examples first. JSON comments are
not supported.

The example configures Qwen3-8B Q4_K_M but leaves `gpu_layers` unset. It will
therefore work with CPU under `auto`; select CUDA explicitly with
`--backend cuda --gpu-layers 37`. See [the model guide](../models/README.md) for
download, filename, licensing, capacity, and evidence details.

`workers` is optional. By default, worker executables are located beside the
CLI and the selected child's `PATH` contains only `runtime\cpu` or
`runtime\cuda` beside the CLI. Development overrides can name an explicit
worker and one or more `library_dirs`; those directories, in configured order,
become the complete child `PATH`. The parent process environment is unchanged.

Resolution precedence is CLI, model, global configuration, then built-in
default. A positional value matching a `models` key is an alias; every other
value is treated as a filesystem path. With no positional value,
`default_model` is used.

## Defaults and backend selection

The CLI preserves the defaults already declared by the runtime request
contract:

| Setting | Default |
| --- | ---: |
| system | `You are a helpful assistant.` |
| max tokens | 32 |
| temperature | 0 |
| top-p | 1 |
| seed | 1 |
| context size | 512 |
| timeout | 10000 ms |

The CLI-only backend default is `auto`. CPU always sends `gpu_layers=0`.
CUDA has no implicit GPU-layer default: an effective positive `gpu_layers`
must come from the CLI, model configuration, or global configuration.

`auto` selects CUDA only when GPU layers are configured, the CUDA worker is
present, and `--inspect-runtime` succeeds with a usable CUDA device. Otherwise
it selects an available CPU worker. Explicit CUDA never falls back to CPU.

## Package layout

The updated v0.1.0 Windows package uses the layout below. It includes
`last-llama.json.example` and `models/README.md`; a live `last-llama.json` and
GGUF model files are user-created.

CPU and CUDA builds have backend-specific DLLs with overlapping filenames, so
their qualified module sets must not be flattened together:

```text
last-llama.exe
last-llama-cpu.exe
last-llama-cuda.exe
last-llama.json.example
models/
  README.md
runtime/
  cpu/
    llama.dll
    ggml.dll
    ggml-base.dll
    ggml-cpu.dll
    llama-common.dll
    last-llama-schema.dll
  cuda/
    llama.dll
    ggml.dll
    ggml-base.dll
    ggml-cpu.dll
    ggml-cuda.dll
    llama-common.dll
    last-llama-schema.dll
    cublas64_13.dll
    cublasLt64_13.dll
```

`llama-common.dll` is required because `last-llama-schema.dll` imports it
directly. Keep the backend-matched copy in each runtime directory; do not put a
shared copy beside the root-level workers. The current qualified
`ggml-cuda.dll` imports `cublas64_13.dll`, which imports `cublasLt64_13.dll`.
It does not dynamically import `cudart64_13.dll`, so that DLL is not part of
the release runtime package.

Windows system DLLs, the installed MSVC/OpenMP redistributable, and the NVIDIA
display driver are machine prerequisites rather than package DLLs. The CUDA
Toolkit headers, compiler, import libraries, and `cudart64_13.dll` are build
prerequisites or unrelated toolkit files, not end-user requirements for this
qualified binary closure.

`doctor` checks every required package DLL, rejects runtime DLLs accidentally
placed beside an otherwise isolated worker, launches each available worker's
authoritative inspection operation, and verifies that attested modules came
from the selected backend directories. A missing required DLL is `FAIL`; an
unavailable optional CUDA worker is `WARN`. If the non-required
`cudart64_13.dll` is present, doctor warns that it should be omitted. Doctor
never writes configuration, downloads models, or changes the parent process
environment.

## Building and testing

For a complete build walkthrough and executable locations, see [Build from source](BUILDING.md).

Use the repository's pinned Zig `0.17.0-dev.1676+c9dc9b798` toolchain:

```powershell
.\.tools\zig\zig.exe build cli
.\.tools\zig\zig.exe build cli-test
.\.tools\zig\zig.exe build fake-worker
.\scripts\test-cli.ps1
```

The unit and fake-worker tests require no GGUF inference. A real smoke remains
separate and explicit:

```powershell
.\last-llama.exe run "C:\models\smollm2-360m-instruct-q8_0.gguf" --backend cpu --prompt "Say hello" --max-tokens 16 --timeout-ms 60000
.\last-llama.exe run "C:\models\smollm2-360m-instruct-q8_0.gguf" --backend cuda --gpu-layers 1 --prompt "Say hello" --max-tokens 16 --timeout-ms 60000
```

For Command Prompt, remove the leading `.\` from `last-llama.exe`; the
PowerShell scripts in this repository are still invoked with `powershell -File`
or from PowerShell.

The CUDA value `1` above is deliberately limited to smoke diagnostics; it is
not an implicit normal-use default.

Possible model discovery and configuration-writing commands are planning only;
they are not accepted CLI syntax. See [Future planning](FUTURE.md).

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| Command is not found in PowerShell | Run from the extracted directory and use `.\last-llama.exe`. |
| Missing model or alias | Run `models show ALIAS`, check the configuration-relative path, or pass an absolute GGUF path. `models` lists configured aliases; it does not discover files. |
| Missing DLL or worker | Run `doctor`; restore the complete package layout and required machine runtimes. Keep CPU/CUDA DLLs separate. |
| CUDA inspection or execution fails | Check the driver/device and explicit offload settings. Use `--backend cpu` if you intend CPU execution. |
| No final answer / token limit | Inspect diagnostics, shorten the prompt or increase the token budget. A partial `text` value is not a completed `final_text`. |
| Generation timeout | Set `--timeout-ms` explicitly, up to 300000; model loading is outside the generation budget. |

For schema usage and result handling, continue to [application integration](INTEGRATION.md).
