[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('cpu', 'cuda')]
    [string]$Backend,
    [Parameter(Mandatory)]
    [string]$Model,
    [Parameter(Mandatory)]
    [ValidateSet('smoke', 'structured', 'lifecycle')]
    [string]$Case,
    [Parameter(Mandatory)]
    [string]$Zig,
    [string]$EngineDirectory,
    [ValidateSet('NMake', 'Ninja')]
    [string]$Generator = 'NMake',
    [string]$Bindings,
    [string]$SchemaLibrary,
    [int]$Cycles = 1,
    [int]$GpuLayers = 1,
    [string]$CudaRuntimeBin,
    [string]$OutputPath,
    [string]$ErrorPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not $EngineDirectory) { $EngineDirectory = Join-Path $projectRoot "build\engine\$Backend\$($Generator.ToLowerInvariant())" }
if (-not $Bindings) { $Bindings = Join-Path $projectRoot 'build\generated\llama.h.zig' }
if (-not $SchemaLibrary) { $SchemaLibrary = Join-Path $projectRoot "build\schema\$Backend\$($Generator.ToLowerInvariant())\last-llama-schema.lib" }
if (-not (Test-Path -LiteralPath $Model -PathType Leaf)) { throw "Model is missing: $Model" }
if (-not (Test-Path -LiteralPath $Bindings -PathType Leaf)) { throw "Generated binding is missing: $Bindings" }
if (-not (Test-Path -LiteralPath $SchemaLibrary -PathType Leaf)) { throw "Schema bridge library is missing: $SchemaLibrary" }
if (-not (Test-Path -LiteralPath (Join-Path $EngineDirectory 'CMakeCache.txt') -PathType Leaf)) { throw "Engine build is missing: $EngineDirectory" }
if ($Backend -eq 'cuda' -and $Case -ne 'smoke') { throw 'The compact initial CUDA gate is smoke only. Run CPU structured and lifecycle gates separately.' }
if ($Backend -eq 'cpu' -and $Case -eq 'smoke') { $fixture = Join-Path $projectRoot 'fixtures\gates\cpu-smoke.json' }
elseif ($Backend -eq 'cuda' -and $Case -eq 'smoke') { $fixture = Join-Path $projectRoot 'fixtures\gates\cuda-smoke.json' }
else { $fixture = Join-Path $projectRoot "fixtures\gates\$Case.json" }

$pushed = $false
try {
    Push-Location $projectRoot
    $pushed = $true

    & $Zig build "-Dbackend=$Backend" "-Dengine-dir=$EngineDirectory" "-Dbindings=$Bindings" "-Dschema-lib=$SchemaLibrary" -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast
    if ($LASTEXITCODE -ne 0) { throw "Zig $Backend runner build failed." }
    $runner = Join-Path $projectRoot "zig-out\bin\last-llama-$Backend.exe"
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Runner was not installed: $runner" }
    $output = if ($OutputPath) { $OutputPath } else { Join-Path (Join-Path $projectRoot 'build\gates') "$Backend-$Case.jsonl" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $output -Parent) | Out-Null
    $previousPath = $env:PATH
    $env:PATH = "$(Split-Path $SchemaLibrary -Parent);$(Join-Path $EngineDirectory 'bin');$env:PATH"
    if ($CudaRuntimeBin) { $env:PATH = "$CudaRuntimeBin;$env:PATH" }
    try {
        $runnerArgs = @($Model, $fixture, $Cycles)
        if ($Backend -eq 'cuda') { $runnerArgs += $GpuLayers }
        if ($ErrorPath) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Path $ErrorPath -Parent) | Out-Null
            & $runner @runnerArgs 1> $output 2> $ErrorPath
        } else {
            & $runner @runnerArgs 1> $output
        }
        if ($LASTEXITCODE -ne 0) { throw "Runner exited with $LASTEXITCODE." }
    } finally {
        $env:PATH = $previousPath
    }
    & python (Join-Path $projectRoot 'scripts\verify-gate.py') --case $Case --backend $Backend --jsonl $output
    if ($LASTEXITCODE -ne 0) { throw "Gate verifier failed for $Backend/$Case." }
    Write-Output "PASS: $Backend $Case gate"
    Write-Output "JSONL evidence: $output"
} finally {
    if ($pushed) { Pop-Location }
}
