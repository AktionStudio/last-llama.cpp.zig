# Last-llama.cpp.zig

`Last-llama.cpp.zig` is a standalone Zig-facing integration for a pinned `llama.cpp` runtime. Its Windows treatment builds explicit CPU and CUDA runners, loads an explicitly supplied GGUF, applies a model chat template, supports guarded JSON Schema-to-GBNF or direct GBNF constraints, and emits one JSON result per request. The additive `last-llama-jsonl-v1` attestation reports runtime/module, model, template/treatment, backend/device, and requested/effective offload identity.

Active `src/llama/` is a bounded project-owned interface over the pinned
upstream C API. Historical attribution and licenses remain in
[NOTICE](NOTICE), [LICENSES](LICENSES), and
[EXTRACTION_MANIFEST.md](EXTRACTION_MANIFEST.md).

Owned-interface migration is complete. All active Deins-derived implementation
has been removed and replaced with an independently implemented minimal Zig
interface to upstream llama.cpp. CPU and CUDA parity, lifecycle/cleanup,
schema/contract behavior, attestation, artifact provenance, and exact
token/piece replay have passed with no observed runtime regression. This is a
standalone-runtime statement; downstream consumers retain their own
execution-bound qualification records.

It is not llama.cpp, a model distribution, an inference server, or Ollama. It
contains only the standalone runtime, schema bridge, and reference CLI.

## Quick start

Use PowerShell. Models are always explicit inputs; setup never downloads one.

```powershell
./scripts/setup-dependencies.ps1

./scripts/generate-bindings.ps1 `
  -ZigHeader C:\path\to\zig-0.14.1\zig.exe

./scripts/build-engine.ps1 -Backend cpu
./scripts/build-schema-api.ps1 -Backend cpu

./scripts/run-gate.ps1 `
  -Backend cpu `
  -Case smoke `
  -Model C:\path\to\smollm2-360m-instruct-q8_0.gguf `
  -Zig C:\path\to\zig-0.17.0-dev.1676+c9dc9b798\zig.exe
```

The normal dependency-free check is:

```powershell
zig build test
```

The native runner builds with explicit backend selection:

```powershell
zig build -Dbackend=cpu -Druntime-revision=<this-repository-commit>
zig build -Dbackend=cuda -Druntime-revision=<this-repository-commit>
```

Those build commands require the generated binding, selected CMake engine, and guarded schema bridge described in [docs/REPRODUCTION.md](docs/REPRODUCTION.md). `run-gate.ps1` supplies those paths and adds only the selected engine directories to its child process `PATH`.

Direct `zig build` defaults to the tracked NMake engine and schema directories. When linking a Ninja build directly, pass both `-Dengine-dir=build/engine/<backend>/ninja` and `-Dschema-lib=build/schema/<backend>/ninja/last-llama-schema.lib`; `run-gate.ps1 -Generator Ninja` supplies them automatically.

The tracked build default is NMake, which remains the supported reference path.
`scripts/build-engine.ps1 -Generator Ninja -Jobs <N>` is the explicit parallel
path; both generators use the same pinned llama.cpp source, MSVC, CMake options,
and backend settings. Release v0.1.0 uses fresh Ninja builds at 16 jobs. See
[docs/REPRODUCTION.md](docs/REPRODUCTION.md).

Historical migration checks are summarized in
[docs/CLI_PACKAGE_QUALIFICATION.md](docs/CLI_PACKAGE_QUALIFICATION.md) and
[docs/HISTORICAL_EVIDENCE.md](docs/HISTORICAL_EVIDENCE.md). They are not release
qualification. The exact unsigned v0.1.0 source and extracted distribution are
qualified afresh by the release procedure.

`last-llama-{cpu,cuda}.exe --inspect-runtime` returns machine-readable runtime,
loaded-module, backend, and device identity without loading a model. With a model
path as its only argument, the runner reads one JSON request from stdin. See
[docs/RUNTIME_BOUNDARY.md](docs/RUNTIME_BOUNDARY.md) for the request, attestation,
one-shot lifecycle, and Qwen treatment contract.

## Human-facing reference CLI

The dependency-free `last-llama.exe` target is a convenience client over those
unchanged worker processes:

```powershell
.\.tools\zig\zig.exe build cli
last-llama run qwen --prompt "Explain black holes simply."
```

It provides strict local JSON configuration, model aliases, conservative
CPU/CUDA selection, worker inspection, diagnostics, human-readable generation
output, and faithful `--json` output. It does not link to llama.cpp or add
conversation state. See [docs/CLI.md](docs/CLI.md) and
[examples/last-llama.example.json](examples/last-llama.example.json).

## Initial scope and model fixtures

The tracked compact gates use the available SmolLM2 infrastructure fixture only:

- `smollm2-360m-instruct-q8_0.gguf`
- SHA-256 `48ab3034d0dd401fbc721eb1df3217902fee7dab9078992d66431f09b7750201`

The former Qwen treatment is documented but its model is not present in the frozen lab at extraction time:

- `Qwen3-32B-Q4_K_M.gguf`
- recorded SHA-256 `efd971561896866f0e910cce52761ca77b1b138090c7f15fe284676d57d1f689`
- recorded embedded-template SHA-256 `57f1fd00f0013a2be96aa79b857391f27e23df5b5f847072b524c897e24d0361`

Do not infer Qwen reproduction from a CPU or CUDA smoke using the small model. See [docs/HISTORICAL_EVIDENCE.md](docs/HISTORICAL_EVIDENCE.md) for the preserved lab evidence and its limits.

## Unsigned v0.1.0 release

The v0.1.0 binary distribution is deliberately unsigned. Signing any executable
or DLL changes the artifact and requires repackaging and complete
requalification. Release construction is documented in
[docs/RELEASE.md](docs/RELEASE.md).
