# v0.1.0 packaging-only update

Status: **PASS — packaging and documentation update only**.

This ZIP reuses every executable and DLL from the original qualified unsigned
v0.1.0 Windows x64 package byte-for-byte. Runtime and CLI behavior are
unchanged, and no newly compiled binary is included.

Changes:

- added `last-llama.json.example`;
- added `models/README.md`;
- refreshed `PACKAGE-README.md`; and
- regenerated `package-manifest.json` for the new archive inventory.

Provenance:

- original qualified runtime commit:
  `4e4824a01c0fa59b40e8e18073c270f28aa5bedd`;
- documentation/configuration source commit:
  `5c7949c5f7afa38b4044dcc4dff18218cc73ff5a`;
- original binary ZIP SHA-256:
  `f6e437c45cf0fac09784239e742fbe3db02d689e50c45411fb9210da451a441b`;
- updated binary ZIP SHA-256:
  `6edb81c9b596269a856940dba0113e46ff4179d4297ca97595d2408ae12ef292`.

The archive is kept locally at
`release\v0.1.0\github-release-assets\last-llama-windows-x64-v0.1.0.zip`
and is uploaded manually from the
[GitHub Releases page](https://github.com/AktionStudio/last-llama.cpp.zig/releases).
The `github-release-assets` directory is intentionally ignored by Git.

Verification performed:

- all 18 executable and DLL sizes and SHA-256 hashes match the original
  qualified package manifest;
- the updated manifest covers all 25 non-manifest payload files;
- the extracted ZIP inventory, sizes, and hashes match the updated manifest;
- no DLL is present at the package root;
- CPU and CUDA runtime directories remain separate;
- the packaged JSON example parses and resolves its relative model path from a
  different working directory; and
- the packaged model guide accurately states that both the guide and
  `last-llama.json.example` are included; and
- `doctor` passes for both unchanged worker/runtime trees.

This record is not a new runtime qualification. It is a package-inventory
verification demonstrating that the qualified binary payloads did not change.
