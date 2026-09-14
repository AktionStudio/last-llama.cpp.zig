# Use the runtime in your application

First [run a prompt with the package](../README.md#try-it). Your application can
then launch the same CLI or worker as a child process. The examples below use
Python's standard library; Python is needed only to run these examples.

## Available capabilities

This table describes the implemented project interface, not the wider llama.cpp
feature set. The types are defined in [contract.zig](../src/runtime/contract.zig).

| Capability | CLI | Direct worker and limits |
| --- | --- | --- |
| GGUF text generation | Model path or alias; `--prompt`, `--prompt-file`, `--system` | Model path argument plus `prompt` and `system`; model chat template applied by default. |
| Sampling and bounds | `--temperature`, `--top-p`, `--seed`, `--context-size`, `--max-tokens`, `--timeout-ms` | Corresponding request fields; a seed does not promise identical answers across hardware/builds. |
| CPU/CUDA | `--backend`, `--gpu-layers`; conservative `auto` selection | Explicit `backend`; CUDA selects one device, with optional device identity constraints. |
| JSON constraints | `--schema` file or inline JSON | `schema_json` is a JSON-encoded string; set `expect_json: true`. Guarded subset only; final extraction requires a JSON object. |
| Direct grammar | Not exposed | `grammar` accepts GBNF; mutually exclusive with `schema_json`. |
| Prompt treatment | Default model-template treatment | `raw_prompt` and named `treatment`; Qwen treatment appends `/no_think` before template rendering, not a guarantee about model behavior. |
| Inspection | `inspect cpu`, `inspect cuda`, `doctor` | `--inspect-runtime` returns runtime/module and compute identity without loading a model. |
| Identity evidence | Preserved in `--json` results | Runtime, model, template, and compute attestation; `expected_*` pins reject mismatches. |
| Completion | Rejects errors and missing final answers | Finish reason, final extraction, token counts, timing, and cleanup fields. |

Execution is one-shot: no token streaming, HTTP endpoint, retained chat history,
or cross-request KV/sampler state. Normal invocations load and unload the model.
The request-array/cycle form is retained for proof fixtures, not persistent
serving. Applications own history, scheduling, retries, and answer reuse.

## Start with the CLI

Use an argument list rather than constructing a shell command. Replace both
absolute paths. A direct model path avoids alias/configuration prerequisites.

```python
import json
import subprocess
from pathlib import Path

package = Path(r"C:\tools\last-llama").resolve()
model = Path(r"C:\models\your-model.gguf").resolve()
completed = subprocess.run(
    [str(package / "last-llama.exe"), "run", str(model),
     "--backend", "cpu", "--prompt", "Say hello in one sentence.",
     "--max-tokens", "128", "--context-size", "4096",
     "--timeout-ms", "300000", "--json"],
    capture_output=True, text=True, encoding="utf-8", timeout=360,
)
if completed.returncode != 0:
    raise RuntimeError(completed.stderr)
rows = completed.stdout.strip().splitlines()
if len(rows) != 1:
    raise RuntimeError("Expected one result row")
result = json.loads(rows[0])
if result.get("status") != "ok" or not isinstance(result.get("final_text"), str):
    raise RuntimeError("No complete answer")
print(result["final_text"])
```

The CLI manages worker selection and the child's DLL search path. It validates
the worker exit and result before returning JSON. `--json` is the whole result,
not just generated text. Keep stderr separate from the JSON stream.

## Request structured output

Save this as `answer.schema.json` and add `--schema` followed by its absolute
path to the CLI argument list:

```json
{
  "type": "object",
  "properties": {"answer": {"type": "string"}},
  "required": ["answer"],
  "additionalProperties": false
}
```

Ask for a short answer in that object. The CLI passes the schema as `schema_json`
and sets `expect_json`. Parse successful `final_text` with `json.loads` to get
the generated object.

The [schema guard](../src/schema/schema_api.cpp) rejects unsupported keywords,
combinations, duplicate keys, and excessive complexity. Objects must be closed
with `additionalProperties: false`. This is not full JSON Schema support.
Constrained syntax does not establish factual correctness.

## Call a worker directly

Use this route for direct GBNF, explicit treatments, or expected identity pins.
This standalone CPU example writes one JSON object and closes stdin. The worker
reads through EOF before processing; leaving stdin open will wait.

```python
import json
import os
import subprocess
from pathlib import Path

package = Path(r"C:\tools\last-llama").resolve()
model = Path(r"C:\models\your-model.gguf").resolve()
request = {
    "id": "hello-1",
    "protocol": "last-llama-jsonl-v1",
    "operation": "generate",
    "backend": "cpu",
    "conversation": "one-shot-v1",
    "prompt": "Say hello in one sentence.",
    "context_size": 4096,
    "max_tokens": 128,
    "timeout_ms": 300000,
}
env = os.environ.copy()
env["PATH"] = str(package / "runtime" / "cpu")
completed = subprocess.run(
    [str(package / "last-llama-cpu.exe"), str(model)],
    input=json.dumps(request) + "\n", env=env, cwd=package,
    capture_output=True, text=True, encoding="utf-8", timeout=360,
)
if completed.returncode != 0:
    raise RuntimeError(completed.stderr)
rows = completed.stdout.strip().splitlines()
if len(rows) != 1:
    raise RuntimeError("Expected one result row")
result = json.loads(rows[0])
if (result.get("id") != request["id"] or result.get("status") != "ok"
        or result.get("finish") != "eog"
        or not isinstance(result.get("final_text"), str)):
    raise RuntimeError(f"Incomplete or failed request: {result}")
print(result["final_text"])
```

A successful result includes `id`, `status: "ok"`, `finish: "eog"`, `final_text`,
`generated_tokens`, and `attestation`. Inspect the actual object rather than
expecting a fixed answer or copying identity hashes from an example. For CUDA,
select its executable and runtime directory, set `backend` to `cuda`, and supply
positive, model-appropriate `gpu_layers`.

## Completion, timeouts, and identity

Treat process success and request success separately. A direct worker can return
a failed result or no final answer despite exiting successfully. `status: "ok"`
alone is insufficient: token limits, timeout, or incomplete extraction can leave
`final_text` null. `text` may contain partial output and should not silently
replace a final answer.

`timeout_ms` bounds generation, with a 300,000 ms maximum; it is not a total
startup/model-load deadline. The examples use a separate 360-second caller
budget. Choose a budget for your application and handle `subprocess.TimeoutExpired`.
Terminating the CLI parent is not a documented guarantee of terminating its worker;
for hard process-tree deadlines, supervise the tree explicitly or call the worker.

CPU cancellation uses abort checks; CUDA checks cancellation/deadlines between
synchronized decode steps, without GPU-kernel preemption. `cancel_after_*` and
`fail_after_decodes` are diagnostic hooks, not an interactive cancel endpoint.

For strict identity admission, use the worker's `expected_*` fields and verify
returned attestation against identities your application has accepted. CLI
configuration does not expose these pins. Attestation does not automatically
qualify your application's behavior.

## Deploy the files your application calls

Keep executables at the package root and preserve backend-specific DLL directories
from the [package layout](CLI.md#package-layout). Do not combine CPU and CUDA DLLs.
The direct-worker example changes only the child's `PATH`; the CLI does this
itself. Models remain separate, user-supplied inputs.

Next: [runtime contract](RUNTIME_BOUNDARY.md), [CLI configuration](CLI.md#configuration),
or [source builds](BUILDING.md). These are process-integration examples; this
guide does not declare internal Zig modules a supported library API.
