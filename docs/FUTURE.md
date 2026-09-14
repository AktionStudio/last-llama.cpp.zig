# Future planning

This document records possible future work. Nothing described here is part of
the current CLI contract, implemented behavior, or qualified v0.1.0 package.
Each accepted change requires tests, documentation, a new release commit, and
qualification of the exact resulting distribution.

## Model discovery and configuration management

The current `models` command reports aliases from configuration. A future CLI
may also make package-local GGUF files easier to find and configure without
changing inference or backend-selection semantics.

Proposed command family:

- `models` displays configured aliases and a separate summary of discovered,
  unconfigured GGUF files.
- `models discover` performs a read-only scan of the package-relative
  `models\` directory and works when no configuration exists.
- `models init` creates `last-llama.json` from
  `last-llama.json.example` without overwriting an existing file.
- `models add <file> --alias <name>` records a model path and alias without
  copying, moving, opening, hashing, or downloading the model.

Discovery should remain bounded, deterministic, and read-only. Results should
distinguish configured-and-present, configured-but-missing, and
discovered-but-unconfigured files. The design must decide whether scanning is
recursive, how filename and alias collisions are handled, and whether reparse
points are excluded. It must support spaces and Unicode without treating a
filename as trusted model metadata.

Configuration writes require a stronger contract than discovery. They should
be explicit and atomic, preserve an existing valid configuration, refuse
unexpected overwrite or alias collisions, and leave no partial file after a
failure. A read-only installation must produce a clear diagnostic. Relative
paths should resolve using the same configuration-directory rules as the
current CLI.

Before release, the accepted behavior needs CLI unit tests, fake-worker
integration tests, configuration portability and denied-write tests, package
inventory checks, and complete qualification of the new extracted binary ZIP.
The existing v0.1.0 evidence does not qualify this proposed behavior.
