[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ZigHeader,
    [string]$EngineDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'external\llama.cpp'),
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'build\generated\llama.h.zig')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ZigHeader -PathType Leaf)) {
    throw "Zig header generator was not found: $ZigHeader"
}
if (-not (Test-Path -LiteralPath (Join-Path $EngineDirectory 'include\llama.h') -PathType Leaf)) {
    throw "Pinned engine header was not found under: $EngineDirectory"
}

$version = (& $ZigHeader version).Trim()
if ($version -ne '0.14.1') {
    throw "The recorded binding-generation helper is Zig 0.14.1; refusing unpinned version $version."
}

$outputDirectory = Split-Path $OutputPath -Parent
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$header = Join-Path $EngineDirectory 'include\llama.h'
& $ZigHeader translate-c -target x86_64-windows-msvc -lc -DNDEBUG=1 -DLLAMA_SHARED=1 -DGGML_SHARED=1 "-I$EngineDirectory\include" "-I$EngineDirectory\ggml\include" "-I$EngineDirectory\ggml\src" $header | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
if ($LASTEXITCODE -ne 0) { throw 'llama.h Zig translation failed.' }
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw "Zig did not produce the requested binding: $OutputPath"
}

$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "Generated $OutputPath"
Write-Output "SHA-256 $hash"
