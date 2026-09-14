[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DependencyRoot,
    [Parameter(Mandatory)] [string]$Model,
    [Parameter(Mandatory)] [string]$WorkRoot,
    [string]$OutputDirectory,
    [string]$Zig = (Join-Path $DependencyRoot '.tools\zig\zig.exe'),
    [string]$HeaderZig = (Join-Path $DependencyRoot '.tools\zig-x86_64-windows-0.14.1\zig.exe'),
    [string]$Ninja = (Join-Path $DependencyRoot '.tools\ninja-1.13.2\ninja.exe'),
    [string]$CudaToolkitRoot = (Join-Path $DependencyRoot '.tools\cuda-13.3.1'),
    [string]$EngineSource = (Join-Path $DependencyRoot 'external\llama.cpp'),
    [string]$CMake = 'C:\Program Files\CMake\bin\cmake.exe',
    [string]$Dumpbin = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64\dumpbin.exe',
    [string[]]$AdditionalIsolationPath = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$releaseVersion = 'v0.1.0'
$engineRevision = 'd4abd573f6a360201799072384ceec6170fdb60c'
$modelSha256 = '48ab3034d0dd401fbc721eb1df3217902fee7dab9078992d66431f09b7750201'
$sourceRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$DependencyRoot = [IO.Path]::GetFullPath($DependencyRoot)
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
$Model = [IO.Path]::GetFullPath($Model)
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $sourceRoot 'release\v0.1.0' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

$sourceZip = Join-Path $OutputDirectory 'last-llama-v0.1.0-source.zip'
$binaryZip = Join-Path $OutputDirectory 'last-llama-windows-x64-v0.1.0.zip'
$evidenceZip = Join-Path $OutputDirectory 'last-llama-v0.1.0-evidence.zip'
$summaryPath = Join-Path $OutputDirectory 'qualification-summary.json'
$cloneRoot = Join-Path $WorkRoot 'clean-source-clone'
$buildRoot = Join-Path $WorkRoot 'fresh-build'
$rawRoot = Join-Path $WorkRoot 'raw-evidence'
$sanitizedRoot = Join-Path $WorkRoot 'sanitized-evidence'
$packageStage = Join-Path $WorkRoot 'package-stage'
$sourceExtract = Join-Path $WorkRoot 'source-archive-extract'
$distributionRoot = Join-Path $WorkRoot 'Extracted Distribution With Spaces'
$qualificationRoot = Join-Path $WorkRoot 'qualification inputs'
$checks = [Collections.Generic.List[object]]::new()
$hiddenPaths = [Collections.Generic.List[object]]::new()
$allowedReleaseScripts = @(
    'scripts/build-default.json',
    'scripts/build-engine.ps1',
    'scripts/build-schema-api.ps1',
    'scripts/finalize-release.ps1',
    'scripts/generate-bindings.ps1',
    'scripts/prepare-release.ps1',
    'scripts/run-gate.ps1',
    'scripts/setup-dependencies.ps1',
    'scripts/test-cli.ps1',
    'scripts/verify-gate.py'
)

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Add-Check([string]$Name, [string]$Details) {
    $checks.Add([ordered]@{ name = $Name; status = 'PASS'; details = $Details })
}

function Assert-Leaf([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Description is missing: $Path" }
}

function Assert-Directory([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Description is missing: $Path" }
}

function Invoke-Checked([string]$Program, [string[]]$Arguments, [string]$Description) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

function Get-RelativeFiles([string]$Root) {
    $resolved = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return @(Get-ChildItem -LiteralPath $resolved -Recurse -File | ForEach-Object {
        $_.FullName.Substring($resolved.Length + 1).Replace('\', '/')
    } | Sort-Object)
}

function Get-FileRecord([string]$Root, [string]$Relative, [string]$Origin, [string]$License) {
    $path = Join-Path $Root $Relative
    return [ordered]@{
        path = $Relative.Replace('\', '/')
        bytes = (Get-Item -LiteralPath $path).Length
        sha256 = Get-Sha256 $path
        origin = $Origin
        license_notice = $License
    }
}

function Invoke-WorkerFile([string]$Worker, [string]$ModelPath, [string]$Fixture, [int]$Cycles, [string]$LibraryDirectory, [string]$Output, [string]$ErrorOutput) {
    $savedPath = $env:PATH
    $env:PATH = "$LibraryDirectory;C:\Windows\System32;C:\Windows"
    try {
        & $Worker $ModelPath $Fixture $Cycles 1> $Output 2> $ErrorOutput
        if ($LASTEXITCODE -ne 0) { throw "Worker gate failed with exit code $LASTEXITCODE." }
    } finally {
        $env:PATH = $savedPath
    }
}

function Read-JsonLines([string]$Path) {
    return @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 100 })
}

function Assert-ModuleOrigins($Runtime, [string]$ExpectedRoot, [string]$ForbiddenRoot) {
    $expected = [IO.Path]::GetFullPath($ExpectedRoot).TrimEnd('\') + '\'
    $forbidden = [IO.Path]::GetFullPath($ForbiddenRoot).TrimEnd('\') + '\'
    foreach ($module in @($Runtime.runtime.loaded_modules)) {
        $modulePath = [IO.Path]::GetFullPath([string]$module.path)
        if (-not $modulePath.StartsWith($expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Module escaped selected backend directory: $($module.name) -> $modulePath"
        }
        if ($modulePath.StartsWith($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Module cross-loaded from forbidden backend: $($module.name) -> $modulePath"
        }
    }
}

function Hide-Path([string]$Path) {
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($protected in @($sourceRoot, $WorkRoot, $OutputDirectory, 'C:\', 'C:\Windows')) {
        if ($resolved.Equals([IO.Path]::GetFullPath($protected).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to hide protected path: $resolved"
        }
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return }
    $parent = Split-Path $resolved -Parent
    $leaf = Split-Path $resolved -Leaf
    $hidden = Join-Path $parent ($leaf + '.hidden-for-v0.1.0-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $hidden) { throw "Isolation destination already exists: $hidden" }
    Rename-Item -LiteralPath $resolved -NewName (Split-Path $hidden -Leaf)
    if ((Test-Path -LiteralPath $resolved) -or -not (Test-Path -LiteralPath $hidden)) { throw "Failed to enforce path isolation: $resolved" }
    $hiddenPaths.Add([ordered]@{ original = $resolved; hidden = $hidden; active = $true })
}

function Restore-HiddenPaths {
    for ($index = $hiddenPaths.Count - 1; $index -ge 0; $index--) {
        $item = $hiddenPaths[$index]
        if (-not $item.active) { continue }
        if (-not (Test-Path -LiteralPath $item.hidden -PathType Container)) { throw "Hidden path disappeared: $($item.hidden)" }
        if (Test-Path -LiteralPath $item.original) { throw "Cannot restore over existing path: $($item.original)" }
        Rename-Item -LiteralPath $item.hidden -NewName (Split-Path $item.original -Leaf)
        if (-not (Test-Path -LiteralPath $item.original) -or (Test-Path -LiteralPath $item.hidden)) { throw "Failed to restore path: $($item.original)" }
        $item.active = $false
    }
}

function ConvertTo-SanitizedJson($Value) {
    $text = $Value | ConvertTo-Json -Depth 100
    $replacements = [ordered]@{
        $sourceRoot = '${REPOSITORY}'
        $cloneRoot = '${CLEAN_SOURCE}'
        $DependencyRoot = '${DEPENDENCIES}'
        $WorkRoot = '${WORK}'
        $Model = '${MODEL}'
    }
    foreach ($entry in $replacements.GetEnumerator()) {
        $text = $text.Replace($entry.Key, $entry.Value).Replace($entry.Key.Replace('\', '\\'), $entry.Value)
    }
    return $text
}

function Get-Imports([string]$Path) {
    $output = & $Dumpbin /nologo /dependents $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed for $Path" }
    return @($output | ForEach-Object { if ($_ -match '^\s+([A-Za-z0-9_.-]+\.dll)\s*$') { $Matches[1].ToLowerInvariant() } } | Sort-Object -Unique)
}

function Assert-Markdown([string]$Root) {
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.md' -File) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($text -match 'C:\\Users\\') { $failures.Add("workstation path: $($file.FullName)") }
        if ($text -match '(?i)LastX') { $failures.Add("private product reference: $($file.FullName)") }
        if ($text -match '(?i)archive/pre-owned|pre-owned-llama-interface') { $failures.Add("private/archive ref: $($file.FullName)") }
        if ($text -match '(?i)last-llama\.cpp\.zig-dev|last-llama-release-verify') { $failures.Add("development repository ref: $($file.FullName)") }
        foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\(([^)]+)\)')) {
            $link = $match.Groups[1].Value.Split('#')[0]
            if (-not $link -or $link -match '^(?i:https?:|mailto:)') { continue }
            $candidate = [IO.Path]::GetFullPath((Join-Path $file.DirectoryName ([Uri]::UnescapeDataString($link))))
            if (-not (Test-Path -LiteralPath $candidate)) { $failures.Add("broken link: $($file.FullName) -> $link") }
        }
    }
    if ($failures.Count) { throw ($failures -join [Environment]::NewLine) }
}

if (Test-Path -LiteralPath $WorkRoot) { throw "WorkRoot must be fresh and absent: $WorkRoot" }
foreach ($path in @($Zig, $HeaderZig, $Ninja, $CMake, $Dumpbin, $Model)) { Assert-Leaf $path 'Required release input' }
foreach ($path in @($DependencyRoot, $CudaToolkitRoot, $EngineSource)) { Assert-Directory $path 'Required release directory' }

$sourceStatus = (& git -C $sourceRoot status --porcelain=v1 --untracked-files=all) -join "`n"
if ($LASTEXITCODE -ne 0 -or $sourceStatus) { throw 'Release source must be a clean Git worktree.' }
$commit = (& git -C $sourceRoot rev-parse --verify HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$' -or $commit -eq ('0' * 40)) { throw "Release commit is missing, abbreviated, or unknown: $commit" }
if ($commit -match '(?i)uncommitted|unknown') { throw "Invalid release revision: $commit" }
$engineHead = (& git -C $EngineSource rev-parse --verify HEAD).Trim()
$engineStatus = (& git -C $EngineSource status --porcelain=v1 --untracked-files=no) -join "`n"
if ($engineHead -ne $engineRevision -or $engineStatus) { throw 'Pinned llama.cpp checkout is missing, dirty, or at the wrong commit.' }
if ((Get-Sha256 $Model) -ne $modelSha256) { throw 'Qualification model hash does not match the declared SmolLM2 fixture.' }
if ((& $Zig version).Trim() -ne '0.17.0-dev.1676+c9dc9b798') { throw 'Runner Zig version mismatch.' }
if ((& $HeaderZig version).Trim() -ne '0.14.1') { throw 'Header Zig version mismatch.' }
if ((& $Ninja --version).Trim() -ne '1.13.2') { throw 'Ninja version mismatch.' }
$nvcc = Join-Path $CudaToolkitRoot 'bin\nvcc.exe'
Assert-Leaf $nvcc 'CUDA compiler'
$nvccVersion = (& $nvcc --version 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $nvccVersion -notmatch 'release 13\.3' -or $nvccVersion -notmatch 'V13\.3\.73') { throw 'NVCC version mismatch.' }

New-Item -ItemType Directory -Path $WorkRoot | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDirectory, $rawRoot, $sanitizedRoot | Out-Null

try {
    $tracked = @(& git -C $sourceRoot ls-files)
    $forbidden = @($tracked | Where-Object {
        ($_.StartsWith('models/') -and $_ -ne 'models/README.md') -or
        ($_.StartsWith('scripts/') -and $_ -notin $allowedReleaseScripts) -or
        $_ -match '^(external|build|results|evidence|temp|release|\.tools|zig-out|\.zig-cache)/' -or
        $_ -match '(?i)\.(exe|dll|lib|exp|pdb|obj|gguf)$' -or
        $_ -match '^docs/owned-interface/(baseline/|README\.md$|REQUIREMENTS\.md$|capture-supplemental\.py$)'
    })
    if ($forbidden.Count) { throw "Forbidden tracked release paths:`n$($forbidden -join "`n")" }
    Assert-Markdown $sourceRoot
    Add-Check 'source hygiene' "$($tracked.Count) explicitly curated tracked files; no forbidden source or public-documentation references"
    Add-Check 'documentation validation' 'all public Markdown relative links and forbidden-reference scans passed'

    Invoke-Checked git @('clone', '--no-hardlinks', '--no-local', '--branch', (& git -C $sourceRoot branch --show-current).Trim(), $sourceRoot, $cloneRoot) 'Clean clone'
    if ((& git -C $cloneRoot rev-parse HEAD).Trim() -ne $commit) { throw 'Clean clone did not resolve to the release commit.' }
    if ((& git -C $cloneRoot status --porcelain=v1 --untracked-files=all) -join "`n") { throw 'Clean clone is not clean.' }

    $inventory = foreach ($relative in @(& git -C $cloneRoot ls-files)) {
        $path = Join-Path $cloneRoot $relative
        [ordered]@{ path = $relative; bytes = (Get-Item -LiteralPath $path).Length; sha256 = Get-Sha256 $path }
    }
    [long]$trackedBytes = 0
    foreach ($item in $inventory) { $trackedBytes += [long]$item.bytes }
    $inventorySummary = [ordered]@{
        release_commit = $commit
        git_status_porcelain = ''
        ignored_files = @(& git -C $cloneRoot status --ignored --porcelain=v1 | Where-Object { $_ -like '!!*' })
        tracked_file_count = $inventory.Count
        tracked_bytes = $trackedBytes
        largest_tracked_files = @($inventory | Sort-Object bytes -Descending | Select-Object -First 20)
        files = @($inventory)
    }
    ConvertTo-SanitizedJson $inventorySummary | Set-Content -LiteralPath (Join-Path $sanitizedRoot 'source-inventory.json') -Encoding utf8NoBOM

    $testCache = Join-Path $buildRoot 'zig-tests-cache'
    Push-Location $cloneRoot
    try {
        Invoke-Checked $Zig @('build', '--cache-dir', $testCache, 'test') 'Dependency-free runtime tests'
        Invoke-Checked $Zig @('build', '--cache-dir', $testCache, 'cli-test') 'Dependency-free CLI tests'
    } finally { Pop-Location }
    Add-Check 'clean-clone/source tests' 'clean clone at exact release commit passed dependency-free runtime and CLI tests'

    $bindings = Join-Path $buildRoot 'generated\llama.h.zig'
    & (Join-Path $cloneRoot 'scripts\generate-bindings.ps1') -ZigHeader $HeaderZig -EngineDirectory $EngineSource -OutputPath $bindings
    if ($LASTEXITCODE -ne 0) { throw 'Binding generation failed.' }

    $cpuEngine = Join-Path $buildRoot 'engine\cpu\ninja'
    $cudaEngine = Join-Path $buildRoot 'engine\cuda\ninja'
    $cpuTiming = Join-Path $rawRoot 'cpu-build-timing.json'
    $cudaTiming = Join-Path $rawRoot 'cuda-build-timing.json'
    & (Join-Path $cloneRoot 'scripts\build-engine.ps1') -Backend cpu -Generator Ninja -Jobs 16 -NinjaExecutable $Ninja -EngineDirectory $EngineSource -BuildDirectory $cpuEngine -TimingOutputPath $cpuTiming -CMakeExecutable $CMake
    if ($LASTEXITCODE -ne 0) { throw 'Fresh CPU Ninja build failed.' }
    Add-Check 'CPU clean build' 'fresh Ninja 1.13.2 build at 16 jobs passed'
    & (Join-Path $cloneRoot 'scripts\build-engine.ps1') -Backend cuda -Generator Ninja -Jobs 16 -NinjaExecutable $Ninja -EngineDirectory $EngineSource -BuildDirectory $cudaEngine -TimingOutputPath $cudaTiming -CudaToolkitRoot $CudaToolkitRoot -CMakeExecutable $CMake
    if ($LASTEXITCODE -ne 0) { throw 'Fresh CUDA Ninja build failed.' }
    Add-Check 'CUDA clean build' 'fresh Ninja 1.13.2 build at 16 jobs passed'

    $cpuSchemaDir = Join-Path $buildRoot 'schema\cpu\ninja'
    $cudaSchemaDir = Join-Path $buildRoot 'schema\cuda\ninja'
    & (Join-Path $cloneRoot 'scripts\build-schema-api.ps1') -Backend cpu -Generator Ninja -EngineDirectory $cpuEngine -SourceDirectory $EngineSource -OutputDirectory $cpuSchemaDir
    if ($LASTEXITCODE -ne 0) { throw 'CPU schema bridge build failed.' }
    & (Join-Path $cloneRoot 'scripts\build-schema-api.ps1') -Backend cuda -Generator Ninja -EngineDirectory $cudaEngine -SourceDirectory $EngineSource -OutputDirectory $cudaSchemaDir
    if ($LASTEXITCODE -ne 0) { throw 'CUDA schema bridge build failed.' }

    $cpuPrefix = Join-Path $buildRoot 'zig-cpu'
    $cudaPrefix = Join-Path $buildRoot 'zig-cuda'
    Push-Location $cloneRoot
    try {
        $commonCpu = @('build', '-Dtarget=x86_64-windows-msvc', '-Doptimize=ReleaseFast', '-Dbackend=cpu', "-Dengine-dir=$cpuEngine", "-Dbindings=$bindings", "-Dschema-lib=$(Join-Path $cpuSchemaDir 'last-llama-schema.lib')", "-Druntime-revision=$commit", '--prefix', $cpuPrefix, '--cache-dir', (Join-Path $buildRoot 'zig-cpu-cache'))
        Invoke-Checked $Zig $commonCpu 'CPU runner release build'
        $schemaTestPath = $env:PATH
        $env:PATH = "$cpuSchemaDir;$(Join-Path $cpuEngine 'bin');$schemaTestPath"
        try {
            Invoke-Checked $Zig ($commonCpu + 'schema-test') 'Schema tests against release CPU build'
        } finally { $env:PATH = $schemaTestPath }
        Invoke-Checked $Zig ($commonCpu + 'fake-worker') 'Fake worker release build'
        $commonCuda = @('build', '-Dtarget=x86_64-windows-msvc', '-Doptimize=ReleaseFast', '-Dbackend=cuda', "-Dengine-dir=$cudaEngine", "-Dbindings=$bindings", "-Dschema-lib=$(Join-Path $cudaSchemaDir 'last-llama-schema.lib')", "-Druntime-revision=$commit", '--prefix', $cudaPrefix, '--cache-dir', (Join-Path $buildRoot 'zig-cuda-cache'))
        Invoke-Checked $Zig $commonCuda 'CUDA runner release build'
    } finally { Pop-Location }

    & (Join-Path $cloneRoot 'scripts\test-cli.ps1') -Cli (Join-Path $cpuPrefix 'bin\last-llama.exe') -FakeWorker (Join-Path $cpuPrefix 'bin\fake-worker.exe')
    if ($LASTEXITCODE -ne 0) { throw 'CLI package integration tests failed.' }

    if (Test-Path -LiteralPath $sourceZip) { throw "Refusing to overwrite source archive: $sourceZip" }
    Invoke-Checked git @('-C', $cloneRoot, 'archive', '--format=zip', "--prefix=last-llama-v0.1.0/", "--output=$sourceZip", 'HEAD') 'Source archive creation'
    New-Item -ItemType Directory -Path $sourceExtract | Out-Null
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $sourceExtract
    $sourceTree = Join-Path $sourceExtract 'last-llama-v0.1.0'
    $archiveFiles = Get-RelativeFiles $sourceTree
    $trackedFiles = @(& git -C $cloneRoot ls-files | Sort-Object)
    if (($archiveFiles -join "`n") -ne ($trackedFiles -join "`n")) { throw 'Source archive file inventory differs from the commit tree.' }
    foreach ($relative in $trackedFiles) {
        $blob = (& git -C $cloneRoot rev-parse "HEAD:$relative").Trim()
        $archiveBlob = (& git -C $cloneRoot hash-object (Join-Path $sourceTree $relative)).Trim()
        if ($blob -ne $archiveBlob) { throw "Source archive content mismatch: $relative" }
    }
    Add-Check 'source ZIP verification' 'complete archive inventory and every file blob match the release commit'

    New-Item -ItemType Directory -Path $packageStage | Out-Null
    $runtimeCpu = Join-Path $packageStage 'runtime\cpu'
    $runtimeCuda = Join-Path $packageStage 'runtime\cuda'
    New-Item -ItemType Directory -Path $runtimeCpu, $runtimeCuda, (Join-Path $packageStage 'LICENSES'), (Join-Path $packageStage 'models') | Out-Null
    Copy-Item -LiteralPath (Join-Path $cpuPrefix 'bin\last-llama.exe') -Destination (Join-Path $packageStage 'last-llama.exe')
    Copy-Item -LiteralPath (Join-Path $cpuPrefix 'bin\last-llama-cpu.exe') -Destination (Join-Path $packageStage 'last-llama-cpu.exe')
    Copy-Item -LiteralPath (Join-Path $cudaPrefix 'bin\last-llama-cuda.exe') -Destination (Join-Path $packageStage 'last-llama-cuda.exe')
    foreach ($name in @('llama.dll', 'llama-common.dll', 'ggml.dll', 'ggml-base.dll', 'ggml-cpu.dll')) {
        Copy-Item -LiteralPath (Join-Path $cpuEngine "bin\$name") -Destination (Join-Path $runtimeCpu $name)
        Copy-Item -LiteralPath (Join-Path $cudaEngine "bin\$name") -Destination (Join-Path $runtimeCuda $name)
    }
    Copy-Item -LiteralPath (Join-Path $cpuSchemaDir 'last-llama-schema.dll') -Destination (Join-Path $runtimeCpu 'last-llama-schema.dll')
    Copy-Item -LiteralPath (Join-Path $cudaSchemaDir 'last-llama-schema.dll') -Destination (Join-Path $runtimeCuda 'last-llama-schema.dll')
    Copy-Item -LiteralPath (Join-Path $cudaEngine 'bin\ggml-cuda.dll') -Destination (Join-Path $runtimeCuda 'ggml-cuda.dll')
    Copy-Item -LiteralPath (Join-Path $CudaToolkitRoot 'bin\x64\cublas64_13.dll') -Destination (Join-Path $runtimeCuda 'cublas64_13.dll')
    Copy-Item -LiteralPath (Join-Path $CudaToolkitRoot 'bin\x64\cublasLt64_13.dll') -Destination (Join-Path $runtimeCuda 'cublasLt64_13.dll')
    Copy-Item -LiteralPath (Join-Path $cloneRoot 'LICENSE'), (Join-Path $cloneRoot 'NOTICE') -Destination $packageStage
    Copy-Item -LiteralPath (Join-Path $cloneRoot 'LICENSES\llama.cpp-MIT.txt') -Destination (Join-Path $packageStage 'LICENSES\llama.cpp-MIT.txt')
    Copy-Item -LiteralPath (Join-Path $CudaToolkitRoot 'licenses\libcublas\LICENSE') -Destination (Join-Path $packageStage 'LICENSES\NVIDIA-cuBLAS-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $cloneRoot 'last-llama.json.example') -Destination (Join-Path $packageStage 'last-llama.json.example')
    Copy-Item -LiteralPath (Join-Path $cloneRoot 'models\README.md') -Destination (Join-Path $packageStage 'models\README.md')

    @"
# last-llama Windows x64 v0.1.0

Status: **Unsigned v0.1.0**. No executable or DLL in this archive is signed.
Signing changes the payload and requires repackaging and full requalification.

The archive contains the reference CLI and separate CPU/CUDA workers at its
root. Backend DLLs remain isolated under runtime/cpu and runtime/cuda; there
are no root-level DLLs. A configuration example and model guide are bundled;
model weights are not.

PowerShell quick start:

    Copy-Item .\last-llama.json.example .\last-llama.json
    New-Item -ItemType Directory -Force .\models | Out-Null
    .\last-llama.exe doctor
    .\last-llama.exe models show qwen3-8b
    .\last-llama.exe run qwen3-8b --backend cpu --prompt "Say hello."

Command Prompt (cmd.exe) quick start:

    copy last-llama.json.example last-llama.json
    if not exist models mkdir models
    last-llama.exe doctor
    last-llama.exe models show qwen3-8b
    last-llama.exe run qwen3-8b --backend cpu --prompt "Say hello."

Put the separately obtained Qwen3-8B-Q4_K_M.gguf in models, or edit the model
path in last-llama.json. For explicit CUDA, add --backend cuda --gpu-layers 37.
PowerShell requires .\ before an executable in the current directory.

Bundled origins:

- Project-built: last-llama.exe, both workers, and both schema bridge DLLs.
- Pinned llama.cpp/GGML ${engineRevision}: llama-common.dll, llama.dll, and
  the GGML DLLs. See LICENSES/llama.cpp-MIT.txt.
- NVIDIA CUDA Toolkit 13.3.1 redistributable: cublas64_13.dll and
  cublasLt64_13.dll. See LICENSES/NVIDIA-cuBLAS-LICENSE.txt.

External prerequisites, not bundled:

- Windows x64.
- Microsoft Visual C++ and OpenMP runtime components required by the machine.
- A compatible NVIDIA display driver when selecting CUDA.
- A user-supplied compatible GGUF model.

The CUDA Toolkit, NVCC, cudart64_13.dll, and NVIDIA driver DLLs are not package
payloads. Run last-llama.exe doctor after creating a local configuration. See
the source repository's docs/CLI.md for configuration and commands.
"@ | Set-Content -LiteralPath (Join-Path $packageStage 'PACKAGE-README.md') -Encoding utf8NoBOM

    $payload = [Collections.Generic.List[object]]::new()
    foreach ($relative in Get-RelativeFiles $packageStage) {
        if ($relative -eq 'package-manifest.json') { continue }
        $origin = if ($relative -match '^last-llama.*\.exe$|^runtime/.*/last-llama-schema\.dll$') { 'project-built' }
                  elseif ($relative -match '^runtime/cuda/cublas(Lt)?64_13\.dll$') { 'NVIDIA redistributable' }
                  elseif ($relative -match '^runtime/') { 'llama.cpp/GGML' }
                  elseif ($relative -eq 'last-llama.json.example') { 'configuration-example' }
                  else { 'documentation/license' }
        $license = if ($origin -eq 'NVIDIA redistributable') { 'LICENSES/NVIDIA-cuBLAS-LICENSE.txt' }
                   elseif ($origin -eq 'llama.cpp/GGML') { 'LICENSES/llama.cpp-MIT.txt' }
                   else { 'LICENSE or NOTICE as applicable' }
        $payload.Add((Get-FileRecord $packageStage $relative $origin $license))
    }
    $packageManifest = [ordered]@{
        format = 'last-llama-package-manifest-v1'
        version = $releaseVersion
        unsigned = $true
        release_commit = $commit
        llama_cpp_revision = $engineRevision
        target = 'x86_64-windows-msvc'
        optimize = 'ReleaseFast'
        generator = 'Ninja 1.13.2'
        jobs = 16
        cuda_toolkit = '13.3.1'
        cuda_architecture = 86
        cuda_graphs = $false
        external_prerequisites = @('Windows x64', 'Microsoft VC++/OpenMP runtime where required', 'compatible NVIDIA driver for CUDA', 'user-supplied GGUF model')
        payload = @($payload)
    }
    $packageManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $packageStage 'package-manifest.json') -Encoding utf8NoBOM

    $dependencyAudit = [Collections.Generic.List[object]]::new()
    foreach ($relative in Get-RelativeFiles $packageStage | Where-Object { $_ -match '\.(exe|dll)$' }) {
        $dependencyAudit.Add([ordered]@{ path = $relative; imports = @(Get-Imports (Join-Path $packageStage $relative)) })
    }
    $schemaImports = @($dependencyAudit | Where-Object { $_.path -eq 'runtime/cpu/last-llama-schema.dll' }).imports
    if ($schemaImports -notcontains 'llama-common.dll') { throw 'Schema dependency audit did not find llama-common.dll.' }
    $cudaImports = @($dependencyAudit | Where-Object { $_.path -eq 'runtime/cuda/ggml-cuda.dll' }).imports
    if ($cudaImports -notcontains 'cublas64_13.dll') { throw 'CUDA dependency audit did not find cublas64_13.dll.' }
    if (Get-ChildItem -LiteralPath $packageStage -File -Filter '*.dll') { throw 'Package root contains a DLL.' }
    if (Get-ChildItem -LiteralPath $runtimeCpu -File | Where-Object { $_.Name -match '^(ggml-cuda|cublas|cudart)' }) { throw 'CPU runtime contains a CUDA-only component.' }

    if (Test-Path -LiteralPath $binaryZip) { throw "Refusing to overwrite binary archive: $binaryZip" }
    Compress-Archive -Path (Join-Path $packageStage '*') -DestinationPath $binaryZip -CompressionLevel Optimal
    New-Item -ItemType Directory -Path $distributionRoot | Out-Null
    Expand-Archive -LiteralPath $binaryZip -DestinationPath $distributionRoot
    $extractedManifest = Get-Content -LiteralPath (Join-Path $distributionRoot 'package-manifest.json') -Raw | ConvertFrom-Json -Depth 100
    $actualPayload = @(Get-RelativeFiles $distributionRoot | Where-Object { $_ -ne 'package-manifest.json' })
    $declaredPayload = @($extractedManifest.payload.path | Sort-Object)
    if (($actualPayload -join "`n") -ne ($declaredPayload -join "`n")) { throw 'Extracted package inventory does not exactly match its manifest.' }
    foreach ($file in @($extractedManifest.payload)) {
        $path = Join-Path $distributionRoot $file.path
        if ((Get-Item -LiteralPath $path).Length -ne [long]$file.bytes -or (Get-Sha256 $path) -ne $file.sha256) { throw "Extracted payload mismatch: $($file.path)" }
    }
    Add-Check 'package manifest verification' 'extracted inventory, byte sizes, and SHA-256 hashes exactly match the payload manifest'

    New-Item -ItemType Directory -Path (Join-Path $qualificationRoot 'models'), (Join-Path $qualificationRoot 'configuration'), (Join-Path $qualificationRoot 'different working directory') | Out-Null
    $testModel = Join-Path $qualificationRoot 'models\smollm2-360m-instruct-q8_0.gguf'
    Copy-Item -LiteralPath $Model -Destination $testModel
    $configPath = Join-Path $qualificationRoot 'configuration\release-test.json'
    [ordered]@{
        default_model = 'smol'
        backend = 'auto'
        generation = [ordered]@{ max_tokens = 32; temperature = 0; top_p = 1; seed = 1; context_size = 256; timeout_ms = 60000 }
        models = [ordered]@{ smol = [ordered]@{ path = '..\models\smollm2-360m-instruct-q8_0.gguf'; description = 'external qualification fixture' } }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

    $dependencyIsolationNames = @('.git', '.tools', '.zig-cache', 'external', 'models', 'build', 'zig-out', 'results', 'evidence', 'temp')
    $dependencyIsolationCount = 0
    foreach ($name in $dependencyIsolationNames) {
        $path = Join-Path $DependencyRoot $name
        if (Test-Path -LiteralPath $path -PathType Container) {
            Hide-Path $path
            $dependencyIsolationCount++
        }
    }
    if ($dependencyIsolationCount -lt 3) { throw 'Development repository isolation did not hide the expected Git, tool, and dependency directories.' }
    foreach ($path in $AdditionalIsolationPath | Select-Object -Unique) { Hide-Path $path }
    $hiddenPaths | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $rawRoot 'isolation-rename-map.json') -Encoding utf8NoBOM
    Add-Check 'development-path isolation' 'development Git metadata plus all present tool, dependency, model, build, cache, result, evidence, and temporary directories were reversibly absent during extracted-package execution'

    $distCli = Join-Path $distributionRoot 'last-llama.exe'
    $cpuWorker = Join-Path $distributionRoot 'last-llama-cpu.exe'
    $cudaWorker = Join-Path $distributionRoot 'last-llama-cuda.exe'
    $distCpu = Join-Path $distributionRoot 'runtime\cpu'
    $distCuda = Join-Path $distributionRoot 'runtime\cuda'
    $savedPath = $env:PATH
    $env:PATH = 'C:\Windows\System32;C:\Windows'
    Push-Location (Join-Path $qualificationRoot 'different working directory')
    try {
        $exampleConfig = Join-Path $distributionRoot 'last-llama.json.example'
        $exampleOutput = & $distCli models show qwen3-8b --config $exampleConfig 2>&1
        if ($LASTEXITCODE -ne 0 -or (($exampleOutput -join "`n") -notmatch 'Qwen3-8B-Q4_K_M\.gguf')) { throw 'Packaged onboarding configuration did not parse and resolve the documented model.' }
        Add-Check 'packaged onboarding configuration' 'the extracted JSON example parsed and resolved its package-relative Qwen3-8B model path from a different working directory'

        $doctorOutput = & $distCli doctor --config $configPath 2>&1
        if ($LASTEXITCODE -ne 0 -or (($doctorOutput -join "`n") -notmatch '(?s)PASS.*cpu') -or (($doctorOutput -join "`n") -notmatch '(?s)PASS.*cuda')) { throw 'Doctor did not pass for both extracted workers.' }
        $cpuInspect = (& $distCli inspect cpu --config $configPath --json 2>&1 | Out-String) | ConvertFrom-Json -Depth 100
        if ($LASTEXITCODE -ne 0) { throw 'Extracted CPU inspection failed.' }
        $cudaInspect = (& $distCli inspect cuda --config $configPath --json 2>&1 | Out-String) | ConvertFrom-Json -Depth 100
        if ($LASTEXITCODE -ne 0) { throw 'Extracted CUDA inspection failed.' }
        Assert-ModuleOrigins $cpuInspect $distCpu $distCuda
        Assert-ModuleOrigins $cudaInspect $distCuda $distCpu
        if ($cpuInspect.runtime.revision -ne $commit -or $cudaInspect.runtime.revision -ne $commit) { throw 'Extracted worker revision does not match the release commit.' }
        if ($cpuInspect.runtime.llama_cpp_revision -ne $engineRevision -or $cudaInspect.runtime.llama_cpp_revision -ne $engineRevision) { throw 'Extracted worker upstream revision mismatch.' }

        $cpuRun = (& $distCli run smol --config $configPath --backend cpu --prompt 'Reply with one short greeting.' --json 2>&1 | Out-String) | ConvertFrom-Json -Depth 100
        if ($LASTEXITCODE -ne 0 -or $cpuRun.status -ne 'ok' -or $cpuRun.backend -ne 'cpu') { throw 'Extracted CPU inference failed.' }
        Assert-ModuleOrigins $cpuRun.attestation $distCpu $distCuda
        Add-Check 'extracted-package CPU inference' 'PASS from a different working directory with external relative model configuration'

        $cudaRun = (& $distCli run smol --config $configPath --backend cuda --gpu-layers 1 --prompt 'Reply with one short greeting.' --json 2>&1 | Out-String) | ConvertFrom-Json -Depth 100
        if ($LASTEXITCODE -ne 0 -or $cudaRun.status -ne 'ok' -or $cudaRun.backend -ne 'cuda') { throw 'Extracted CUDA inference failed.' }
        if ($cudaRun.attestation.compute.requested_offload -ne 1 -or $cudaRun.attestation.compute.effective_offload -ne 1) { throw 'Explicit CUDA offload was not effective.' }
        Assert-ModuleOrigins $cudaRun.attestation $distCuda $distCpu
        Add-Check 'extracted-package CUDA inference' 'PASS with explicit one-layer offload'
        Add-Check 'offload/cross-load isolation' 'CPU and CUDA module origins stayed inside their selected package directories; CUDA offload was requested and effective'
        Add-Check 'configuration portability' 'relative model path resolved from an external config while execution used a different current directory'

        $gateRoot = Join-Path $rawRoot 'extracted-gates'
        New-Item -ItemType Directory -Path $gateRoot | Out-Null
        Invoke-WorkerFile $cpuWorker $testModel (Join-Path $cloneRoot 'fixtures\gates\structured.json') 1 $distCpu (Join-Path $gateRoot 'cpu-structured.jsonl') (Join-Path $gateRoot 'cpu-structured.stderr.txt')
        $structuredRows = Read-JsonLines (Join-Path $gateRoot 'cpu-structured.jsonl')
        if ($structuredRows.Count -ne 1 -or $structuredRows[0].status -ne 'ok' -or -not $structuredRows[0].final_text) { throw 'Extracted structured-output gate failed.' }
        Invoke-WorkerFile $cpuWorker $testModel (Join-Path $cloneRoot 'fixtures\gates\lifecycle.json') 3 $distCpu (Join-Path $gateRoot 'cpu-lifecycle.jsonl') (Join-Path $gateRoot 'cpu-lifecycle.stderr.txt')
        $lifecycleRows = Read-JsonLines (Join-Path $gateRoot 'cpu-lifecycle.jsonl')
        if ($lifecycleRows.Count -ne 15) { throw "Lifecycle gate produced $($lifecycleRows.Count) rows, expected 15." }
        foreach ($row in $lifecycleRows) {
            if ($row.context_destroyed -eq $false -and $row.id -in @('structured-final', 'cancelled-before-decode', 'injected-failure')) { throw "Lifecycle cleanup failed for $($row.id)." }
        }
        Add-Check 'structured output and lifecycle' 'extracted CPU schema output and three-cycle lifecycle gate passed'

        $revisionPath = $env:PATH
        $env:PATH = "$distCpu;C:\Windows\System32;C:\Windows"
        try {
            $matchRequest = [ordered]@{ id = 'revision-match'; prompt = 'Reply briefly.'; backend = 'cpu'; context_size = 256; max_tokens = 8; timeout_ms = 60000; expected_runtime_revision = $commit; expected_llama_cpp_revision = $engineRevision } | ConvertTo-Json -Compress
            $matchOutput = $matchRequest | & $cpuWorker $testModel 2> (Join-Path $rawRoot 'revision-match.stderr.txt') | Out-String
            $matchResult = $matchOutput | ConvertFrom-Json -Depth 100
            if ($matchResult.status -ne 'ok' -or $matchResult.attestation.runtime.revision -ne $commit) { throw 'Matching release revision was not admitted.' }
            $mismatchRequest = [ordered]@{ id = 'revision-mismatch'; prompt = 'Reply briefly.'; backend = 'cpu'; context_size = 256; max_tokens = 8; timeout_ms = 60000; expected_runtime_revision = ('f' * 40) } | ConvertTo-Json -Compress
            $mismatchOutput = $mismatchRequest | & $cpuWorker $testModel 2> (Join-Path $rawRoot 'revision-mismatch.stderr.txt') | Out-String
            $mismatchResult = $mismatchOutput | ConvertFrom-Json -Depth 100
            if ($mismatchResult.status -ne 'RuntimeRevisionMismatch') { throw 'Mismatched release revision was not rejected.' }
        } finally { $env:PATH = $revisionPath }
        Add-Check 'runtime revision binding' 'both workers embed the full release commit; matching pin passed and mismatched pin failed closed'

        $missingDll = Join-Path $distCpu 'llama-common.dll'
        Rename-Item -LiteralPath $missingDll -NewName 'llama-common.dll.missing-test'
        try {
            $missingOutput = & $distCli doctor --config $configPath 2>&1
            if ($LASTEXITCODE -eq 0 -or (($missingOutput -join "`n") -notmatch 'required DLL missing: llama-common.dll')) { throw 'Missing-dependency diagnostic did not fail clearly.' }
        } finally { Rename-Item -LiteralPath (Join-Path $distCpu 'llama-common.dll.missing-test') -NewName 'llama-common.dll' }
        Add-Check 'missing-dependency diagnostics' 'doctor rejected a missing required CPU dependency and named it'

        Rename-Item -LiteralPath $cudaWorker -NewName 'last-llama-cuda.exe.unavailable-test'
        try {
            $noFallback = & $distCli run smol --config $configPath --backend cuda --gpu-layers 1 --prompt hello 2>&1
            if ($LASTEXITCODE -eq 0 -or (($noFallback -join "`n") -notmatch 'explicitly requested CUDA is unavailable')) { throw 'Explicit CUDA did not fail closed when unavailable.' }
        } finally { Rename-Item -LiteralPath (Join-Path $distributionRoot 'last-llama-cuda.exe.unavailable-test') -NewName 'last-llama-cuda.exe' }
        Add-Check 'explicit-CUDA no fallback' 'explicit CUDA failed without selecting CPU when the CUDA worker was unavailable'

        $aclBefore = [ordered]@{}
        foreach ($item in Get-ChildItem -LiteralPath $distributionRoot -Recurse -Force) {
            $relative = $item.FullName.Substring($distributionRoot.Length + 1)
            $aclBefore[$relative] = (Get-Acl -LiteralPath $item.FullName).Sddl
        }
        $aclBefore['.'] = (Get-Acl -LiteralPath $distributionRoot).Sddl
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $aclApplyLog = Join-Path $rawRoot 'readonly-icacls-apply.txt'
        foreach ($item in @(Get-Item -LiteralPath $distributionRoot) + @(Get-ChildItem -LiteralPath $distributionRoot -Recurse -Force)) {
            $rights = if ($item.PSIsContainer) { 'WD,AD,DC' } else { 'WD,AD' }
            & icacls $item.FullName /deny "*$sid`:($rights)" | Out-File -LiteralPath $aclApplyLog -Append
            if ($LASTEXITCODE -ne 0) { throw "Could not enforce read-only installation ACL: $($item.FullName)" }
        }
        try {
            $writeBlocked = $false
            try { Set-Content -LiteralPath (Join-Path $distributionRoot 'write-probe.txt') -Value 'must fail' -ErrorAction Stop } catch { $writeBlocked = $true }
            if (-not $writeBlocked) { throw 'Installation-directory write was not denied.' }
            $readonlyRun = (& $distCli run smol --config $configPath --backend cpu --prompt 'Reply with one short greeting.' --json 2>&1 | Out-String) | ConvertFrom-Json -Depth 100
            if ($LASTEXITCODE -ne 0 -or $readonlyRun.status -ne 'ok') { throw 'CPU inference failed while installation writes were denied.' }
        } finally {
            $aclRestoreLog = Join-Path $rawRoot 'readonly-icacls-restore.txt'
            foreach ($item in @((Get-ChildItem -LiteralPath $distributionRoot -Recurse -Force) | Sort-Object { $_.FullName.Length } -Descending) + @(Get-Item -LiteralPath $distributionRoot)) {
                & icacls $item.FullName /remove:d "*$sid" | Out-File -LiteralPath $aclRestoreLog -Append
                if ($LASTEXITCODE -ne 0) { throw "Could not remove read-only installation ACL: $($item.FullName)" }
            }
        }
        foreach ($entry in $aclBefore.GetEnumerator()) {
            $path = if ($entry.Key -eq '.') { $distributionRoot } else { Join-Path $distributionRoot $entry.Key }
            if ((Get-Acl -LiteralPath $path).Sddl -ne $entry.Value) { throw "ACL restoration mismatch: $($entry.Key)" }
        }
        Add-Check 'read-only execution' 'write denial was enforced, CPU inference passed, and every captured ACL was restored exactly'

        $runtimeEvidence = [ordered]@{
            cpu_inspection = $cpuInspect
            cuda_inspection = $cudaInspect
            cpu_inference = $cpuRun
            cuda_inference = $cudaRun
            structured = $structuredRows[0]
            lifecycle = @($lifecycleRows | ForEach-Object { [ordered]@{ id = $_.id; status = $_.status; finish = $_.finish; model_cycle = $_.model_cycle; context_destroyed = $_.context_destroyed; sampler_reset = $_.sampler_reset; sampler_destroyed = $_.sampler_destroyed } })
        }
        ConvertTo-SanitizedJson $runtimeEvidence | Set-Content -LiteralPath (Join-Path $sanitizedRoot 'runtime-evidence.json') -Encoding utf8NoBOM
    } finally {
        Pop-Location
        $env:PATH = $savedPath
        Restore-HiddenPaths
    }

    $isolationIndex = 0
    $restored = @($hiddenPaths | ForEach-Object {
        $isolationIndex++
        [ordered]@{ id = ('isolated-path-{0:D2}' -f $isolationIndex); restored = (Test-Path -LiteralPath $_.original); hidden_absent = -not (Test-Path -LiteralPath $_.hidden) }
    })
    if ($restored | Where-Object { -not $_.restored -or -not $_.hidden_absent }) { throw 'One or more isolated paths were not restored.' }

    $buildMetadata = [ordered]@{
        release_commit = $commit
        llama_cpp_revision = $engineRevision
        tools = [ordered]@{ zig = '0.17.0-dev.1676+c9dc9b798'; header_zig = '0.14.1'; ninja = '1.13.2'; cuda_toolkit = '13.3.1'; nvcc = '13.3.73' }
        settings = [ordered]@{ target = 'x86_64-windows-msvc'; optimize = 'ReleaseFast'; generator = 'Ninja'; jobs = 16; cuda_architecture = 86; cuda_graphs = $false }
        cpu_timing = Get-Content -LiteralPath $cpuTiming -Raw | ConvertFrom-Json
        cuda_timing = Get-Content -LiteralPath $cudaTiming -Raw | ConvertFrom-Json
        dependency_audit = @($dependencyAudit)
        isolation_restoration = $restored
    }
    ConvertTo-SanitizedJson $buildMetadata | Set-Content -LiteralPath (Join-Path $sanitizedRoot 'build-and-dependency-metadata.json') -Encoding utf8NoBOM
    Copy-Item -LiteralPath (Join-Path $packageStage 'package-manifest.json') -Destination (Join-Path $sanitizedRoot 'package-manifest.json')

    Add-Check 'evidence sanitation' 'fresh sanitized summaries omit raw logs and normalize repository, dependency, model, and work paths'
    Add-Check 'final readiness' 'all pre-tag release qualification gates passed; artifacts are ready for annotated tagging and finalization'
    $summary = [ordered]@{
        format = 'last-llama-v0.1.0-qualification-v1'
        version = $releaseVersion
        unsigned = $true
        overall_status = 'PASS'
        release_commit = $commit
        llama_cpp_revision = $engineRevision
        checks = @($checks)
        artifacts = [ordered]@{
            source = [ordered]@{ name = Split-Path $sourceZip -Leaf; sha256 = Get-Sha256 $sourceZip; bytes = (Get-Item $sourceZip).Length }
            binary = [ordered]@{ name = Split-Path $binaryZip -Leaf; sha256 = Get-Sha256 $binaryZip; bytes = (Get-Item $binaryZip).Length }
        }
    }
    $summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM
    Copy-Item -LiteralPath $summaryPath -Destination (Join-Path $sanitizedRoot 'qualification-summary.json')

    $evidenceFiles = [Collections.Generic.List[object]]::new()
    foreach ($relative in Get-RelativeFiles $sanitizedRoot) {
        $evidenceFiles.Add([ordered]@{ path = $relative; bytes = (Get-Item (Join-Path $sanitizedRoot $relative)).Length; sha256 = Get-Sha256 (Join-Path $sanitizedRoot $relative) })
    }
    $evidenceManifest = [ordered]@{
        format = 'last-llama-evidence-manifest-v1'
        release_commit = $commit
        unsigned = $true
        sanitized_copies = @($evidenceFiles)
        normalizations = @('repository paths -> ${REPOSITORY}', 'clean clone paths -> ${CLEAN_SOURCE}', 'dependency paths -> ${DEPENDENCIES}', 'work paths -> ${WORK}', 'model paths -> ${MODEL}')
        omissions = @('raw stdout/stderr and build logs with workstation paths', 'historical private evidence', 'models, toolchains, source checkouts, and compiled build trees', 'unconstrained generated prose except bounded fresh qualification results')
    }
    $evidenceManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $sanitizedRoot 'evidence-manifest.json') -Encoding utf8NoBOM
    $sanitizedText = Get-ChildItem -LiteralPath $sanitizedRoot -Recurse -File | Get-Content -Raw
    if (($sanitizedText -join "`n") -match 'C:\\Users\\|(?i)last-llama\.cpp\.zig-dev|last-llama-release-verify|LastX') { throw 'Sanitized evidence still contains a private or development reference.' }
    if (Test-Path -LiteralPath $evidenceZip) { throw "Refusing to overwrite evidence archive: $evidenceZip" }
    Compress-Archive -Path (Join-Path $sanitizedRoot '*') -DestinationPath $evidenceZip -CompressionLevel Optimal
    $evidenceExtract = Join-Path $WorkRoot 'evidence-archive-extract'
    New-Item -ItemType Directory -Path $evidenceExtract | Out-Null
    Expand-Archive -LiteralPath $evidenceZip -DestinationPath $evidenceExtract
    $extractedEvidenceManifest = Get-Content -LiteralPath (Join-Path $evidenceExtract 'evidence-manifest.json') -Raw | ConvertFrom-Json -Depth 100
    $actualEvidence = @(Get-RelativeFiles $evidenceExtract | Where-Object { $_ -ne 'evidence-manifest.json' })
    $declaredEvidence = @($extractedEvidenceManifest.sanitized_copies.path | Sort-Object)
    if (($actualEvidence -join "`n") -ne ($declaredEvidence -join "`n")) { throw 'Evidence ZIP inventory does not exactly match evidence-manifest.json.' }
    foreach ($file in @($extractedEvidenceManifest.sanitized_copies)) {
        $path = Join-Path $evidenceExtract $file.path
        if ((Get-Item -LiteralPath $path).Length -ne [long]$file.bytes -or (Get-Sha256 $path) -ne $file.sha256) { throw "Evidence ZIP content mismatch: $($file.path)" }
    }
    $summary.artifacts.evidence = [ordered]@{ name = Split-Path $evidenceZip -Leaf; sha256 = Get-Sha256 $evidenceZip; bytes = (Get-Item $evidenceZip).Length }
    $summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $summaryPath -Encoding utf8NoBOM

    $finalStatus = (& git -C $sourceRoot status --porcelain=v1 --untracked-files=all) -join "`n"
    if ($finalStatus) { throw "Source tree changed during preparation: $finalStatus" }
    Write-Output "PASS: unsigned v0.1.0 artifacts qualified for commit $commit"
    Write-Output "Qualification summary: $summaryPath"
} catch {
    if ($hiddenPaths.Count) {
        try { Restore-HiddenPaths } catch { Write-Error "Release failed and restoration also failed: $($_.Exception.Message)" }
    }
    throw
}
