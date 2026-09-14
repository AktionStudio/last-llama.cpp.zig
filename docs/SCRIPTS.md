# Repository scripts and audiences

Users of the extracted Windows binary package do not need any repository
scripts. They run `last-llama.exe` and use the packaged configuration example.
The scripts are tracked in the source repository and source archive so source
builders and release maintainers can reproduce declared results.

Tracked scripts should not be added to `.gitignore`. Generated outputs,
downloaded dependencies, model weights, toolchains, evidence workspaces, and
release artifacts are ignored or excluded instead. One-off private or
migration-only helpers belong under an ignored workspace such as `temp\`, not
in the public `scripts\` directory.

## Script inventory

| File | Audience | Purpose | Shipped in binary ZIP |
| --- | --- | --- | --- |
| `build-default.json` | Source builder | Declares the default generator and CPU/CUDA job counts used by build helpers. | No |
| `setup-dependencies.ps1` | Source builder | Obtains and verifies the pinned llama.cpp checkout. This script performs a Git clone or fetch and therefore requires network access. It never downloads a model. | No |
| `generate-bindings.ps1` | Source builder | Generates the pinned Zig C binding from the llama.cpp headers. | No |
| `build-engine.ps1` | Source builder | Builds the selected CPU or CUDA llama.cpp/GGML engine with NMake or the explicitly selected Ninja route. | No |
| `build-schema-api.ps1` | Source builder | Builds the backend-matched guarded schema bridge. | No |
| `run-gate.ps1` | Developer or maintainer | Builds and runs bounded smoke, structured-output, or lifecycle gates against a supplied model. | No |
| `verify-gate.py` | Developer or maintainer | Validates JSONL produced by the bounded runtime gates. | No |
| `test-cli.ps1` | Developer or maintainer | Runs package-like CLI integration tests with the fake worker and isolated runtime directories. | No |
| `prepare-release.ps1` | Release maintainer only | Performs clean-clone tests, fresh builds, archive construction, extracted-package qualification, and sanitized-evidence preparation. It is version-specific and is not an installer. | No |
| `finalize-release.ps1` | Release maintainer only | Verifies an already qualified annotated tag, produces the final report and checksums, and rechecks immutability. It does not push or publish. | No |

## What remains excluded

The public release allowlist intentionally excludes old host-qualification,
frozen-parity, token-replay, migration, and evidence-processing helpers that
are not part of current source reproduction. Their historical results may be
summarized in documentation, but the machinery itself is not needed by package
users or by the current release route.

The binary ZIP should continue to contain no scripts. The source ZIP should
contain the tracked scripts above because they explain and reproduce how the
runtime and release artifacts are constructed. See [Reproduction gates](REPRODUCTION.md)
and [Release procedure](RELEASE.md) for the supported sequences.
