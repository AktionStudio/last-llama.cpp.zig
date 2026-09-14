# Last-llama.cpp.zig

Last-llama.cpp.zig is a standalone Windows inference runtime and command-line
tool built in Zig around `llama.cpp`. It runs user-supplied GGUF models on CPU
or NVIDIA CUDA and gives applications a stable JSON-lines worker interface for
local text generation, structured output, lifecycle control, and provenance.

It began as a missing piece in a larger Zig project: I needed more control over
local models than third-party model services could give me. An existing Zig
wrapper showed that the bridge was possible; from that starting point, the
project grew into a narrow, independently maintained runtime with an explicit
ownership boundary. [Read the story behind the project](docs/STORY.md).

Models are supplied separately, and this project never downloads one without
you choosing it.

| I want to... | Start here |
| --- | --- |
| Try my first prompt | [Try it](#try-it) |
| Learn why this project exists | [Project story](docs/STORY.md) |
| Use the runtime from an application | [Application guide](docs/INTEGRATION.md) |
| Compile the project myself | [Build from source](docs/BUILDING.md) |

## Try it

The Windows package is the easiest way to begin. You need Windows x64 and a GGUF
model. The native workers also use the Microsoft Visual C++/OpenMP runtime,
which is already installed on many Windows PCs. The `doctor` command below will
check your setup. If the Microsoft runtime is missing, use the official
[Visual C++ x64 Redistributable](https://aka.ms/vc14/vc_redist.x64.exe).

CUDA is optional. It needs a supported NVIDIA GPU and a suitable display driver,
available from the official [NVIDIA driver page](https://www.nvidia.com/drivers).
You do not need Zig, CMake, or the CUDA Toolkit to use the package.

1. Download the Windows x64 binary ZIP from the [releases page](https://github.com/AktionStudio/last-llama.cpp.zig/releases).
2. Extract the complete ZIP to a directory of your choice.
3. Choose a GGUF model using the [model guide](models/README.md).
4. Open PowerShell in the extracted directory and replace the example model path below with yours.

```powershell
.\last-llama.exe doctor
.\last-llama.exe run "C:\models\your-model.gguf" --backend cpu --prompt "Say hello in one sentence." --max-tokens 128 --context-size 4096 --timeout-ms 300000
```

If the CPU checks pass, you are ready to run on CPU. CUDA diagnostics do not
prevent CPU use when the CPU worker is healthy. A successful `run` prints the
model's answer directly in the terminal.

The example above uses a model path, so you do not need to create a configuration
file before trying your first prompt. If something does not work, the
[CLI troubleshooting guide](docs/CLI.md#troubleshooting) explains the common
messages and what to check next.

### Make everyday commands shorter

Once your first prompt works, you can give models friendly names such as
`qwen3-8b`. Save the [configuration example](last-llama.json.example) beside
`last-llama.exe` as `last-llama.json`, then edit the model path.

The updated v0.1.0 Windows ZIP includes `last-llama.json.example` and a
`models\README.md` guide. Actual GGUF model files are still supplied separately.

```powershell
Copy-Item .\last-llama.json.example .\last-llama.json
notepad .\last-llama.json
.\last-llama.exe models show qwen3-8b
.\last-llama.exe run qwen3-8b --prompt "Explain black holes simply."
```

Relative model paths are resolved from the directory containing the configuration
file. See the [CLI guide](docs/CLI.md) for all settings and Command Prompt
examples.

If you want to use CUDA, choose a positive offload count that is appropriate for
your model. The [backend selection guide](docs/CLI.md#defaults-and-backend-selection)
explains CUDA, CPU, and the conservative `auto` behavior.

## Use it in your application

The simplest integration is to call `last-llama.exe` with `--json`. Applications
that need the full request contract can launch a CPU or CUDA worker directly.
Both routes use the same local inference runtime.

You can:

- Generate text from a local GGUF model using CPU or NVIDIA CUDA.
- Control sampling, context size, token limits, and generation timeouts.
- Request structured JSON with the supported JSON Schema guard.
- Receive machine-readable runtime, model, template, and backend information.
- Inspect the runtime without loading a model.

The [application guide](docs/INTEGRATION.md) includes complete Python examples
for the CLI and direct workers. The [runtime reference](docs/RUNTIME_BOUNDARY.md)
documents the full request and response contract.

This is a one-shot local runtime rather than an inference server: applications
manage conversation history, scheduling, and orchestration themselves.

## Build from source

Prefer to compile it yourself? The [source-build guide](docs/BUILDING.md) walks
through the required tools, a CLI-only build, a complete CPU build, CUDA, and
the available validation gates.

## More information

This README is focused on getting started. Detailed engineering, release, and
evidence material lives in the dedicated references below.

| Reference | What it covers |
| --- | --- |
| [Story](docs/STORY.md) | Why the project began and how its interface became independently maintained. |
| [Models](models/README.md) | Model sources, configuration, memory considerations, and recorded evidence. |
| [CLI guide](docs/CLI.md) | Commands, settings, package layout, and troubleshooting. |
| [Runtime reference](docs/RUNTIME_BOUNDARY.md) | Worker protocol, lifecycle, constraints, and attestation. |
| [Dependencies](DEPENDENCIES.md) | Pinned source and build toolchains. |
| [Reproduction gates](docs/REPRODUCTION.md) | Smoke, structured-output, and lifecycle checks. |
| [Package evidence](docs/CLI_PACKAGE_QUALIFICATION.md) | Recorded package results and their limits. |
| [Release procedure](docs/RELEASE.md) | Packaging, signing status, and release qualification. |
| [Licenses and attribution](NOTICE) | Project and third-party notices. |

The current v0.1.0 Windows package is unsigned. See the
[release procedure](docs/RELEASE.md) for the exact release status and evidence
boundaries.
