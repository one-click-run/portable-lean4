$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$requiredFiles = @(
    ".github\workflows\test.yml",
    ".github\workflows\publish-core.yml",
    ".github\workflows\publish-full.yml",
    "scripts\build-core.ps1",
    "scripts\build-full.ps1",
    "scripts\test-lean-lsp.js",
    "scripts\versions.psd1",
    "Initialize-PortableLean4.ps1",
    "Enter-PortableLean4.ps1",
    "Open-PortableLean4-VSCode.ps1",
    "init.ps1",
    "init-full.ps1",
    "examples\hello\Main.lean",
    "examples\hello\lakefile.toml",
    "examples\hello\lean-toolchain",
    "examples\mathlib\Main.lean",
    "examples\mathlib\lakefile.toml",
    "examples\mathlib\lean-toolchain",
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
$mathlibToolchainFile = (Get-Content -LiteralPath (Join-Path $repoRoot "examples\mathlib\lean-toolchain") -Raw).Trim()
if ($mathlibToolchainFile -ne $versions.Lean.Toolchain) { throw "The Mathlib example toolchain is not pinned to the configured Lean version." }
if ($versions.Mathlib.Tag -ne "v$($versions.Lean.Version)" -or $versions.Mathlib.Version -ne $versions.Lean.Version) {
    throw "Mathlib must use the release matching the pinned Lean version."
}
if ($versions.Mathlib.Commit -notmatch '^[0-9a-f]{40}$') { throw "The Mathlib commit must be a full Git SHA." }
$mathlibLakefile = Get-Content -LiteralPath (Join-Path $repoRoot "examples\mathlib\lakefile.toml") -Raw
if ($mathlibLakefile -notmatch [regex]::Escape("rev = `"$($versions.Mathlib.Tag)`"")) {
    throw "The Mathlib example does not require the configured release tag."
}
if ($mathlibLakefile -notmatch [regex]::Escape('defaultTargets = ["Main"]')) {
    throw "The Mathlib example must make Main the default incremental build target."
}
if ($mathlibLakefile -notmatch '(?ms)\[\[lean_lib\]\]\s*name\s*=\s*"Main"') {
    throw "The Mathlib example must register Main as a Lean library target."
}
$mathlibExample = Get-Content -LiteralPath (Join-Path $repoRoot "examples\mathlib\Main.lean") -Raw
if ($mathlibExample -notmatch '(?m)^module\s*$') {
    throw "The Mathlib example must use the Lean module system."
}
if ($mathlibExample -match '(?m)^\s*import\s+Mathlib\s*$') {
    throw "The bundled smoke-test example must not import the entire Mathlib umbrella module."
}
$entryScript = Get-Content -LiteralPath (Join-Path $repoRoot "Enter-PortableLean4.ps1") -Raw
if ($entryScript -match [regex]::Escape('lake env lean Main.lean')) {
    throw "The Mathlib self-check must use Lake's incremental build cache."
}

$extensionManifest = Get-Content -LiteralPath (Join-Path $repoRoot "vscode-extensions\manifest.json") -Raw | ConvertFrom-Json
if (@($extensionManifest.extensions).Count -lt 3) { throw "The extension manifest must include Lean 4, Even Better TOML, and Tombi." }
$extensionIds = @($extensionManifest.extensions | ForEach-Object { $_.id })
foreach ($requiredExtension in @("tamasfe.even-better-toml", "leanprover.lean4", "tombi-toml.tombi")) {
    if ($extensionIds -notcontains $requiredExtension) { throw "Missing required VS Code extension: $requiredExtension" }
}
foreach ($extension in $extensionManifest.extensions) {
    if ($extension.sha256 -notmatch '^[0-9a-f]{64}$') { throw "Invalid SHA-256 for $($extension.id)." }
}
$vscodeLauncher = Get-Content -LiteralPath (Join-Path $repoRoot "Open-PortableLean4-VSCode.ps1") -Raw
if ($vscodeLauncher -notmatch [regex]::Escape("--do-not-include-pack-dependencies")) {
    throw "The VS Code launcher must prevent bundled VSIX files from fetching Marketplace dependencies."
}

Write-Host "Repository validation passed." -ForegroundColor Green

