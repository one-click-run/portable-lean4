param(
    [switch]$Check,
    [switch]$CheckProject,
    [switch]$CheckMathlib
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Initialize-PortableLean4.ps1")

$portable = Initialize-PortableLean4Environment -Root $PSScriptRoot

if ($Check -or $CheckProject -or $CheckMathlib) {
    foreach ($tool in @("elan", "lean", "lake", "leanc")) {
        $resolved = Get-Command $tool -ErrorAction SilentlyContinue
        if (-not $resolved) { throw "Missing bundled tool: $tool" }
        if (-not $resolved.Source.StartsWith($portable.Root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$tool resolved outside the portable directory: $($resolved.Source)"
        }
        Write-Host ("{0}: {1}" -f $tool, $resolved.Source)
    }

$leanVersionLines = @(& lean --version 2>&1)
$leanVersionExitCode = $LASTEXITCODE
$leanVersion = ($leanVersionLines -join ' ').Trim()
if ($leanVersionExitCode -ne 0 -or $leanVersion -notmatch '(?<!\d)4\.35\.0(?!\d)') {
        throw "Unexpected Lean version: $leanVersion"
    }
    & lake --version | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Lake version check failed." }

    if ($CheckProject) {
        $example = Join-Path $portable.Root "examples\hello"
        Push-Location $example
        try {
            & lake build
            if ($LASTEXITCODE -ne 0) { throw "The bundled example failed to build." }
            $hello = Join-Path $example ".lake\build\bin\hello.exe"
            if (-not (Test-Path -LiteralPath $hello -PathType Leaf)) {
                throw "The bundled example executable was not created."
            }
            $output = (& $hello).Trim()
            if ($output -ne "Hello from portable Lean 4!") {
                throw "Unexpected example output: $output"
            }
        } finally {
            Pop-Location
        }
    }

    if ($CheckMathlib) {
        $example = Join-Path $portable.Root "examples\mathlib"
        if (-not (Test-Path -LiteralPath (Join-Path $example ".lake\packages\mathlib\Mathlib.lean") -PathType Leaf)) {
            throw "The bundled Mathlib source tree is missing."
        }
        Push-Location $example
        try {
            & lake env lean Main.lean
            if ($LASTEXITCODE -ne 0) { throw "The bundled Mathlib example failed to typecheck." }
        } finally {
            Pop-Location
        }
    }

    Write-Host $leanVersion -ForegroundColor Green
    Write-Host "Portable Lean 4 checks passed." -ForegroundColor Green
    exit 0
}

$hasMathlib = Test-Path -LiteralPath (Join-Path $portable.Root "examples\mathlib\.lake\packages\mathlib\Mathlib.lean") -PathType Leaf
$edition = if ($hasMathlib) { "Portable Lean 4 + Mathlib" } else { "Portable Lean 4" }
$host.UI.RawUI.WindowTitle = $edition
Write-Host "$edition environment" -ForegroundColor Green
Write-Host (& lean --version | Select-Object -First 1)
Write-Host "Toolchain: $($portable.Toolchain)" -ForegroundColor DarkGray
Write-Host "The current shell is isolated and does not modify the system PATH." -ForegroundColor DarkGray
Write-Host "Bundled tools work offline. Explicit package updates may require network access." -ForegroundColor DarkGray
& $env:ComSpec /K "prompt (portable-lean4) `$P`$G"

