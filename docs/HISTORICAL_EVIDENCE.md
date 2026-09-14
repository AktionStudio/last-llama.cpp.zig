# Concise historical evidence

The frozen source lab is evidence only. This file records the useful claims that guided extraction; it does not turn them into clean-project results.

| Historical treatment | Recorded result | Scope and limit |
| --- | --- | --- |
| Zig 0.17 CPU Qwen semantic harness | PASS: 12 semantic requests; additional 87-request boundary/lifecycle checks | Lab executable and model, not this clean checkout |
| Zig 0.17 CUDA Qwen smoke | PASS: two finals, RTX 3090, requested 99 layers and effective 65/65 offload | Lab executable and model, not this clean checkout |
| Zig 0.17 CUDA Qwen matrix | PASS: 129 requests across three model cycles | Lab executable and model, not this clean checkout |
| Guarded native schema conversion | PASS: fresh exact conversions and CPU/CUDA sampler/generation checks | Finite admitted subset only; unsupported schema must fail closed |
| Small-model CUDA proof | PASS: selected RTX 3090, full small-model layer offload, successful bounded generation | Does not establish Qwen support or output equality |

Known Qwen evidence used engine `d4abd573f6a360201799072384ceec6170fdb60c`, wrapper base `f776b9aca51cc90f7ddba9c2a0874862aebf08f5`, Zig `0.17.0-dev.1676+c9dc9b798`, RTX 3090, driver `591.86`, CUDA `13.3.1`/NVCC `13.3.73`, and Qwen template SHA-256 `57f1fd00f0013a2be96aa79b857391f27e23df5b5f847072b524c897e24d0361`.

The recorded 19,762,149,024-byte Qwen GGUF is absent from the frozen lab now. Therefore the clean project must report Qwen3-32B as not performed until the user explicitly supplies a model whose SHA-256 is `efd971561896866f0e910cce52761ca77b1b138090c7f15fe284676d57d1f689`.

Intentionally omitted: application source and fixtures, provider adapters,
orchestration state, private archives, experiments, raw logs, historical build
trees, toolchain archives, DLLs, and models.
