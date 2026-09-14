[CmdletBinding()]
param(
    [string]$ExternalRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'external')
)

$ErrorActionPreference = 'Stop'
$engineRepository = 'https://github.com/ggml-org/llama.cpp.git'
$engineCommit = 'd4abd573f6a360201799072384ceec6170fdb60c'
$engineDirectory = Join-Path $ExternalRoot 'llama.cpp'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is required to obtain the pinned llama.cpp source.'
}

New-Item -ItemType Directory -Force -Path $ExternalRoot | Out-Null
if (Test-Path -LiteralPath $engineDirectory) {
    if (-not (Test-Path -LiteralPath (Join-Path $engineDirectory '.git'))) {
        throw "Refusing to reuse non-Git dependency directory: $engineDirectory"
    }
    $origin = (& git -C $engineDirectory remote get-url origin).Trim()
    if ($origin -ne $engineRepository) {
        throw "Refusing dependency with unexpected origin: $origin"
    }
    $dirty = & git -C $engineDirectory status --porcelain
    if ($dirty) {
        throw "Refusing to overwrite modified dependency checkout: $engineDirectory"
    }
    & git -C $engineDirectory fetch --tags origin $engineCommit
} else {
    & git clone $engineRepository $engineDirectory
    if ($LASTEXITCODE -ne 0) { throw 'llama.cpp clone failed.' }
}

& git -C $engineDirectory checkout --detach $engineCommit
if ($LASTEXITCODE -ne 0) { throw 'llama.cpp pinned checkout failed.' }
$actual = (& git -C $engineDirectory rev-parse HEAD).Trim()
if ($actual -ne $engineCommit) {
    throw "Pinned revision verification failed: expected $engineCommit, got $actual"
}

Write-Output "Pinned llama.cpp source is ready: $engineDirectory @ $actual"
Write-Output 'No model was downloaded. Supply models explicitly at run time.'
