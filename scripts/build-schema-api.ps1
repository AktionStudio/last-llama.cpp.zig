[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('cpu', 'cuda')]
    [string]$Backend,
    [string]$EngineDirectory,
    [ValidateSet('NMake', 'Ninja')]
    [string]$Generator = 'NMake',
    [string]$SourceDirectory,
    [string]$OutputDirectory,
    [string]$VsDevCmd = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not $EngineDirectory) { $EngineDirectory = Join-Path $projectRoot "build\engine\$Backend\$($Generator.ToLowerInvariant())" }
if (-not $SourceDirectory) { $SourceDirectory = Join-Path $projectRoot 'external\llama.cpp' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot "build\schema\$Backend\$($Generator.ToLowerInvariant())" }
foreach ($path in @($EngineDirectory, $SourceDirectory, $VsDevCmd)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required path is missing: $path" }
}
foreach ($relative in @('common\llama-common.lib', 'common\llama-common-base.lib', 'src\llama.lib', 'ggml\src\ggml.lib', 'ggml\src\ggml-cpu.lib', 'ggml\src\ggml-base.lib')) {
    if (-not (Test-Path -LiteralPath (Join-Path $EngineDirectory $relative) -PathType Leaf)) {
        throw "The engine was not built with common support: $relative"
    }
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$source = Join-Path $projectRoot 'src\schema\schema_api.cpp'
$object = Join-Path $OutputDirectory 'schema_api.obj'
$dll = Join-Path $OutputDirectory 'last-llama-schema.dll'
$library = Join-Path $OutputDirectory 'last-llama-schema.lib'
$command = "call `"$VsDevCmd`" && cl /nologo /std:c++17 /EHsc /MD /O2 /LD /DLAB_SCHEMA_EXPORTS=1 /DLLAMA_SHARED=1 /DGGML_SHARED=1 /I `"$SourceDirectory\common`" /I `"$SourceDirectory\vendor`" /I `"$SourceDirectory\include`" /I `"$SourceDirectory\ggml\include`" `"$source`" /Fo:`"$object`" /Fe:`"$dll`" /link /IMPLIB:`"$library`" `"$EngineDirectory\common\llama-common.lib`" `"$EngineDirectory\common\llama-common-base.lib`" `"$EngineDirectory\src\llama.lib`" `"$EngineDirectory\ggml\src\ggml.lib`" `"$EngineDirectory\ggml\src\ggml-cpu.lib`" `"$EngineDirectory\ggml\src\ggml-base.lib`""
& $env:ComSpec /d /s /c $command
if ($LASTEXITCODE -ne 0) { throw "Schema bridge build failed for $Backend." }
foreach ($path in @($dll, $library)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Schema bridge output is missing: $path" }
}
Write-Output "Guarded schema bridge is ready: $library"
