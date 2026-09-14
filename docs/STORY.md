# The story behind Last-llama.cpp.zig

## The missing piece

I was building a larger system in Zig and needed it to run language models
locally. Calling third-party model services was useful, but it did not give me
all the control the project needed in one place: choosing the exact model
artifact, controlling CPU or GPU execution, constraining structured output,
managing the model lifecycle, and recording what actually ran.

I wanted a local component that could be inspected and reproduced. It should
not silently download a model, hide a backend decision, retain conversation
state, or require the rest of the application to become an inference server.
The application would remain responsible for its own history and orchestration;
the runtime would do one job and make its behavior explicit.

## Finding a starting point

`llama.cpp` already provided the native inference engine, but I could not find
an interface in Zig that matched this particular boundary. I did find
[`Deins/llama.cpp.zig`](https://github.com/Deins/llama.cpp.zig), an existing Zig
wrapper around `llama.cpp`. It showed that the connection was practical and
gave the early work an important reference point. That inspiration and the
historical source provenance remain credited in this repository.

The initial work used an adapted wrapper surface while the runtime behavior was
being explored. Over time, however, the actual requirements became much
narrower and clearer than a general-purpose wrapper: load a model, tokenize and
decode, apply a template, sample, constrain output when requested, report
identity, clean up reliably, and support explicit CPU or CUDA execution.

## Choosing an owned boundary

Once that required surface was understood, I decided not to carry the earlier
wrapper implementation forward. The active wrapper code was removed and
replaced with a small project-owned implementation against the upstream
`llama.cpp` C API. The goal was not to erase where the project started; it was
to make the maintained boundary understandable, auditable, and limited to what
this runtime actually uses.

That is why the repository keeps both sides of the history visible:

- the Deins wrapper is acknowledged as the historical inspiration and early
  provenance;
- upstream `llama.cpp` remains the native engine and is pinned as an external
  dependency; and
- the active `src/llama` interface is independently maintained as part of this
  project, without importing the historical wrapper source.

The detailed evidence for that transition is recorded in the
[source-provenance audit](owned-interface/PROVENANCE.md),
[extraction manifest](../EXTRACTION_MANIFEST.md), [dependency record](../DEPENDENCIES.md),
and [attribution notice](../NOTICE).

## Becoming a standalone tool

What began as infrastructure for a larger application became useful as its own
component. Last-llama.cpp.zig now provides separate CPU and CUDA workers behind
the versioned `last-llama-jsonl-v1` protocol, plus a friendlier command-line
interface for direct use. Applications can use the CLI or launch a worker
themselves without taking a dependency on the rest of the original system.

The design remains intentionally focused. This is not a hosted API, a model
downloader, a chat-history manager, or a scheduling service. It is a local
inference building block that tries to be explicit about models, configuration,
backend selection, structured output, runtime identity, and cleanup.

The first public release is a small milestone in that journey: an unsigned,
locally qualified Windows package that other Zig developers and local-model
builders can inspect, run, and build upon.
