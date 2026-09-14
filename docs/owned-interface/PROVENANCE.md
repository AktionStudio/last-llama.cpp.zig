# Historical source provenance and completed audit

Historical wrapper origin: Deins/llama.cpp.zig
`f776b9aca51cc90f7ddba9c2a0874862aebf08f5`, as recorded in NOTICE and the extraction
manifest. This inventory describes historical source, not permission to copy it.

## Historical footprint verified before deletion

| File | Runtime use / imported symbols | Underlying calls |
| --- | --- | --- |
| `src/backend/llama.zig` | build.zig registers `llama`; both runners consume Backend, Model, Context, Batch, Sampler, SamplerPtr, Token, TokenData, TokenDataArray, Tokenizer, Detokenizer, and c. Support consumes Model and c. | Backend/model/context/vocab/batch/sampler C symbols are enumerated in REQUIREMENTS.md. Tokenizer and Detokenizer are reexports from utils.zig. |
| `src/backend/utils.zig` | Imported by llama.zig; active runtime uses Tokenizer.init/tokenize/getTokens/deinit and Detokenizer.init/detokenize/clearRetainingCapacity/deinit. | `llama_tokenize`, `llama_token_to_piece` through vocabulary methods. No templating, ring-buffer, logging, trimming, or other helper is required by runtime. |

Runtime model methods: defaultParams, initFromFile, deinit, nCtxTrain, nLayer,
vocab, metaValStr, cCPtr. Context methods: defaultParams, initWithModel, nCtx,
deinit. Batch methods: initOne, decode. Sampler methods: initChain, initGreedy,
initTopP, initTemp, initDist, add, sample, apply, accept, reset, deinit.
Vocabulary methods: tokenEos, isEog, tokenize, tokenToPiece (last two used by helpers).

The tracked Zig/import/build graph and extraction classifications identify these
two files as inherited implementation. Runtime runners/support and schema bridge
are lab/project code consuming that wrapper; preserve them rather than deleting
them by association. The generated header and external engine are upstream
artifacts, not Deins code. No Deins package is present in build.zig.zon.

## Final-source audit checklist

Search active tracked Zig and build inputs for old paths/module registrations,
Deins names, distinctive old helpers, inherited comments, and API compatibility
shapes. Review structures as well as text matches. Candidate historical markers:

- `TemplatedPrompt`, `TokenRingBuffer`, `appendEraseFifo`, `detokenizeWithSpecial`,
  `scopedLog`, `tokenGetText`, `templateFromName`, `toLLama`, `SamplerPtr`.
- `zigified opaque`, `unexpected tokenization error`, `assume that token on
  average`, `simple prompt template mechanism`, `lenght of elements used`.
- Old `src/backend` paths, `@import("llama")` registrations, convenience reexports,
  opaque pointer-cast facade, and broad unused sampler/model APIs.

These are audit candidates, not a forbidden-word list. Model, context, sampler,
token, batch, init/deinit, and upstream C names are ordinary concepts. Do not
cosmetically rename them. Every remaining match must be classified as upstream
API, historical documentation, license/provenance, or justified non-derived
terminology. Similarity review must distinguish necessary short C calls from
copied helper structure; a clean grep alone is not proof of independent authorship.

## Completed active-source audit

Active Zig/build inputs contain no `src/backend` path or `@import("llama")`
registration. `src/llama/c.zig` is the generated-header boundary; runtime and
text use only the required upstream C calls. Remaining Deins references occur
only in this historical inventory, NOTICE/LICENSES, and extraction provenance.
No inherited helper names, comments, broad wrapper APIs, or compatibility aliases
remain active. The historical implementation is not included in this curated
repository.
