param(
    [string]$Runa = (Join-Path $PSScriptRoot "..\zig-out\bin\runa.exe")
)

$ErrorActionPreference = "Stop"

$ResolvedRuna = Resolve-Path -LiteralPath $Runa -ErrorAction Stop
$RunaPath = $ResolvedRuna.Path

function Resolve-ExamplePath {
    param([string]$RelativePath)
    return Join-Path $PSScriptRoot $RelativePath
}

function Write-ExampleFile {
    param(
        [string]$RelativePath,
        [string]$Content
    )

    $Path = Resolve-ExamplePath $RelativePath
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    Set-Content -LiteralPath $Path -Value $Content -NoNewline -Encoding ASCII
}

function Remove-GeneratedExampleOutputs {
    $Root = (Resolve-Path -LiteralPath $PSScriptRoot).Path
    $Generated = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force |
        Where-Object { $_.Name -eq "target" -or $_.Name -eq "dist" -or $_.Name -eq ".state" } |
        Sort-Object FullName -Descending)
    foreach ($Item in $Generated) {
        if (-not $Item.FullName.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "refusing to remove outside examples: $($Item.FullName)"
        }
        Remove-Item -LiteralPath $Item.FullName -Recurse -Force
    }
}

function Invoke-Runa {
    param(
        [string]$Example,
        [string[]]$Arguments
    )

    $ExampleDir = Resolve-ExamplePath $Example
    Push-Location -LiteralPath $ExampleDir
    try {
        & $RunaPath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "runa $($Arguments -join ' ') failed in examples\$Example with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Invoke-RunaCaptured {
    param(
        [string]$Example,
        [string[]]$Arguments,
        [int[]]$ExpectedExitCodes = @(0),
        [hashtable]$EnvVars = @{}
    )

    $ProcessInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $ProcessInfo.FileName = $RunaPath
    $ProcessInfo.WorkingDirectory = Resolve-ExamplePath $Example
    $ProcessInfo.UseShellExecute = $false
    $ProcessInfo.RedirectStandardOutput = $true
    $ProcessInfo.RedirectStandardError = $true
    $ProcessInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
    foreach ($Key in $EnvVars.Keys) {
        $ProcessInfo.EnvironmentVariables[$Key] = [string]$EnvVars[$Key]
    }

    $Process = [System.Diagnostics.Process]::Start($ProcessInfo)
    $Stdout = $Process.StandardOutput.ReadToEnd()
    $Stderr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()

    if ($ExpectedExitCodes -notcontains $Process.ExitCode) {
        throw @"
runa $($Arguments -join ' ') in examples\$Example exited with $($Process.ExitCode)
stdout:
$Stdout
stderr:
$Stderr
"@
    }

    return [pscustomobject]@{
        ExitCode = $Process.ExitCode
        Stdout = $Stdout
        Stderr = $Stderr
    }
}

function Join-ProcessArguments {
    param([string[]]$Arguments)

    $Quoted = foreach ($Argument in $Arguments) {
        if ($Argument -match '[\s"]') {
            '"' + ($Argument.Replace('\', '\\').Replace('"', '\"')) + '"'
        } else {
            $Argument
        }
    }
    return ($Quoted -join " ")
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Label
    )

    if (-not $Text.Contains($Needle)) {
        throw "missing '$Needle' in $Label"
    }
}

function Assert-NotContains {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Label
    )

    if ($Text.Contains($Needle)) {
        throw "unexpected '$Needle' in $Label"
    }
}

function Assert-ExamplePathExists {
    param([string]$RelativePath)
    $Path = Resolve-ExamplePath $RelativePath
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "missing expected path examples\$RelativePath"
    }
}

function Assert-ExamplePathMissing {
    param([string]$RelativePath)
    $Path = Resolve-ExamplePath $RelativePath
    if (Test-Path -LiteralPath $Path) {
        throw "unexpected path exists examples\$RelativePath"
    }
}

function Assert-ExecutableMissing {
    param(
        [string]$Example,
        [string]$Product
    )

    $TargetDir = Resolve-ExamplePath "$Example\target"
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        return
    }

    $Candidates = @(Get-ChildItem -LiteralPath $TargetDir -Recurse -File -Filter "$Product.exe")
    if ($Candidates.Count -ne 0) {
        throw "unexpected built executable $Product.exe in examples\$Example"
    }
}

function Invoke-ExampleBinary {
    param(
        [string]$Example,
        [string]$Product,
        [int]$ExpectedExitCode
    )

    $TargetDir = Resolve-ExamplePath "$Example\target"
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        throw "missing target directory for examples\$Example"
    }

    $Candidates = @(Get-ChildItem -LiteralPath $TargetDir -Recurse -File -Filter "$Product.exe")
    if ($Candidates.Count -eq 0) {
        throw "missing built executable $Product.exe for examples\$Example"
    }

    $Executable = $Candidates | Select-Object -First 1
    & $Executable.FullName
    if ($LASTEXITCODE -ne $ExpectedExitCode) {
        throw "examples\$Example exited with $LASTEXITCODE, expected $ExpectedExitCode"
    }
}

function Assert-DynamicLibraryExists {
    param(
        [string]$Example,
        [string]$Product
    )

    $TargetDir = Resolve-ExamplePath "$Example\target"
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        throw "missing target directory for examples\$Example"
    }

    $Candidates = @(Get-ChildItem -LiteralPath $TargetDir -Recurse -File -Filter "$Product.dll")
    if ($Candidates.Count -eq 0) {
        throw "missing built dynamic library $Product.dll for examples\$Example"
    }
}

function Convert-ToTomlPath {
    param([string]$Path)
    return $Path.Replace("\", "/")
}

function Write-RegistryConfig {
    param(
        [string]$ConfigPath,
        [string]$RegistryRoot
    )

    $RegistryTomlPath = Convert-ToTomlPath (Resolve-Path -LiteralPath $RegistryRoot).Path
    $Document = "default_registry = `"local`"`n`n[registries.local]`nroot = `"$RegistryTomlPath`"`n"
    Set-Content -LiteralPath $ConfigPath -Value $Document -NoNewline -Encoding ASCII
}

function Invoke-SmokeExamples {
    $Examples = @(
        [pscustomobject]@{ Name = "hello-world"; Product = "hello_world"; ExitCode = 0; HasTests = $false; RunsBinary = $true },
        [pscustomobject]@{ Name = "fizzbuzz"; Product = "fizzbuzz"; ExitCode = 15; HasTests = $false; RunsBinary = $true },
        [pscustomobject]@{ Name = "binary-tests"; Product = "binary_tests"; ExitCode = 0; HasTests = $true; RunsBinary = $true },
        [pscustomobject]@{ Name = "fizzbuzz-tests"; Product = ""; ExitCode = 0; HasTests = $true; RunsBinary = $false }
    )

    foreach ($Example in $Examples) {
        Invoke-Runa -Example $Example.Name -Arguments @("fmt", "--check")
        Invoke-Runa -Example $Example.Name -Arguments @("check")
        if ($Example.HasTests) {
            Invoke-Runa -Example $Example.Name -Arguments @("test", "--parallel")
        }
        if ($Example.RunsBinary) {
            Invoke-Runa -Example $Example.Name -Arguments @("build")
            Invoke-ExampleBinary -Example $Example.Name -Product $Example.Product -ExpectedExitCode $Example.ExitCode
        }
    }
}

function Invoke-BuildProofs {
    Invoke-Runa -Example "build-cdylib" -Arguments @("fmt", "--check")
    Invoke-Runa -Example "build-cdylib" -Arguments @("check")
    Invoke-Runa -Example "build-cdylib" -Arguments @("build", "--cdylib=plugin")
    Assert-DynamicLibraryExists -Example "build-cdylib" -Product "plugin"

    Invoke-Runa -Example "build-fail-fast" -Arguments @("fmt", "--check")
    Invoke-Runa -Example "build-fail-fast" -Arguments @("check")
    $FailFast = Invoke-RunaCaptured -Example "build-fail-fast" -Arguments @("build") -ExpectedExitCodes @(1)
    Assert-Contains -Text $FailFast.Stderr -Needle "runa build:" -Label "build-fail-fast stderr"
    Assert-ExecutableMissing -Example "build-fail-fast" -Product "b_good"

    Invoke-Runa -Example "build-workspace-order" -Arguments @("fmt", "--check")
    Invoke-Runa -Example "build-workspace-order" -Arguments @("check")
    $WorkspaceOrder = Invoke-RunaCaptured -Example "build-workspace-order" -Arguments @("build") -ExpectedExitCodes @(1)
    Assert-Contains -Text $WorkspaceOrder.Stderr -Needle "runa build:" -Label "build-workspace-order stderr"
    Assert-ExecutableMissing -Example "build-workspace-order" -Product "b_good"

    Invoke-Runa -Example "build-unsupported-target" -Arguments @("fmt", "--check")
    $Unsupported = Invoke-RunaCaptured -Example "build-unsupported-target" -Arguments @("build") -ExpectedExitCodes @(1)
    Assert-Contains -Text $Unsupported.Stderr -Needle "build.target.unsupported" -Label "build-unsupported-target stderr"

    $Conflict = Invoke-RunaCaptured -Example "build-target-conflict" -Arguments @("build") -ExpectedExitCodes @(1)
    Assert-Contains -Text $Conflict.Stderr -Needle "build.target.conflict" -Label "build-target-conflict stderr"

    Invoke-Runa -Example "build-selector-mismatch" -Arguments @("fmt", "--check")
    Invoke-Runa -Example "build-selector-mismatch" -Arguments @("check")
    $Selector = Invoke-RunaCaptured -Example "build-selector-mismatch" -Arguments @("build", "--bin=plugin") -ExpectedExitCodes @(1)
    Assert-Contains -Text $Selector.Stderr -Needle "build.product.missing" -Label "build-selector-mismatch stderr"

    $ProofRoot = Resolve-ExamplePath "build-nonselectable"
    $StateRoot = Join-Path $ProofRoot ".state"
    $RegistryRoot = Join-Path $StateRoot "registry"
    $StoreRoot = Join-Path $StateRoot "store"
    New-Item -ItemType Directory -Force $RegistryRoot, $StoreRoot | Out-Null
    $ConfigPath = Join-Path $StateRoot "config.toml"
    Write-RegistryConfig -ConfigPath $ConfigPath -RegistryRoot $RegistryRoot
    $EnvVars = @{
        RUNA_CONFIG_PATH = (Resolve-Path -LiteralPath $ConfigPath).Path
        RUNA_STORE_ROOT = (Resolve-Path -LiteralPath $StoreRoot).Path
    }

    [void](Invoke-RunaCaptured -Example "build-nonselectable\managed-src" -Arguments @("publish", "local") -EnvVars $EnvVars)
    [void](Invoke-RunaCaptured -Example "build-nonselectable" -Arguments @("import", "managed_dep", "--version=2026.0.01") -EnvVars $EnvVars)

    foreach ($PackageName in @("vendored_dep", "external_dep", "managed_dep")) {
        $NonSelectable = Invoke-RunaCaptured -Example "build-nonselectable\app" -Arguments @("build", "--package=$PackageName") -ExpectedExitCodes @(1) -EnvVars $EnvVars
        Assert-Contains -Text $NonSelectable.Stderr -Needle "UnknownWorkspacePackage" -Label "build-nonselectable $PackageName stderr"
    }
}

function Invoke-TestProofs {
    Invoke-Runa -Example "test-fail-fast" -Arguments @("fmt", "--check")
    Invoke-Runa -Example "test-fail-fast" -Arguments @("check")
    $FailFast = Invoke-RunaCaptured -Example "test-fail-fast" -Arguments @("test", "--parallel") -ExpectedExitCodes @(1)
    Assert-Contains -Text $FailFast.Stdout -Needle "runa test package a_bad: discovered=1 executed=1 passed=0 failed=1 harness_failures=0" -Label "test-fail-fast stdout"
    Assert-Contains -Text $FailFast.Stdout -Needle "runa test: discovered=2 executed=1 passed=0 failed=1 harness_failures=0" -Label "test-fail-fast stdout"
    Assert-NotContains -Text $FailFast.Stdout -Needle "b_good" -Label "test-fail-fast stdout"
    Assert-NotContains -Text $FailFast.Stderr -Needle "b_good::must_not_run_after_first_package_fails" -Label "test-fail-fast stderr"

    Invoke-Runa -Example "test-cwd" -Arguments @("fmt", "--check")
    Invoke-Runa -Example "test-cwd" -Arguments @("check")
    $Nested = Invoke-RunaCaptured -Example "test-cwd\nested" -Arguments @("test", "--parallel")
    Assert-Contains -Text $Nested.Stdout -Needle "discovered=1 executed=1 passed=1 failed=0 harness_failures=0" -Label "test-cwd stdout"
    Assert-ExamplePathExists -RelativePath "test-cwd\target"
    Assert-ExamplePathMissing -RelativePath "test-cwd\nested\target"

    Invoke-Runa -Example "test-routing" -Arguments @("fmt", "--check")
    Invoke-Runa -Example "test-routing" -Arguments @("check")
    $Routing = Invoke-RunaCaptured -Example "test-routing" -Arguments @("test") -ExpectedExitCodes @(1)
    Assert-Contains -Text $Routing.Stdout -Needle "runa test package test_routing: discovered=2 executed=2 passed=1 failed=1 harness_failures=0" -Label "test-routing stdout"
    Assert-Contains -Text $Routing.Stdout -Needle "runa test: discovered=2 executed=2 passed=1 failed=1 harness_failures=0" -Label "test-routing stdout"
    Assert-Contains -Text $Routing.Stderr -Needle "runa test: failed test_routing::writes_and_fails" -Label "test-routing stderr"
    Assert-Contains -Text $Routing.Stderr -Needle "captured stdout" -Label "test-routing stderr"
    Assert-Contains -Text $Routing.Stderr -Needle "X" -Label "test-routing stderr"

    $RoutingNoCapture = Invoke-RunaCaptured -Example "test-routing" -Arguments @("test", "--parallel", "--no-capture") -ExpectedExitCodes @(1)
    Assert-Contains -Text $RoutingNoCapture.Stdout -Needle "runa test package test_routing: discovered=2 executed=2 passed=1 failed=1 harness_failures=0" -Label "test-routing no-capture stdout"
    Assert-Contains -Text $RoutingNoCapture.Stdout -Needle "runa test: discovered=2 executed=2 passed=1 failed=1 harness_failures=0" -Label "test-routing no-capture stdout"
    Assert-Contains -Text $RoutingNoCapture.Stdout -Needle "X" -Label "test-routing no-capture stdout"
    Assert-Contains -Text $RoutingNoCapture.Stderr -Needle "runa test: failed test_routing::writes_and_fails" -Label "test-routing no-capture stderr"
}

function Invoke-NewFlowProof {
    $Root = Resolve-ExamplePath ".state\new-flow"
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Invoke-Runa -Example ".state\new-flow" -Arguments @("new", "new_app")
    Write-ExampleFile -RelativePath ".state\new-flow\new_app\main.rna" -Content @'
fn main() -> I32:
  return 9
'@
    Invoke-Runa -Example ".state\new-flow\new_app" -Arguments @("fmt")
    Invoke-Runa -Example ".state\new-flow\new_app" -Arguments @("check")
    Invoke-Runa -Example ".state\new-flow\new_app" -Arguments @("build")
    Invoke-ExampleBinary -Example ".state\new-flow\new_app" -Product "new_app" -ExpectedExitCode 9
}

function Invoke-FmtExclusionProof {
    $Root = Resolve-ExamplePath ".state\fmt-exclusions"
    New-Item -ItemType Directory -Force -Path (Join-Path $Root "target") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Root "dist") | Out-Null
    Write-ExampleFile -RelativePath ".state\fmt-exclusions\runa.toml" -Content @'
[package]
name = "fmt_exclusions"
version = "2026.0.01"
edition = "2026"
lang_version = "0.00"

[[products]]
kind = "bin"
root = "main.rna"
'@
    Write-ExampleFile -RelativePath ".state\fmt-exclusions\main.rna" -Content @'
fn main() -> I32:
  return 0
'@
    $Ignored = @'
fn ignored() -> I32:
  return 99
'@
    Write-ExampleFile -RelativePath ".state\fmt-exclusions\target\ignored.rna" -Content $Ignored
    Write-ExampleFile -RelativePath ".state\fmt-exclusions\dist\ignored.rna" -Content $Ignored
    Write-ExampleFile -RelativePath ".state\fmt-exclusions\vendor\unused\ignored.rna" -Content $Ignored

    Invoke-Runa -Example ".state\fmt-exclusions" -Arguments @("fmt")
    $MainAfter = Get-Content -LiteralPath (Resolve-ExamplePath ".state\fmt-exclusions\main.rna") -Raw
    Assert-Contains -Text $MainAfter -Needle "    return 0" -Label "fmt-exclusions main"
    $TargetAfter = Get-Content -LiteralPath (Resolve-ExamplePath ".state\fmt-exclusions\target\ignored.rna") -Raw
    $DistAfter = Get-Content -LiteralPath (Resolve-ExamplePath ".state\fmt-exclusions\dist\ignored.rna") -Raw
    $VendorAfter = Get-Content -LiteralPath (Resolve-ExamplePath ".state\fmt-exclusions\vendor\unused\ignored.rna") -Raw
    if ($TargetAfter -ne $Ignored -or $DistAfter -ne $Ignored -or $VendorAfter -ne $Ignored) {
        throw "runa fmt rewrote target/, dist/, or undeclared vendor/ source"
    }
}

function Invoke-ManagedDependencyFlow {
    $Root = Resolve-ExamplePath ".state\managed-flow"
    $RegistryRoot = Join-Path $Root "registry"
    $StoreRoot = Join-Path $Root "store"
    New-Item -ItemType Directory -Force -Path $Root, $RegistryRoot, $StoreRoot | Out-Null
    $ConfigPath = Join-Path $Root "config.toml"
    Write-RegistryConfig -ConfigPath $ConfigPath -RegistryRoot $RegistryRoot
    $EnvVars = @{
        RUNA_CONFIG_PATH = (Resolve-Path -LiteralPath $ConfigPath).Path
        RUNA_STORE_ROOT = (Resolve-Path -LiteralPath $StoreRoot).Path
    }

    Invoke-Runa -Example ".state\managed-flow" -Arguments @("new", "--lib", "dep")
    Invoke-Runa -Example ".state\managed-flow" -Arguments @("new", "app")
    Write-ExampleFile -RelativePath ".state\managed-flow\dep\lib.rna" -Content @'
pub fn value() -> I32:
  return 6
'@
    Write-ExampleFile -RelativePath ".state\managed-flow\app\main.rna" -Content @'
use dep.value as dep_value

fn main() -> I32:
    return dep_value :: :: call
'@

    [void](Invoke-RunaCaptured -Example ".state\managed-flow\dep" -Arguments @("publish", "local") -EnvVars $EnvVars)
    [void](Invoke-RunaCaptured -Example ".state\managed-flow" -Arguments @("import", "dep", "--version=2026.0.01") -EnvVars $EnvVars)
    [void](Invoke-RunaCaptured -Example ".state\managed-flow\app" -Arguments @("add", "dep", "--version=2026.0.01") -EnvVars $EnvVars)

    $StoreLib = Join-Path $StoreRoot "sources\local\dep\2026.0.01\sources\lib.rna"
    $StoreBefore = Get-Content -LiteralPath $StoreLib -Raw
    [void](Invoke-RunaCaptured -Example ".state\managed-flow\app" -Arguments @("fmt") -EnvVars $EnvVars)
    $StoreAfter = Get-Content -LiteralPath $StoreLib -Raw
    if ($StoreBefore -ne $StoreAfter) {
        throw "managed store source changed during app fmt"
    }

    [void](Invoke-RunaCaptured -Example ".state\managed-flow\app" -Arguments @("check") -EnvVars $EnvVars)
    [void](Invoke-RunaCaptured -Example ".state\managed-flow\app" -Arguments @("build") -EnvVars $EnvVars)
    Invoke-ExampleBinary -Example ".state\managed-flow\app" -Product "app" -ExpectedExitCode 6
}

function Invoke-VendoredDependencyFlow {
    $Root = Resolve-ExamplePath ".state\vendor-flow"
    $RegistryRoot = Join-Path $Root "registry"
    New-Item -ItemType Directory -Force -Path $Root, $RegistryRoot | Out-Null
    $ConfigPath = Join-Path $Root "config.toml"
    Write-RegistryConfig -ConfigPath $ConfigPath -RegistryRoot $RegistryRoot
    $EnvVars = @{
        RUNA_CONFIG_PATH = (Resolve-Path -LiteralPath $ConfigPath).Path
    }

    Invoke-Runa -Example ".state\vendor-flow" -Arguments @("new", "--lib", "dep")
    Invoke-Runa -Example ".state\vendor-flow" -Arguments @("new", "app")
    Write-ExampleFile -RelativePath ".state\vendor-flow\dep\lib.rna" -Content @'
pub fn value() -> I32:
  return 8
'@
    Write-ExampleFile -RelativePath ".state\vendor-flow\app\main.rna" -Content @'
use dep.value as dep_value

fn main() -> I32:
  return dep_value :: :: call
'@

    [void](Invoke-RunaCaptured -Example ".state\vendor-flow\dep" -Arguments @("publish", "local") -EnvVars $EnvVars)
    $LangMismatch = Invoke-RunaCaptured -Example ".state\vendor-flow\app" -Arguments @("vendor", "dep", "--version=2026.0.01", "--lang-version=0.01") -ExpectedExitCodes @(1) -EnvVars $EnvVars
    Assert-Contains -Text $LangMismatch.Stderr -Needle "DependencyLangVersionMismatch" -Label "vendor lang-version stderr"
    [void](Invoke-RunaCaptured -Example ".state\vendor-flow\app" -Arguments @("vendor", "dep", "--version=2026.0.01", "--lang-version=0.00") -EnvVars $EnvVars)

    [void](Invoke-RunaCaptured -Example ".state\vendor-flow\app" -Arguments @("fmt") -EnvVars $EnvVars)
    $VendoredAfter = Get-Content -LiteralPath (Resolve-ExamplePath ".state\vendor-flow\app\vendor\dep\lib.rna") -Raw
    Assert-Contains -Text $VendoredAfter -Needle "    return 8" -Label "vendored formatted lib"
    [void](Invoke-RunaCaptured -Example ".state\vendor-flow\app" -Arguments @("check") -EnvVars $EnvVars)
    [void](Invoke-RunaCaptured -Example ".state\vendor-flow\app" -Arguments @("build") -EnvVars $EnvVars)
    Invoke-ExampleBinary -Example ".state\vendor-flow\app" -Product "app" -ExpectedExitCode 8
}

function Invoke-PublishArtifactsProof {
    $Root = Resolve-ExamplePath ".state\publish-artifacts"
    $RegistryRoot = Join-Path $Root "registry"
    New-Item -ItemType Directory -Force -Path $Root, $RegistryRoot | Out-Null
    $ConfigPath = Join-Path $Root "config.toml"
    Write-RegistryConfig -ConfigPath $ConfigPath -RegistryRoot $RegistryRoot
    $EnvVars = @{
        RUNA_CONFIG_PATH = (Resolve-Path -LiteralPath $ConfigPath).Path
    }

    Invoke-Runa -Example ".state\publish-artifacts" -Arguments @("new", "app")
    [void](Invoke-RunaCaptured -Example ".state\publish-artifacts\app" -Arguments @("publish", "local", "--artifacts") -EnvVars $EnvVars)

    Assert-ExamplePathExists -RelativePath ".state\publish-artifacts\registry\sources\app\2026.0.01\sources\main.rna"
    Assert-ExamplePathExists -RelativePath ".state\publish-artifacts\registry\artifacts\app\2026.0.01\app\bin\windows\payload\app.exe"
    Assert-ExamplePathExists -RelativePath ".state\publish-artifacts\app\dist\windows\app\app\app.exe"
}

Remove-GeneratedExampleOutputs
try {
    Invoke-SmokeExamples
    Invoke-BuildProofs
    Invoke-TestProofs
    Invoke-NewFlowProof
    Invoke-FmtExclusionProof
    Invoke-ManagedDependencyFlow
    Invoke-VendoredDependencyFlow
    Invoke-PublishArtifactsProof
} finally {
    Remove-GeneratedExampleOutputs
}

Write-Host "examples: ok"
