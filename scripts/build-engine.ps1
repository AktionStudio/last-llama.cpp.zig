[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('cpu', 'cuda')]
    [string]$Backend,
    [string]$EngineDirectory,
    [string]$BuildDirectory,
    [string]$VsDevCmd = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    [string]$NMakeDirectory = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64',
    [string]$CMakeExecutable = 'C:\Program Files\CMake\bin\cmake.exe',
    [ValidateSet('NMake', 'Ninja')]
    [string]$Generator,
    [ValidateRange(0, 1024)]
    [int]$Jobs = 0,
    [string]$NinjaExecutable,
    [string]$BuildDefaultsPath,
    [string]$TimingOutputPath,
    [string]$CudaToolkitRoot
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$requiredEngineCommit = 'd4abd573f6a360201799072384ceec6170fdb60c'
$expectedNinjaVersion = '1.13.2'

if (-not $EngineDirectory) { $EngineDirectory = Join-Path $projectRoot 'external\llama.cpp' }
if (-not $BuildDefaultsPath) { $BuildDefaultsPath = Join-Path $PSScriptRoot 'build-default.json' }
if (-not (Test-Path -LiteralPath $BuildDefaultsPath -PathType Leaf)) { throw "Build defaults are missing: $BuildDefaultsPath" }

$defaults = Get-Content -LiteralPath $BuildDefaultsPath -Raw | ConvertFrom-Json
if (-not $Generator) { $Generator = [string]$defaults.generator }
if ($Generator -notin @('NMake', 'Ninja')) { throw "Unsupported build generator '$Generator' in $BuildDefaultsPath." }
if ($Jobs -eq 0) {
    $jobsProperty = $defaults.jobs.PSObject.Properties[$Backend]
    if (-not $jobsProperty -or [int]$jobsProperty.Value -lt 1) { throw "Build defaults do not define a positive $Backend job count." }
    $Jobs = [int]$jobsProperty.Value
}

$generatorDirectory = $Generator.ToLowerInvariant()
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $projectRoot "build\engine\$Backend\$generatorDirectory" }
if (-not $TimingOutputPath) { $TimingOutputPath = Join-Path $BuildDirectory 'build-timing.json' }

if (-not (Test-Path -LiteralPath (Join-Path $EngineDirectory '.git') -PathType Container)) {
    throw "Pinned engine checkout is missing: $EngineDirectory. Run scripts/setup-dependencies.ps1 first."
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is required to verify the pinned engine revision.' }
$engineCommit = (& git -C $EngineDirectory rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $engineCommit -ne $requiredEngineCommit) {
    throw "Pinned engine revision mismatch: expected $requiredEngineCommit, got $engineCommit."
}
if (-not (Test-Path -LiteralPath $VsDevCmd -PathType Leaf)) { throw "MSVC environment script is missing: $VsDevCmd" }
if (-not (Test-Path -LiteralPath $CMakeExecutable -PathType Leaf)) { throw "CMake was not found: $CMakeExecutable" }

$nmake = Join-Path $NMakeDirectory 'nmake.exe'
$hostCompiler = Join-Path $NMakeDirectory 'cl.exe'
foreach ($path in @($nmake, $hostCompiler)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required MSVC tool was not found: $path" }
}

function Resolve-Ninja {
    param([string]$RequestedPath)
    $candidates = @()
    if ($RequestedPath) { $candidates += $RequestedPath }
    $candidates += Join-Path $projectRoot '.tools\ninja-1.13.2\ninja.exe'
    foreach ($name in @('ninja.exe', 'ninja')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source) { $candidates += $command.Source }
    }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $version = (& $candidate --version).Trim()
        if ($LASTEXITCODE -eq 0 -and $version -eq $expectedNinjaVersion) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw "Ninja $expectedNinjaVersion was not found. Supply -NinjaExecutable or place that pinned binary under .tools\\ninja-1.13.2."
}

$makeProgram = $nmake
if ($Generator -eq 'Ninja') { $makeProgram = Resolve-Ninja -RequestedPath $NinjaExecutable }

if ($Backend -eq 'cuda') {
    if (-not $CudaToolkitRoot) { throw 'CUDA requires -CudaToolkitRoot pointing to an explicit CUDA toolkit containing bin\\nvcc.exe.' }
    $CudaToolkitRoot = (Resolve-Path -LiteralPath $CudaToolkitRoot -ErrorAction Stop).Path
    $nvcc = Join-Path $CudaToolkitRoot 'bin\nvcc.exe'
    if (-not (Test-Path -LiteralPath $nvcc -PathType Leaf)) { throw "CUDA compiler was not found: $nvcc" }
}

New-Item -ItemType Directory -Force -Path (Split-Path -Path $BuildDirectory -Parent) | Out-Null
$commonOptions = @(
    '-DCMAKE_BUILD_TYPE=Release',
    '-DBUILD_SHARED_LIBS=ON',
    '-DLLAMA_OPENSSL=OFF',
    '-DLLAMA_BUILD_COMMON=ON',
    '-DLLAMA_BUILD_TESTS=OFF',
    '-DLLAMA_BUILD_TOOLS=OFF',
    '-DLLAMA_BUILD_EXAMPLES=OFF',
    '-DLLAMA_BUILD_SERVER=OFF',
    '-DLLAMA_BUILD_APP=OFF',
    '-DLLAMA_BUILD_UI=OFF'
)
$configureArguments = @(
    "-S `"$EngineDirectory`"",
    "-B `"$BuildDirectory`"",
    "-DCMAKE_MAKE_PROGRAM=`"$makeProgram`""
)
if ($Generator -eq 'NMake') { $configureArguments += '-G "NMake Makefiles"' }
else { $configureArguments += '-G Ninja' }
$configureArguments += $commonOptions
$backendOptions = @()
if ($Backend -eq 'cpu') {
    $backendOptions += '-DGGML_CUDA=OFF'
} else {
    $backendOptions += @(
        '-DGGML_CUDA=ON',
        '-DGGML_CUDA_GRAPHS=OFF',
        '-DCMAKE_CUDA_ARCHITECTURES=86',
        '-DCMAKE_CUDA_FLAGS=-Xcompiler=/Zc:preprocessor',
        "-DCUDAToolkit_ROOT=`"$CudaToolkitRoot`"",
        "-DCMAKE_CUDA_COMPILER=`"$nvcc`"",
        "-DCMAKE_CUDA_HOST_COMPILER=`"$hostCompiler`""
    )
}
$configureArguments += $backendOptions

$environmentPrefix = "call `"$VsDevCmd`" && setlocal EnableDelayedExpansion && set `"PATH=$NMakeDirectory;!PATH!`""
if ($Backend -eq 'cuda') { $environmentPrefix += " && set `"CUDA_PATH=$CudaToolkitRoot`" && set `"PATH=!CUDA_PATH!\bin;!PATH!`"" }

$configureTimer = [Diagnostics.Stopwatch]::StartNew()
$configure = "$environmentPrefix && `"$CMakeExecutable`" " + ($configureArguments -join ' ')
& $env:ComSpec /d /s /v:on /c $configure
$configureTimer.Stop()
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed for $Backend/$Generator." }

$buildTimer = [Diagnostics.Stopwatch]::StartNew()
$build = "$environmentPrefix && `"$CMakeExecutable`" --build `"$BuildDirectory`" --target llama llama-common"
if ($Generator -eq 'Ninja') { $build += " --parallel $Jobs" }
& $env:ComSpec /d /s /v:on /c $build
$buildTimer.Stop()
if ($LASTEXITCODE -ne 0) { throw "CMake build failed for $Backend/$Generator." }

foreach ($relative in @('src\llama.lib', 'ggml\src\ggml.lib', 'ggml\src\ggml-base.lib', 'bin\llama.dll', 'bin\ggml.dll', 'bin\ggml-base.dll', 'bin\ggml-cpu.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $BuildDirectory $relative) -PathType Leaf)) { throw "Expected engine output is missing: $relative" }
}
if ($Backend -eq 'cuda' -and -not (Test-Path -LiteralPath (Join-Path $BuildDirectory 'bin\ggml-cuda.dll') -PathType Leaf)) {
    throw 'Expected CUDA engine output is missing: bin\\ggml-cuda.dll'
}

$timingDirectory = Split-Path -Path $TimingOutputPath -Parent
if ($timingDirectory) { New-Item -ItemType Directory -Force -Path $timingDirectory | Out-Null }
[ordered]@{
    backend = $Backend
    generator = $Generator
    requestedJobs = $Jobs
    effectiveJobs = if ($Generator -eq 'Ninja') { $Jobs } else { 1 }
    engineCommit = $engineCommit
    engineDirectory = (Resolve-Path -LiteralPath $EngineDirectory).Path
    buildDirectory = (Resolve-Path -LiteralPath $BuildDirectory).Path
    makeProgram = $makeProgram
    commonOptions = $commonOptions
    backendOptions = $backendOptions
    configureSeconds = [math]::Round($configureTimer.Elapsed.TotalSeconds, 3)
    buildSeconds = [math]::Round($buildTimer.Elapsed.TotalSeconds, 3)
    totalSeconds = [math]::Round(($configureTimer.Elapsed + $buildTimer.Elapsed).TotalSeconds, 3)
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $TimingOutputPath -Encoding utf8

if ($Generator -eq 'Ninja') {
    Write-Output "Pinned $Backend engine is ready with Ninja ($Jobs jobs): $BuildDirectory"
} else {
    Write-Output "Pinned $Backend engine is ready with serial NMake: $BuildDirectory"
}
Write-Output "Timing: $TimingOutputPath"
