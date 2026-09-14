# Unsigned v0.1.0 release procedure

The v0.1.0 Windows distribution is intentionally **unsigned**. Signing or
otherwise changing any packaged file requires a new package and complete
requalification.

The existing tag and originally qualified v0.1.0 archive remain historical
deliverables. The packaging-only v0.1.0 Windows update reuses every executable
and DLL byte-for-byte while adding `last-llama.json.example`,
`models/README.md`, and refreshed package documentation. This is package
inventory verification, not a new runtime qualification.

These are release-maintainer operations, not installation steps for application
users. The complete tracked-script classification is in
[Repository scripts and audiences](SCRIPTS.md).

Release construction is fail-closed and has two phases:

1. `scripts/prepare-release.ps1` validates a clean 40-character source commit,
   creates a clean clone, runs dependency-free tests, builds fresh CPU and CUDA
   engines with Ninja 1.13.2 at 16 jobs, creates the source and binary archives,
   and qualifies the exact extracted binary package.
2. After every qualification row is `PASS`, create the annotated `v0.1.0` tag
   in the independent repository. Then run `scripts/finalize-release.ps1` to
   verify the tag and embedded worker revisions, create the final report and
   `SHA256SUMS.txt`, and recheck immutability.

Neither script downloads dependencies, pushes Git refs, signs files, or accepts
an `uncommitted`, abbreviated, missing, dirty, or unknown source revision.

## Required local inputs

- Zig `0.17.0-dev.1676+c9dc9b798` for runners and tests.
- Zig `0.14.1` for C-header translation.
- Ninja `1.13.2`, CMake, and the declared MSVC x64 toolchain.
- A clean llama.cpp checkout at
  `d4abd573f6a360201799072384ceec6170fdb60c`.
- CUDA Toolkit `13.3.1` with NVCC `13.3.73` and the cuBLAS redistributables.
- A user-supplied GGUF smoke model. The v0.1.0 qualification treatment expects
  SmolLM2 Q8_0 SHA-256
  `48ab3034d0dd401fbc721eb1df3217902fee7dab9078992d66431f09b7750201`.

All paths are passed explicitly. Existing engine, schema, Zig output, and cache
directories are not reused.

## Prepare and qualify

Run from the independent repository. Choose fresh, dedicated work and output
directories; neither may be inside a dependency checkout.

```powershell
.\scripts\prepare-release.ps1 `
  -DependencyRoot C:\path\to\local-dependencies `
  -Model C:\path\to\smollm2-360m-instruct-q8_0.gguf `
  -WorkRoot C:\path\to\fresh-release-work `
  -OutputDirectory .\release\v0.1.0
```

`DependencyRoot` is expected to contain the already-present `.tools` and
`external/llama.cpp` directories described in [DEPENDENCIES.md](../DEPENDENCIES.md).
The script records a reversible rename map and temporarily hides that dependency
repository during extracted-package execution. Its `finally` block restores the
original name and verifies restoration. A blocked or unenforceable isolation or
permission check fails qualification.

The prepare phase writes three immutable candidates and
`qualification-summary.json`:

- `last-llama-windows-x64-v0.1.0.zip`
- `last-llama-v0.1.0-source.zip`
- `last-llama-v0.1.0-evidence.zip`

The packaging-only v0.1.0 Windows update includes `last-llama.json.example`
and `models/README.md`. Actual GGUF weights remain forbidden. The package
manifest records both onboarding files, and package verification parses the
packaged example. Executables remain
at the archive root, DLLs remain exclusively under their backend runtime
directories, and the distribution remains CPU plus CUDA rather than GPU-only.

The evidence archive contains sanitized copies only. Raw local logs remain in
the dedicated work directory, outside the release archives. The originals and
historical evidence are never rewritten.

## Tag and finalize

Only after `qualification-summary.json` reports `overall_status: PASS`:

```powershell
git tag -a v0.1.0 -m "Unsigned last-llama.cpp.zig v0.1.0"
git rev-parse v0.1.0^{}

.\scripts\finalize-release.ps1 `
  -OutputDirectory .\release\v0.1.0 `
  -TagRepository .
```

The finalizer refuses a missing, lightweight, or conflicting tag. It produces
`v0.1.0-validation-report.md` and `SHA256SUMS.txt`, then independently rechecks
the source ZIP, binary ZIP, evidence ZIP, and report hashes. It prints the
SHA-256 of `SHA256SUMS.txt` for the final handoff; the checksum file does not
contain a circular self-hash.

Nothing in this procedure pushes a tag or commit. NMake remains the documented
reference/default build route; this release uses the previously qualified Ninja
1.13.2, 16-job route without repeating generator-equivalence work.

All command blocks in this document are PowerShell. Command Prompt users can
launch the scripts with `powershell -File scripts\prepare-release.ps1 ...` and
`powershell -File scripts\finalize-release.ps1 ...`; PowerShell line
continuations shown with a backtick must be converted if arguments are placed
directly in Command Prompt.
