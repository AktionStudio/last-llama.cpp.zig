[CmdletBinding()]
param(
    [string]$Cli = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\last-llama.exe'),
    [string]$FakeWorker = (Join-Path (Split-Path $PSScriptRoot -Parent) 'zig-out\bin\fake-worker.exe')
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path -LiteralPath $Cli -PathType Leaf)) { throw "CLI is missing: $Cli" }
if (-not (Test-Path -LiteralPath $FakeWorker -PathType Leaf)) { throw "Fake worker is missing: $FakeWorker" }

$testRoot = Join-Path $projectRoot ("build\cli-integration\" + [guid]::NewGuid().ToString('N'))
$resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
$resolvedBuildRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'build\cli-integration'))
if (-not $resolvedTestRoot.StartsWith($resolvedBuildRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to create a CLI test directory outside build\cli-integration.'
}

function Invoke-CliSuccess {
    param([string[]]$Arguments)
    $output = & $Cli @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "CLI failed for '$($Arguments -join ' ')': $($output -join [Environment]::NewLine)" }
    return ($output -join [Environment]::NewLine)
}

function Invoke-CliFailure {
    param([string[]]$Arguments, [string]$Contains)
    $output = & $Cli @Arguments 2>&1
    if ($LASTEXITCODE -eq 0) { throw "CLI unexpectedly succeeded for '$($Arguments -join ' ')'." }
    $text = $output -join [Environment]::NewLine
    if ($text -notlike "*$Contains*") { throw "CLI failure did not contain '$Contains': $text" }
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot 'models'), (Join-Path $testRoot 'workers'), (Join-Path $testRoot 'runtime\cpu'), (Join-Path $testRoot 'runtime\cuda') | Out-Null
    foreach ($name in @('llama.dll', 'llama-common.dll', 'ggml.dll', 'ggml-base.dll', 'ggml-cpu.dll', 'last-llama-schema.dll')) {
        New-Item -ItemType File -Path (Join-Path $testRoot "runtime\cpu\$name"), (Join-Path $testRoot "runtime\cuda\$name") | Out-Null
    }
    foreach ($name in @('ggml-cuda.dll', 'cublas64_13.dll', 'cublasLt64_13.dll')) {
        New-Item -ItemType File -Path (Join-Path $testRoot "runtime\cuda\$name") | Out-Null
    }
    Copy-Item -LiteralPath $FakeWorker -Destination (Join-Path $testRoot 'workers\last-llama-cpu.exe')
    Copy-Item -LiteralPath $FakeWorker -Destination (Join-Path $testRoot 'workers\last-llama-cuda.exe')
    New-Item -ItemType File -Path (Join-Path $testRoot 'models\fake.gguf') | Out-Null
    $config = [ordered]@{
        default_model = 'fake'
        backend = 'auto'
        generation = [ordered]@{ temperature = 0.7 }
        workers = [ordered]@{
            cpu = [ordered]@{ path = 'workers\last-llama-cpu.exe' }
            cuda = [ordered]@{ path = 'workers\last-llama-cuda.exe' }
        }
        models = [ordered]@{
            fake = [ordered]@{
                path = 'models\fake.gguf'
                generation = [ordered]@{ temperature = 0.5; max_tokens = 77 }
            }
            global = [ordered]@{ path = 'models\fake.gguf' }
        }
    }
    $configPath = Join-Path $testRoot 'last-llama.json'
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

    $packagedCli = Join-Path $testRoot 'last-llama.exe'
    Copy-Item -LiteralPath $Cli -Destination $packagedCli
    $Cli = $packagedCli
    $discovered = Invoke-CliSuccess @('models')
    if ($discovered -notlike '*fake*fake.gguf*') { throw 'Executable-relative config discovery failed.' }

    $models = Invoke-CliSuccess @('models', '--config', $configPath)
    if ($models -notlike '*fake*fake.gguf*') { throw 'models did not resolve the alias path.' }
    $describe = Invoke-CliSuccess @('describe', 'fake', '--config', $configPath)
    if ($describe -notlike '*exists: yes*' -or $describe -notlike '*temperature: 0.5*' -or $describe -notlike '*max_tokens: 77*') { throw 'describe did not show resolved model settings.' }
    $modelsShow = Invoke-CliSuccess @('models', 'show', 'fake', '--config', $configPath)
    if ($modelsShow -ne $describe) { throw 'models show did not match describe resolution.' }
    $cpuRuntime = [System.IO.Path]::GetFullPath((Join-Path $testRoot 'runtime\cpu'))
    $cudaRuntime = [System.IO.Path]::GetFullPath((Join-Path $testRoot 'runtime\cuda'))
    $cpuInspect = Invoke-CliSuccess @('inspect', 'cpu', '--config', $configPath, '--json') | ConvertFrom-Json
    $cudaInspect = Invoke-CliSuccess @('inspect', 'cuda', '--config', $configPath, '--json') | ConvertFrom-Json
    if ($cpuInspect.observed_path -ne $cpuRuntime -or $cpuInspect.observed_path -like '*runtime\cuda*') { throw "CPU child PATH was not isolated: $($cpuInspect.observed_path)" }
    if ($cudaInspect.observed_path -ne $cudaRuntime -or $cudaInspect.observed_path -like '*runtime\cpu*') { throw "CUDA child PATH was not isolated: $($cudaInspect.observed_path)" }
    $doctor = Invoke-CliSuccess @('doctor', '--config', $configPath)
    if ($doctor -notlike '*PASS*cpu*required DLL present: llama-common.dll*' -or $doctor -notlike '*PASS*cuda*required DLL present: cublasLt64_13.dll*') { throw 'doctor did not pass the verified CPU/CUDA dependency closure.' }
    if ($doctor -like '*cudart64_13.dll*') { throw 'doctor still treated absent cudart64_13.dll as part of the package.' }

    $cudart = Join-Path $testRoot 'runtime\cuda\cudart64_13.dll'
    New-Item -ItemType File -Path $cudart | Out-Null
    $optionalDoctor = Invoke-CliSuccess @('doctor', '--config', $configPath)
    if ($optionalDoctor -notlike '*WARN*cuda*non-required DLL present: cudart64_13.dll*') { throw 'doctor did not classify the stale CUDA DLL as non-required.' }
    Remove-Item -LiteralPath $cudart -Force

    $cpuCommon = Join-Path $testRoot 'runtime\cpu\llama-common.dll'
    Move-Item -LiteralPath $cpuCommon -Destination "$cpuCommon.disabled"
    Invoke-CliFailure @('doctor', '--config', $configPath) 'required DLL missing: llama-common.dll'
    Move-Item -LiteralPath "$cpuCommon.disabled" -Destination $cpuCommon

    $cudaBlasLt = Join-Path $testRoot 'runtime\cuda\cublasLt64_13.dll'
    Move-Item -LiteralPath $cudaBlasLt -Destination "$cudaBlasLt.disabled"
    Invoke-CliFailure @('doctor', '--config', $configPath) 'required DLL missing: cublasLt64_13.dll'
    Move-Item -LiteralPath "$cudaBlasLt.disabled" -Destination $cudaBlasLt

    $cpuGgml = Join-Path $testRoot 'runtime\cpu\ggml-cpu.dll'
    Move-Item -LiteralPath $cpuGgml -Destination "$cpuGgml.disabled"
    Invoke-CliFailure @('doctor', '--config', $configPath) 'required DLL missing: ggml-cpu.dll'
    Move-Item -LiteralPath "$cpuGgml.disabled" -Destination $cpuGgml

    $rootGgml = Join-Path $testRoot 'workers\ggml.dll'
    New-Item -ItemType File -Path $rootGgml | Out-Null
    Invoke-CliFailure @('doctor', '--config', $configPath) 'worker directory contains unselected runtime DLL: ggml.dll'
    Remove-Item -LiteralPath $rootGgml -Force

    $cpuExtra = Join-Path $testRoot 'runtime\cpu-extra'
    New-Item -ItemType Directory -Path $cpuExtra | Out-Null
    $config.workers.cpu.library_dirs = @('runtime\cpu', 'runtime\cpu-extra')
    $overrideConfigPath = Join-Path $testRoot 'last-llama.override.json'
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $overrideConfigPath -Encoding utf8NoBOM
    $overrideInspect = Invoke-CliSuccess @('inspect', 'cpu', '--config', $overrideConfigPath, '--json') | ConvertFrom-Json
    $expectedOverridePath = "$cpuRuntime;$([System.IO.Path]::GetFullPath($cpuExtra))"
    if ($overrideInspect.observed_path -ne $expectedOverridePath -or $overrideInspect.observed_path -like '*runtime\cuda*') { throw "Explicit library override was not isolated: $($overrideInspect.observed_path)" }

    $human = Invoke-CliSuccess @('run', '--config', $configPath, '--prompt', 'hello')
    if ($human -ne 'fake response') { throw "Unexpected human output: $human" }
    $machine = Invoke-CliSuccess @('run', 'fake', '--config', $configPath, '--prompt', 'hello', '--temperature', '0.2', '--json') | ConvertFrom-Json
    if ([Math]::Abs([double]$machine.observed_temperature - 0.2) -gt 0.0001 -or $machine.observed_max_tokens -ne 77 -or $machine.backend -ne 'cpu') { throw "CLI/model/global/default precedence or auto CPU selection changed: $($machine | ConvertTo-Json -Compress)" }
    $global = Invoke-CliSuccess @('run', 'global', '--config', $configPath, '--prompt', 'hello', '--json') | ConvertFrom-Json
    if ([Math]::Abs([double]$global.observed_temperature - 0.7) -gt 0.0001 -or $global.observed_max_tokens -ne 32 -or $global.observed_context_size -ne 512) { throw 'Global or built-in generation fallback changed.' }
    $promptPath = Join-Path $testRoot 'prompt.txt'
    'hello from file' | Set-Content -LiteralPath $promptPath -Encoding utf8NoBOM
    $promptFileResult = Invoke-CliSuccess @('run', 'fake', '--config', $configPath, '--prompt-file', $promptPath)
    if ($promptFileResult -ne 'fake response') { throw 'Prompt-file request failed.' }
    $schema = Invoke-CliSuccess @('run', 'fake', '--config', $configPath, '--prompt', 'hello', '--schema', '{"type":"object"}', '--json') | ConvertFrom-Json
    if (-not $schema.observed_schema -or -not $schema.observed_expect_json) { throw 'Schema request did not preserve schema_json and expect_json.' }
    $direct = Invoke-CliSuccess @('run', (Join-Path $testRoot 'models\fake.gguf'), '--config', $configPath, '--backend', 'cpu', '--prompt', 'hello')
    if ($direct -ne 'fake response') { throw 'Direct model path did not reach the worker.' }

    Invoke-CliFailure @('run', 'fake', '--config', $configPath, '--backend', 'cuda', '--prompt', 'hello') 'gpu_layers'
    $cuda = Invoke-CliSuccess @('run', 'fake', '--config', $configPath, '--backend', 'cuda', '--gpu-layers', '1', '--prompt', 'hello', '--json') | ConvertFrom-Json
    if ($cuda.backend -ne 'cuda') { throw 'Explicit CUDA did not reach the CUDA fake worker.' }
    Invoke-CliFailure @('run', 'fake', '--config', $configPath, '--backend', 'cpu', '--prompt', 'MALFORMED') 'malformed worker output'
    Invoke-CliFailure @('run', 'fake', '--config', $configPath, '--backend', 'cpu', '--prompt', 'MULTIPLE') 'MultipleWorkerRows'
    Invoke-CliFailure @('run', (Join-Path $testRoot 'models\missing.gguf'), '--config', $configPath, '--backend', 'cpu', '--prompt', 'hello') 'existing model path'

    Move-Item -LiteralPath (Join-Path $testRoot 'workers\last-llama-cuda.exe') -Destination (Join-Path $testRoot 'workers\last-llama-cuda.disabled')
    Invoke-CliFailure @('run', 'fake', '--config', $configPath, '--backend', 'cuda', '--gpu-layers', '1', '--prompt', 'hello') 'explicitly requested CUDA is unavailable'
    $fallback = Invoke-CliSuccess @('run', 'fake', '--config', $configPath, '--backend', 'auto', '--gpu-layers', '1', '--prompt', 'hello', '--json') | ConvertFrom-Json
    if ($fallback.backend -ne 'cpu') { throw 'Auto did not fall back to CPU when CUDA was unavailable.' }

    Write-Output 'PASS: CLI fake-worker integration tests'
} finally {
    if (Test-Path -LiteralPath $resolvedTestRoot) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
