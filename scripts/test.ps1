$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$requiredFiles = @(
    ".github\workflows\test.yml",
    ".github\workflows\publish-core.yml",
    "scripts\build-core.ps1",
    "scripts\test-lean-lsp.js",
    "scripts\versions.psd1",
    "Initialize-PortableLean4.ps1",
    "Enter-PortableLean4.ps1",
    "Open-PortableLean4-VSCode.ps1",
    "init.ps1",
    "examples\hello\Main.lean",
    "examples\hello\lakefile.toml",
    "examples\hello\lean-toolchain",
    "vscode-extensions\manifest.json"
)
foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing required file: $relativePath" }
}

$parseErrors = @()
Get-ChildItem -LiteralPath $repoRoot -Filter "*.ps1" -Recurse | ForEach-Object {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    $parseErrors += @($errors | ForEach-Object { "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" })
}
if ($parseErrors.Count -gt 0) { throw ($parseErrors -join [Environment]::NewLine) }

$versions = Import-PowerShellDataFile (Join-Path $repoRoot "scripts\versions.psd1")
if ($versions.Lean.Toolchain -ne "leanprover/lean4:v$($versions.Lean.Version)") {
    throw "The pinned Lean version and toolchain disagree."
}
$toolchainFile = (Get-Content -LiteralPath (Join-Path $repoRoot "examples\hello\lean-toolchain") -Raw).Trim()
if ($toolchainFile -ne $versions.Lean.Toolchain) { throw "The example toolchain is not pinned to the configured Lean version." }

$extensionManifest = Get-Content -LiteralPath (Join-Path $repoRoot "vscode-extensions\manifest.json") -Raw | ConvertFrom-Json
if (@($extensionManifest.extensions).Count -lt 2) { throw "The extension manifest must include Lean 4 and Tombi." }
foreach ($extension in $extensionManifest.extensions) {
    if ($extension.sha256 -notmatch '^[0-9a-f]{64}$') { throw "Invalid SHA-256 for $($extension.id)." }
}

Write-Host "Repository validation passed." -ForegroundColor Green

