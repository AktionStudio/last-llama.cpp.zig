# Reproduction gates

For a first compilation and a working local invocation, start with [Build from source](BUILDING.md). This page covers validation gates after setup. Run commands from the project root. Native outputs stay under ignored `build/`; Zig executables are installed in `zig-out/bin`.

These helpers are for source builders and maintainers, not users of the binary
package. See [Repository scripts and audiences](SCRIPTS.md) before running them.

The command blocks below are PowerShell. PowerShell users should keep the `.\`
prefix for repository scripts; Command Prompt users can invoke them as
`powershell -File scripts\script-name.ps1 ...`.

## Build generators

NMake is the tracked reference default. Ninja is an explicit local-development choice, not a user or release requirement:

```powershell
# Supported reference path.
.\scripts\build-engine.ps1 -Backend cpu -Generator NMake

# Fast local-development path after its equivalence check passes.
.\scripts\build-engine.ps1 -Backend cpu -Generator Ninja -Jobs 16
```

`build-engine.ps1` keeps each generator in its own directory: `build/engine/<backend>/nmake` or `build/engine/<backend>/ninja`. Both use the same pinned llama.cpp revision, MSVC, Release/shared-library configuration, and backend-specific CMake options. The sole build differences are the CMake generator, its make program, and Ninja's requested parallel-job count. NMake is serial, so its accepted `-Jobs` value is recorded but not passed to NMake.

When calling Zig directly for Ninja outputs, pass both `-Dengine-dir=build/engine/<backend>/ninja` and `-Dschema-lib=build/schema/<backend>/ninja/last-llama-schema.lib`, including for `schema-test`. Gate commands supply these paths when given `-Generator Ninja`.

For Ninja, the script checks an explicit `-NinjaExecutable`, then the repository-local `.tools/ninja-1.13.2/ninja.exe`, then `PATH`. The selected binary must report version `1.13.2`; the script does not download or install Ninja. Configure, build, and total wall times are recorded as `build-timing.json` beside the engine output.

The default generator and job counts are intentionally small tracked settings in `scripts/build-default.json`. Passing `-Generator` or `-Jobs` is always explicit and takes precedence. No host profile participates in normal builds.

## 1. Bootstrap pinned source and binding

```powershell
.\scripts\setup-dependencies.ps1
.\scripts\generate-bindings.ps1 -ZigHeader C:\path\to\zig-0.14.1\zig.exe
```

The binding helper requires Zig `0.14.1`. The runners use the separately supplied Zig `0.17.0-dev.1676+c9dc9b798` toolchain.

## 2. CPU gates

Set `$Zig` to the pinned runner compiler path as shown in [Build from source](BUILDING.md). The examples below use NMake. Add `-Generator Ninja` to the schema and gate commands when validating an explicit Ninja build.

```powershell
.\scripts\build-engine.ps1 -Backend cpu -Generator NMake
.\scripts\build-schema-api.ps1 -Backend cpu -Generator NMake
& $Zig build schema-test -Dbackend=cpu
.\scripts\run-gate.ps1 -Backend cpu -Generator NMake -Case smoke -Model C:\path\to\model.gguf -Zig C:\path\to\zig-0.17.0-dev.1676+c9dc9b798\zig.exe
.\scripts\run-gate.ps1 -Backend cpu -Generator NMake -Case structured -Model C:\path\to\model.gguf -Zig C:\path\to\zig-0.17.0-dev.1676+c9dc9b798\zig.exe
.\scripts\run-gate.ps1 -Backend cpu -Generator NMake -Case lifecycle -Cycles 3 -Model C:\path\to\model.gguf -Zig C:\path\to\zig-0.17.0-dev.1676+c9dc9b798\zig.exe
```

The smoke gate proves decoding. The structured gate proves a guarded JSON Schema conversion and constrained final. The lifecycle gate repeats model cycles and covers final extraction, direct grammar probes, cancellation cleanup, and injected-failure cleanup.

## 3. CUDA gate

```powershell
.\scripts\build-engine.ps1 -Backend cuda -Generator NMake -CudaToolkitRoot C:\path\to\cuda-13.3.1
.\scripts\build-schema-api.ps1 -Backend cuda -Generator NMake
& $Zig build schema-test -Dbackend=cuda
.\scripts\run-gate.ps1 -Backend cuda -Generator NMake -Case smoke -Model C:\path\to\model.gguf -Zig C:\path\to\zig-0.17.0-dev.1676+c9dc9b798\zig.exe -CudaRuntimeBin C:\path\to\cuda-13.3.1\bin\x64 -GpuLayers 1
```

CUDA success requires the standalone runtime's current `RUNTIME_CUDA_SELECTED` marker plus a JSONL attestation reporting requested and effective CUDA backend, positive matching GPU offload, and no unexpected CPU fallback. A missing CUDA device must fail before model evaluation.

## 4. Release builds

NMake remains the reference/default. The v0.1.0 release procedure uses fresh
Ninja 1.13.2 CPU and CUDA builds at 16 jobs and records their exact settings.
The prior generator-equivalence study is historical and is not repeated during
release qualification. See [RELEASE.md](RELEASE.md).
