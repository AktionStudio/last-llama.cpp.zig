# Build from source

To try the runtime first, use the [Windows package](../README.md#try-it).
To call it from another program, see [application integration](INTEGRATION.md).
This guide is for compiling the source checkout on Windows x64.

## Prerequisites

Run PowerShell from the repository root. Supply the toolchains yourself;
repository helpers do not install them.

| Tool | Needed for |
| --- | --- |
| Zig `0.17.0-dev.1676+c9dc9b798` | CLI, workers, and Zig tests. |
| Zig `0.14.1` | One-time C-header translation after obtaining the pinned headers. |
| Git | Obtaining/verifying pinned llama.cpp source. |
| MSVC x64 build tools, Windows SDK, CMake, NMake | Native engine and schema bridge. |
| CUDA Toolkit `13.3.1` | CUDA builds only; see the exact treatment in [Dependencies](../DEPENDENCIES.md). |

The two Zig versions serve different purposes; do not use the header helper to
compile the application. Set explicit paths once:

```powershell
$Zig = 'C:\path\to\zig-0.17.0-dev.1676+c9dc9b798\zig.exe'
$ZigHeader = 'C:\path\to\zig-0.14.1\zig.exe'
& $Zig version
```

Build scripts have recorded host defaults for MSVC and CMake paths. If your
installation differs, pass `-VsDevCmd` to both native helpers, and
`-NMakeDirectory` / `-CMakeExecutable` to `build-engine.ps1`. These are paths to
your installed tools, not requirements to reproduce the original directory names.

## Build only the CLI

```powershell
& $Zig build cli
& $Zig build test
& $Zig build cli-test
.\zig-out\bin\last-llama.exe help
```

The CLI is installed at `zig-out\bin\last-llama.exe`. These builds/tests need
no native engine or model. The CLI still needs built or packaged workers and
their DLLs to perform inference.

## Build the CPU runtime

`setup-dependencies.ps1` clones or fetches the pinned llama.cpp revision and
therefore uses the network. It does not download a model.

```powershell
.\scripts\setup-dependencies.ps1
.\scripts\generate-bindings.ps1 -ZigHeader $ZigHeader
.\scripts\build-engine.ps1 -Backend cpu
.\scripts\build-schema-api.ps1 -Backend cpu
& $Zig build -Dbackend=cpu -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast
```

The default build installs both the CLI and `last-llama-cpu.exe` in `zig-out\bin`.
It does not assemble a portable DLL package. For local use, save the following
as `last-llama.dev.json` in the repository root. These paths select the NMake
outputs built above:

```json
{
  "backend": "cpu",
  "workers": {
    "cpu": {
      "path": "zig-out\\bin\\last-llama-cpu.exe",
      "library_dirs": [
        "build\\engine\\cpu\\nmake\\bin",
        "build\\schema\\cpu\\nmake"
      ]
    }
  }
}
```

Then inspect the worker and run your supplied model:

```powershell
.\zig-out\bin\last-llama.exe inspect cpu --config .\last-llama.dev.json
.\zig-out\bin\last-llama.exe run "C:\models\your-model.gguf" --config .\last-llama.dev.json --prompt "Say hello in one sentence." --max-tokens 128 --context-size 4096 --timeout-ms 300000
```

Successful inspection prints runtime/device identity; successful generation
prints an answer. The configuration resolves paths relative to its own location
and changes only the worker's environment. Keep this machine-local file out of
commits. Portable distributions instead use the [package layout](CLI.md#package-layout).

Ordinary local builds report `uncommitted` unless `-Druntime-revision` is supplied.
A commit string alone does not prove a modified working tree matches that commit.
The [release procedure](RELEASE.md) enforces clean, exact source identity for
release artifacts; those restrictions are not imposed by ordinary `zig build`.

## CUDA, Ninja, and validation

For a CUDA build, follow the [CUDA sequence](REPRODUCTION.md#3-cuda-gate), supplying
the Toolkit root and runtime directory explicitly. CUDA builds produce
`zig-out\bin\last-llama-cuda.exe`; keep its native outputs separate from CPU.

NMake remains the reference/default. For Ninja, select the same generator for
engine, schema, and gate commands. Direct Zig builds also need matching
`-Dengine-dir` and `-Dschema-lib` paths; see [generator selection](REPRODUCTION.md#build-generators).

Use [reproduction gates](REPRODUCTION.md) for model smoke, structured-output, and
lifecycle checks. A successful compilation is not an inference qualification.
Packaging, tagging, and release evidence belong to the [maintainer procedure](RELEASE.md).
