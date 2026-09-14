# Dependencies

These versions define the recorded build treatment. Start with [Build from source](docs/BUILDING.md) for the command sequence. Dependency upgrades require fresh validation; the recorded host below is evidence, not a general hardware support matrix.

| Component | Required treatment | Acquisition |
| --- | --- | --- |
| llama.cpp | `d4abd573f6a360201799072384ceec6170fdb60c` | `scripts/setup-dependencies.ps1` clones `https://github.com/ggml-org/llama.cpp.git` into ignored `external/llama.cpp` and verifies detached `HEAD` |
| Historical wrapper provenance | `Deins/llama.cpp.zig` `f776b9aca51cc90f7ddba9c2a0874862aebf08f5` | No checkout is needed at build time; attribution/license and archive/tag are retained, but no active wrapper source is imported |
| Zig compile tool | `0.17.0-dev.1676+c9dc9b798` | User supplies the compiler path explicitly to the gate script |
| Zig header helper | `0.14.1` | User supplies the compiler path explicitly to `generate-bindings.ps1`; this reproduces the recorded C-header translation treatment |
| Host toolchain | x86_64 Windows MSVC via `vcvars64.bat` | Required by CMake/NMake and the schema bridge |
| CMake generator | NMake Makefiles is the reference/default; Ninja 1.13.2 is the explicit v0.1.0 release path | Selected explicitly by `build-engine.ps1`; the project does not download either tool |
| CUDA path | CUDA 13.3.1 redistribution, NVCC 13.3.73, architecture 86, CUDA graphs off | Required only for `-Backend cuda`; its root is always explicit and never downloaded by this project |

The extraction host reported CMake `4.4.0`, MSVC `19.51.36256`, an RTX 3090 (24 GiB), and NVIDIA driver `591.86`. These are observed environment facts, not portable support claims. The lab’s known CUDA recipe used the same driver family, CUDA `13.3.1`, NVCC `13.3.73`, `-DCMAKE_CUDA_ARCHITECTURES=86`, and `-DGGML_CUDA_GRAPHS=OFF`.

## Generated and untracked content

Never add these to Git:

- `external/llama.cpp/` and its nested Git metadata
- `models/*.gguf`
- `build/engine/`, `build/schema/`, and `build/generated/llama.h.zig`
- DLLs, import libraries, object files, executables, debug symbols, CMake trees, Zig caches, or runtime logs

`src/llama/c.zig` imports `llama.h` as a generated module; `src/llama/runtime.zig` is the narrow active C-facing surface. The generated binding is intentionally outside `src/`; its known-working treatment is recorded instead of committing a stale header translation.

## Schema bridge dependency

`src/schema/schema_api.cpp` is built against the selected engine’s `common` converter and vendored nlohmann JSON. It admits a deliberately bounded subset of JSON Schema and fails closed on unsupported keyword intersections, open objects, duplicate keys, unbounded complexity, and converter branches known to drop sibling constraints. It does not claim complete JSON Schema support.
