# Models

Models are not bundled with this project. Obtain each GGUF separately, review
its license and source, and place it outside Git. The tracked configuration
example expects this package-relative layout:

```text
models/
  README.md
  Qwen3-8B-Q4_K_M.gguf
```

The official Qwen repositories publish `Qwen3-8B-Q4_K_M.gguf` at approximately
5.03 GB and `Qwen3-32B-Q4_K_M.gguf` at approximately 19.8 GB:

- [Qwen3-8B-GGUF](https://huggingface.co/Qwen/Qwen3-8B-GGUF/tree/main)
- [Qwen3-32B-GGUF](https://huggingface.co/Qwen/Qwen3-32B-GGUF/tree/main)

The model repositories currently identify the models under the Apache-2.0
license. Model licensing is separate from this project's license and notices;
verify the upstream page before downloading or redistributing a model.

## Configure a model

The updated v0.1.0 Windows package includes this guide in `models\README.md`
and includes `last-llama.json.example` beside the executables. Copy that file
to `last-llama.json`, then edit the model path as needed. Its alias `qwen3-8b`
maps to `models\Qwen3-8B-Q4_K_M.gguf`. Relative paths resolve from the directory
containing the selected configuration file, not necessarily the current
working directory. You can also pass an absolute GGUF path instead of an alias.

```powershell
Copy-Item .\last-llama.json.example .\last-llama.json
notepad .\last-llama.json
```

```bat
copy last-llama.json.example last-llama.json
notepad last-llama.json
```

The first block is for PowerShell; the second is for Command Prompt.

The sample leaves backend selection at `auto` without configuring GPU layers,
so it remains CPU-capable. CUDA is always an explicit choice:

```powershell
.\last-llama.exe run qwen3-8b --backend cuda --gpu-layers 37 --prompt "Say hello."
```

```bat
last-llama.exe run qwen3-8b --backend cuda --gpu-layers 37 --prompt "Say hello."
```

The first command is for PowerShell; the second is for Command Prompt.

## Evidence boundaries

These terms are deliberately different:

- **Supported configuration** means the CLI can resolve and pass the model to
  the unchanged worker contract.
- **Tested** means an exact model artifact completed a stated bounded check on
  recorded hardware and settings.
- **Runtime-qualified** means that exact artifact passed a declared standalone
  runtime gate; it does not automatically qualify a consuming application.
- **Downstream-qualified** means a consuming system separately accepted that
  exact runtime, model, execution prompt, hardware, and qualification procedure.

Recorded downstream evidence for Qwen3-8B Q4_K_M used SHA-256
`10ded9291f250596ef7149438dd5da80bf3780b0eebcd2a1922c2b4a08c36e54`
on an RTX 3090 with 37 of 37 layers offloaded. That is narrow evidence for the
recorded artifact and execution; it is not a general promise for every model,
prompt, driver, or machine.

Recorded Qwen3-32B Q4_K_M evidence used SHA-256
`efd971561896866f0e910cce52761ca77b1b138090c7f15fe284676d57d1f689`.
CUDA lifecycle and provenance succeeded on an RTX 3090 with 65 of 65 layers
offloaded, but the consuming system's multi-decision qualification remained
degraded because semantic repeatability failed. CPU downstream qualification
was not performed. Do not describe that 32B configuration as downstream
qualified.

The unsigned v0.1.0 release-package qualification used the smaller tracked
SmolLM2 fixture, not either Qwen model.

## Capacity notes

GGUF file size is not total runtime memory. Context length, KV cache, compute
buffers, CUDA offload, driver allocation, and concurrent processes add memory
usage. A file that fits on disk may still exceed RAM or VRAM. Start with a
bounded context and token count, use `doctor`, and treat offload values as
model-specific settings rather than universal recommendations.
