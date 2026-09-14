# Windows x64 v0.1.0 binary

The large Windows archive is intentionally excluded from Git and should be
uploaded as a GitHub Release asset:

- Download page: <https://github.com/AktionStudio/last-llama.cpp.zig/releases>
- Release asset: `last-llama-windows-x64-v0.1.0.zip`
- SHA-256: `6edb81c9b596269a856940dba0113e46ff4179d4297ca97595d2408ae12ef292`
- Local maintainer path: `release\v0.1.0\github-release-assets\last-llama-windows-x64-v0.1.0.zip`

The local `github-release-assets` directory is ignored so this 442,157,570-byte
archive cannot accidentally become a normal Git blob. Upload it manually on
the GitHub Releases page, then verify the downloaded file against the SHA-256
above. This is the packaging-only v0.1.0 update: its executable and DLL payloads
are byte-for-byte identical to the originally qualified unsigned v0.1.0 package.
