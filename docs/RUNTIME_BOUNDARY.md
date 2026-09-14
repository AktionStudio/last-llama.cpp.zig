# Standalone runtime boundary

For implemented capabilities and complete calling examples, start with the [application integration guide](INTEGRATION.md). This reference describes the worker contract; its lifecycle names are not separate CLI subcommands.

The API boundary is `last-llama-jsonl-v1`, implemented by
`last-llama-cpu.exe` and `last-llama-cuda.exe`. Embedding applications remain
outside this repository and must qualify their own adapter and execution
binding.

Each invocation has this lifecycle:

1. `initialize`: initialize llama.cpp backend state.
2. `inspect_runtime`: the CUDA runner enumerates and selects exactly one CUDA device; CPU selects no GPU.
3. `load_model`: load the GGUF supplied as the first positional argument. Model weights may remain resident only for the invocation's requested cycles.
4. `generate`: read one JSON request from stdin and write one JSON result to stdout. The original request-array file form remains available for standalone proof fixtures.
5. `cancel`: CPU honors the exercised abort callback. CUDA supports cancellation and deadline checks between synchronized decode steps, not GPU-kernel preemption.
6. `unload_model`: unload after the requested cycles.
7. `shutdown`: deinitialize the llama.cpp backend.

`--inspect-runtime` performs no model load and returns the protocol, standalone source revision, pinned llama.cpp revision, executable SHA-256, loaded native module paths and hashes, effective backend, and selected device identity.

The request format supports model-template rendering (`system`, `prompt`, `raw_prompt`), explicit backend and device, requested GPU layers, context/token/sampling bounds, direct `grammar`, guarded `schema_json`, `expect_json`, cancellation, injected-failure hooks, and optional expected identity pins. `grammar` and `schema_json` are mutually exclusive. `schema_json` is converted fresh per request; it is never cached.

Every model-bound response includes separate runtime, model, template, and compute attestation. This records the model artifact path and SHA-256, GGUF architecture, file-type metadata, context capability, source/effective template hashes, treatment, requested/effective backend and offload, device identity, executable identity, and loaded module identity. Expected pins reject mismatches. `qwen3-no-think-directive-v1` records the actual generic Qwen treatment: the runtime appends `/no_think` before applying the model chat template. It does not claim that a metadata field disables reasoning.

These fields are additive within `last-llama-jsonl-v1`: existing request-array consumers remain supported, while consumers that require attestation may fail closed on missing fields. No inference semantics were removed or reinterpreted.

For each generated request, the runner creates a fresh context, verifies empty sequence memory, clears sequence memory, resets and destroys its sampler, releases the request arena, and checks the Zig allocator baseline. A request cannot carry a transcript, KV cache, sampler state, or generated answer into the next request. The JSON output fields `kv_before`, `kv_after`, and `kv_after_clear` use the current llama.cpp sequence-memory API; `-1` means that sequence 0 has no positions.

This is one-shot only. `conversation` must be `one-shot-v1`; no durable conversation state, implicit retry, fallback, transcript resend, or cross-run continuation is implemented.

The request generation timeout safety ceiling is 300 seconds. This ceiling was
raised from 180 seconds after a fresh-process Qwen3-32B CPU diagnostic reached
generation at approximately 108 seconds and completed a small response at
approximately 132 seconds. Existing requests retain their authored timeout;
the runtime does not silently increase or clamp it.
