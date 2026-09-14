# Reference CLI

`last-llama.exe` is a human-facing, one-shot client for the existing
`last-llama-jsonl-v1` CPU and CUDA worker processes. It does not link to
llama.cpp, load models itself, render templates, tokenize, sample, maintain a
conversation, or reinterpret runtime results.

## Commands

```powershell
last-llama help
last-llama version
last-llama doctor
last-llama models
last-llama models show qwen
last-llama describe qwen
last-llama inspect cuda
last-llama run qwen --prompt "Say hello"
last-llama run qwen --prompt "Say hello" --json
last-llama run D:\models\model.gguf --prompt-file prompt.txt
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

```json
{
  "default_model": "qwen",
  "backend": "auto",
  "system": "You are a helpful assistant.",
  "generation": {
    "max_tokens": 256,
    "temperature": 0.7,
    "top_p": 0.95,
    "seed": 1,
    "context_size": 4096,
    "timeout_ms": 300000
  },
  "workers": {
    "cpu": {
      "path": "last-llama-cpu.exe",
      "library_dirs": ["runtime\\cpu"]
    },
    "cuda": {
      "path": "last-llama-cuda.exe",
      "library_dirs": ["runtime\\cuda"]
    }
  },
  "models": {
    "qwen": {
      "path": "models\\Qwen3-32B-Q4_K_M.gguf",
      "backend": "cuda",
      "gpu_layers": 33,
      "system": "You are a helpful assistant.",
      "description": "Local Qwen model",
      "generation": {
        "temperature": 0.6,
        "max_tokens": 512
      }
    }
  }
}
```

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

CPU and CUDA builds have backend-specific DLLs with overlapping filenames, so
their qualified module sets must not be flattened together:

```text
last-llama.exe
last-llama-cpu.exe
last-llama-cuda.exe
last-llama.json
models/
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

Use the repository's pinned Zig `0.17.0-dev.1676+c9dc9b798` toolchain:

```powershell
.\.tools\zig\zig.exe build cli
.\.tools\zig\zig.exe build cli-test
.\.tools\zig\zig.exe build fake-worker
./scripts/test-cli.ps1
```

The unit and fake-worker tests require no GGUF inference. A real smoke remains
separate and explicit:

```powershell
last-llama run smol --backend cpu --prompt "Say hello" --max-tokens 16 --timeout-ms 60000
last-llama run smol --backend cuda --gpu-layers 1 --prompt "Say hello" --max-tokens 16 --timeout-ms 60000
```

The CUDA value `1` above is deliberately limited to smoke diagnostics; it is
not an implicit normal-use default.
