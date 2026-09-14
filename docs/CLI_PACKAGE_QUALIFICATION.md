# Historical CLI/package migration qualification — 2026-09-13

Historical status: **PASS** for the CLI/package boundary at the recorded
migration snapshot. This is not v0.1.0 release qualification and is not evidence
for any subsequently built executable or package.

## Dependency audit

The final-qualified binaries were inspected with MSVC `dumpbin /dependents`.
Their preserved `--inspect-runtime` module attestations and fresh package-like
inspections were checked as independent runtime evidence.

| Component | Non-system runtime dependencies |
| --- | --- |
| `last-llama.exe` | none |
| `last-llama-cpu.exe` | `ggml.dll`, `ggml-base.dll`, `llama.dll`, `last-llama-schema.dll` |
| `last-llama-cuda.exe` | `ggml.dll`, `ggml-base.dll`, `llama.dll`, `last-llama-schema.dll` |
| `last-llama-schema.dll` | `llama-common.dll` |
| `llama-common.dll` | `llama.dll`, `ggml.dll`, `ggml-base.dll` |
| CPU `ggml.dll` | `ggml-cpu.dll`, `ggml-base.dll` |
| CUDA `ggml.dll` | `ggml-cpu.dll`, `ggml-cuda.dll`, `ggml-base.dll` |
| `ggml-cpu.dll` | `ggml-base.dll` |
| `ggml-cuda.dll` | `ggml-base.dll`, `cublas64_13.dll` |
| `cublas64_13.dll` | `cublasLt64_13.dll` |

`last-llama-schema.dll` proves that a backend-matched `llama-common.dll` is
required. It is duplicated into `runtime\cpu` and `runtime\cuda` so each
backend remains self-contained and no shared search directory is introduced.

`ggml-cuda.dll` does not import `cudart64_13.dll`. The qualified CUDA CMake
cache selects `cudart_static.lib`, and a fresh CUDA inspect and inference both
passed from a directory with no cudart DLL. The CUDA runtime linkage is
therefore static for this qualified build. `cublas64_13.dll` and its direct
dependency `cublasLt64_13.dll` remain required package files.

Windows API-set DLLs, `KERNEL32`, `ntdll`, the MSVC/OpenMP redistributable, and
the NVIDIA display-driver `nvcuda.dll` are machine/runtime prerequisites and
are not package files. CUDA headers, NVCC, import libraries, and other Toolkit
development files are build prerequisites only.

## Focused qualification

An unzipped package-like tree was assembled under ignored `build/` storage:

```text
last-llama.exe
last-llama-cpu.exe
last-llama-cuda.exe
last-llama.json
runtime/cpu/   # matched CPU llama, GGML, schema, and llama-common DLLs
runtime/cuda/  # matched CUDA set plus cuBLAS and cuBLASLt; no cudart DLL
```

Results:

- CLI build and unit tests: PASS.
- Existing runtime contract tests: PASS.
- Fake-worker package integration: PASS, including dependency classification,
  backend PATH isolation, explicit overrides, alias/direct-path behavior,
  precedence, and explicit-CUDA no-fallback behavior.
- `doctor`: PASS for both workers and every required DLL/module origin.
- Development worker/library overrides: PASS; the Toolkit directory produced
  only the expected non-failing warning for its extra `cudart64_13.dll`.
- `inspect cpu`: PASS; all five attested modules originated in `runtime\cpu`.
- CPU alias inference: PASS, `status=ok`, `finish=eog`, `final_text=Hello.`.
- CPU direct-path inference: PASS with the same result and isolated origins.
- `inspect cuda`: PASS; device `NVIDIA GeForce RTX 3090`, PCI id
  `0000:0b:00.0`; all six attested modules originated in `runtime\cuda`.
- CUDA inference with explicit `--gpu-layers 1`: PASS, `status=ok`,
  `finish=eog`, `final_text=Hello.`, requested/effective offload `1/1`.
- `git diff --check`: PASS.

## Runtime qualification inheritance

The immutable final-qualified workers were copied, not rebuilt:

| Worker | SHA-256 before and after |
| --- | --- |
| CPU | `43bb5ffeab22e2e20a1cd39d094beb124892dcc251b1c7f9ff4a8e27d9f29bd1` |
| CUDA | `94afca1350bd8bcac28308810a7acb3023c96aa0bfbe9c1dc709b750d62a45cb` |

No file under `src/runtime`, `src/llama`, or `src/schema` changed, and
`last-llama-jsonl-v1` did not change. The underlying CPU/CUDA runtime
qualification remains inherited. This milestone qualifies only CLI launch,
DLL discovery/layout, doctor diagnostics, and package-like execution.

## Development-repository isolation scope

For v0.1.0, runtime/package qualification and development-repository isolation
were verified separately. These release results are distinct from the historical
migration evidence above.

CPU/CUDA package execution passed in the original release qualification
environment. A later Windows Sandbox check confirmed that the real development
`.git` directory was excluded from the guest filesystem. Separate complete
archive-entry scans confirmed that neither release ZIP contains `.git` entries.

Windows Application Control blocked the unsigned CPU worker from executing
inside that Sandbox; CUDA execution there was not performed. Therefore
simultaneous runtime execution and real development-Git isolation in the same
execution environment remains unqualified for v0.1.0. The Sandbox check was
isolation-only, not a full runtime qualification. See the corrected validation
report and evidence bundle attached to the release for these separate scopes.
