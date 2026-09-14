[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'release\v0.1.0'),
    [string]$Tag = 'v0.1.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$summaryPath = Join-Path $OutputDirectory 'qualification-summary.json'
$sourceZip = Join-Path $OutputDirectory 'last-llama-v0.1.0-source.zip'
$binaryZip = Join-Path $OutputDirectory 'last-llama-windows-x64-v0.1.0.zip'
$evidenceZip = Join-Path $OutputDirectory 'last-llama-v0.1.0-evidence.zip'
$reportPath = Join-Path $OutputDirectory 'v0.1.0-validation-report.md'
$checksumsPath = Join-Path $OutputDirectory 'SHA256SUMS.txt'

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

foreach ($path in @($summaryPath, $sourceZip, $binaryZip, $evidenceZip)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required qualified artifact is missing: $path" }
}
if (Test-Path -LiteralPath $reportPath) { throw "Refusing to overwrite final report: $reportPath" }
if (Test-Path -LiteralPath $checksumsPath) { throw "Refusing to overwrite checksums: $checksumsPath" }

$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 100
if ($summary.overall_status -ne 'PASS' -or -not $summary.unsigned -or @($summary.checks | Where-Object { $_.status -ne 'PASS' }).Count) {
    throw 'Qualification summary is not an all-PASS unsigned release record.'
}
$commit = [string]$summary.release_commit
if ($commit -notmatch '^[0-9a-f]{40}$') { throw 'Qualification summary does not contain a full release commit.' }
$head = (& git -C $RepositoryRoot rev-parse --verify HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $commit) { throw 'Repository HEAD differs from the qualified commit.' }
$status = (& git -C $RepositoryRoot status --porcelain=v1 --untracked-files=all) -join "`n"
if ($status) { throw "Repository is not clean: $status" }
$tagCommit = (& git -C $RepositoryRoot rev-list -n 1 $Tag 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $tagCommit -ne $commit) { throw "Annotated tag $Tag does not resolve to the qualified commit." }
$tagType = (& git -C $RepositoryRoot cat-file -t $Tag).Trim()
if ($tagType -ne 'tag') { throw "$Tag is not an annotated tag." }

foreach ($artifact in @($summary.artifacts.source, $summary.artifacts.binary, $summary.artifacts.evidence)) {
    $path = Join-Path $OutputDirectory $artifact.name
    if ((Get-Sha256 $path) -ne $artifact.sha256 -or (Get-Item -LiteralPath $path).Length -ne [long]$artifact.bytes) {
        throw "Qualified artifact changed after validation: $($artifact.name)"
    }
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('last-llama-finalize-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $sourceExtract = Join-Path $temp 'source'
    $binaryExtract = Join-Path $temp 'binary'
    New-Item -ItemType Directory -Path $sourceExtract, $binaryExtract | Out-Null
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $sourceExtract
    Expand-Archive -LiteralPath $binaryZip -DestinationPath $binaryExtract
    $sourceTree = Join-Path $sourceExtract 'last-llama-v0.1.0'
    $tracked = @(& git -C $RepositoryRoot ls-files | Sort-Object)
    $archived = @(Get-ChildItem -LiteralPath $sourceTree -Recurse -File | ForEach-Object { $_.FullName.Substring($sourceTree.Length + 1).Replace('\', '/') } | Sort-Object)
    if (($tracked -join "`n") -ne ($archived -join "`n")) { throw 'Source archive inventory no longer matches the tagged commit.' }
    foreach ($relative in $tracked) {
        $tagBlob = (& git -C $RepositoryRoot rev-parse "$Tag`:$relative").Trim()
        $zipBlob = (& git -C $RepositoryRoot hash-object (Join-Path $sourceTree $relative)).Trim()
        if ($tagBlob -ne $zipBlob) { throw "Source archive differs from tagged commit: $relative" }
    }

    $manifest = Get-Content -LiteralPath (Join-Path $binaryExtract 'package-manifest.json') -Raw | ConvertFrom-Json -Depth 100
    if ($manifest.release_commit -ne $commit -or -not $manifest.unsigned) { throw 'Binary manifest commit or unsigned state is wrong.' }
    foreach ($worker in @('last-llama-cpu.exe', 'last-llama-cuda.exe')) {
        $backend = if ($worker -like '*cpu*') { 'cpu' } else { 'cuda' }
        $runtimeDir = Join-Path $binaryExtract "runtime\$backend"
        $savedPath = $env:PATH
        $env:PATH = "$runtimeDir;C:\Windows\System32;C:\Windows"
        try {
            $inspectStderr = Join-Path $temp "$worker.inspect.stderr.txt"
            $inspectJson = & (Join-Path $binaryExtract $worker) --inspect-runtime 2> $inspectStderr | Out-String
            $inspectExitCode = $LASTEXITCODE
            if ($inspectExitCode -ne 0) { throw "$worker runtime inspection failed with exit code $inspectExitCode." }
            $inspect = $inspectJson | ConvertFrom-Json -Depth 100
            if ($inspect.runtime.revision -ne $commit) { throw "$worker does not embed the tagged commit." }
        } finally { $env:PATH = $savedPath }
    }
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

$matrix = @($summary.checks | ForEach-Object { "| $($_.name) | $($_.status) | $(([string]$_.details).Replace('|', '\|')) |" }) -join "`n"
$report = @"
# Unsigned v0.1.0 validation report

Overall status: **PASS**

- Release: v0.1.0
- Signing status: **Unsigned v0.1.0**
- Qualified commit: $commit
- Annotated tag: $Tag (verified to resolve to the qualified commit)
- Runtime protocol: last-llama-jsonl-v1 (unchanged)
- Upstream llama.cpp: $($summary.llama_cpp_revision)

Signing or changing any packaged file requires repackaging and complete
requalification.

## Qualification matrix

| Gate | Result | Evidence summary |
| --- | --- | --- |
$matrix

All requested gates were performed and passed. Historical migration evidence
is identified separately in the source documentation and was not substituted
for qualification of these exact archives. Raw local logs remain outside the
evidence archive; the evidence ZIP contains sanitized copies and its own
evidence-manifest.json.

## Artifact closure

The source ZIP was re-extracted after tagging and its complete inventory and
file contents matched the tagged tree. Both packaged workers were re-inspected
from the extracted binary ZIP and reported the same full commit as the tag and
package manifest. Package payloads are unsigned and immutable at this closure.

External prerequisites are Windows x64, Microsoft VC++/OpenMP runtime components
where required, a compatible NVIDIA driver for CUDA, and a user-supplied GGUF
model. Toolchains, CUDA development files, models, and NVIDIA driver DLLs are
not bundled.
"@
$report | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM

$covered = @($sourceZip, $binaryZip, $evidenceZip, $reportPath)
$lines = @($covered | ForEach-Object { "$(Get-Sha256 $_)  $(Split-Path $_ -Leaf)" })
$lines | Set-Content -LiteralPath $checksumsPath -Encoding ascii

foreach ($line in Get-Content -LiteralPath $checksumsPath) {
    if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Malformed checksum line: $line" }
    $path = Join-Path $OutputDirectory $Matches[2]
    if ((Get-Sha256 $path) -ne $Matches[1]) { throw "Checksum verification failed: $($Matches[2])" }
}
$checksumSelfHash1 = Get-Sha256 $checksumsPath
$checksumSelfHash2 = (Get-FileHash -LiteralPath $checksumsPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($checksumSelfHash1 -ne $checksumSelfHash2) { throw 'Independent SHA256SUMS.txt self-hash recheck failed.' }

$finalStatus = (& git -C $RepositoryRoot status --porcelain=v1 --untracked-files=all) -join "`n"
if ($finalStatus) { throw "Final source tree is not clean: $finalStatus" }
foreach ($artifact in @($summary.artifacts.source, $summary.artifacts.binary, $summary.artifacts.evidence)) {
    $path = Join-Path $OutputDirectory $artifact.name
    if ((Get-Sha256 $path) -ne $artifact.sha256) { throw "Artifact changed during finalization: $($artifact.name)" }
}

Write-Output 'PASS: unsigned v0.1.0 final closure verified.'
Write-Output "SHA256SUMS.txt SHA-256: $checksumSelfHash1"
