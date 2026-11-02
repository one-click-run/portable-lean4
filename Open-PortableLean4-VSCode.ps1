param(
    [switch]$Check,
    [string]$CodePath = $env:ONE_CLICK_RUN_VSCODE,
    [switch]$CheckExtensions
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = $PSScriptRoot

function Find-VSCode([string]$RequestedPath) {
    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw "ONE_CLICK_RUN_VSCODE does not point to a file: $RequestedPath"
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    foreach ($commandName in @("code.cmd", "code.exe")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) { return $(if ($command.Source) { $command.Source } else { $command.Path }) }
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"),
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\Code.exe"),
        (Join-Path $env:ProgramFiles "Microsoft VS Code\bin\code.cmd"),
        (Join-Path $env:ProgramFiles "Microsoft VS Code\Code.exe")
    )
    $match = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if ($match) { return $match }
    throw "Microsoft Visual Studio Code was not found. Install VS Code, or set ONE_CLICK_RUN_VSCODE to code.cmd or Code.exe."
}

function Read-BundledExtensionManifest {
    $manifestPath = Join-Path $root "vscode-extensions\extensions.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Bundled extension manifest is missing: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($extension in $manifest.extensions) {
        $vsix = Join-Path (Split-Path -Parent $manifestPath) $extension.file
        if (-not (Test-Path -LiteralPath $vsix -PathType Leaf)) { throw "Bundled VSIX is missing: $vsix" }
        $actual = (Get-FileHash -LiteralPath $vsix -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $extension.sha256) { throw "Bundled VSIX checksum mismatch: $($extension.file)" }
    }
    return $manifest
}

function Install-BundledExtensions([string]$VSCode, $Manifest, [string]$UserData, [string]$ExtensionsDirectory) {
    $versionText = @(& $VSCode --version 2>&1)[0]
    if ($LASTEXITCODE -ne 0 -or -not $versionText) { throw "VS Code could not report its version." }
    if ([version]$versionText -lt [version]$Manifest.minimumVSCodeVersion) {
        throw "VS Code $versionText is too old. Version $($Manifest.minimumVSCodeVersion) or newer is required."
    }

    New-Item -ItemType Directory -Path $ExtensionsDirectory, (Join-Path $UserData "User") -Force | Out-Null
    $installed = @(& $VSCode --user-data-dir $UserData --extensions-dir $ExtensionsDirectory --list-extensions --show-versions 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "VS Code could not inspect the portable extension directory." }

    foreach ($extension in $Manifest.extensions) {
        $expected = "$($extension.id)@$($extension.version)"
        if ($installed -notcontains $expected) {
            $vsix = Join-Path $root "vscode-extensions\$($extension.file)"
            & $VSCode --user-data-dir $UserData --extensions-dir $ExtensionsDirectory --install-extension $vsix --force | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Offline installation failed for $expected." }
        }
    }

    $installed = @(& $VSCode --user-data-dir $UserData --extensions-dir $ExtensionsDirectory --list-extensions --show-versions 2>&1)
    foreach ($extension in $Manifest.extensions) {
        $expected = "$($extension.id)@$($extension.version)"
        if ($installed -notcontains $expected) { throw "Portable extension verification failed: $expected" }
    }
}

# Resolve VS Code before USERPROFILE is redirected for the child process.
$resolvedCode = $null
if (-not $Check) { $resolvedCode = Find-VSCode $CodePath }

. (Join-Path $root "Initialize-PortableLean4.ps1")
$portable = Initialize-PortableLean4Environment -Root $root -IsolateUserProfile
$userData = Join-Path $root "data\vscode-user-data"
$extensionsDirectory = Join-Path $root "data\vscode-extensions"
$userSettingsDirectory = Join-Path $userData "User"
New-Item -ItemType Directory -Path $userSettingsDirectory -Force | Out-Null
$settingsPath = Join-Path $userSettingsDirectory "settings.json"
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    $settings = [ordered]@{
        "extensions.autoCheckUpdates" = $false
        "extensions.autoUpdate" = $false
        "update.mode" = "none"
        "telemetry.telemetryLevel" = "off"
        "lean4.alwaysAskBeforeInstallingLeanVersions" = $true
        "lean4.showSetupWarnings" = $false
        "security.workspace.trust.enabled" = $false
        "window.restoreWindows" = "none"
        "workbench.startupEditor" = "none"
        "git.enabled" = $false
    }
    [IO.File]::WriteAllText($settingsPath, (($settings | ConvertTo-Json) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

$mathlibExample = Join-Path $root "examples\mathlib"
$workspaceFolder = if (Test-Path -LiteralPath (Join-Path $mathlibExample ".lake\packages\mathlib\Mathlib.lean") -PathType Leaf) {
    $mathlibExample
} else {
    Join-Path $root "examples\hello"
}
$workspace = Join-Path $root "Portable-Lean4.code-workspace"
$workspaceDefinition = [ordered]@{
    folders = @([ordered]@{ path = $workspaceFolder })
    settings = [ordered]@{
        "terminal.integrated.env.windows" = [ordered]@{
            ELAN_HOME = $portable.ElanHome
            ELAN_TOOLCHAIN = $portable.Toolchain
            HOME = $portable.PortableHome
            USERPROFILE = $portable.PortableHome
            PATH = $env:PATH
        }
    }
}
[IO.File]::WriteAllText($workspace, (($workspaceDefinition | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

$manifest = Read-BundledExtensionManifest
if ($Check) {
    Write-Host "VS Code workspace configuration OK: $workspace" -ForegroundColor Green
    Write-Host "Bundled VSIX checksums OK." -ForegroundColor Green
    Write-Host "VS Code will use isolated USERPROFILE: $($portable.PortableHome)" -ForegroundColor Green
    exit 0
}

Install-BundledExtensions $resolvedCode $manifest $userData $extensionsDirectory
if ($CheckExtensions) {
    Write-Host "Offline VS Code extension installation OK: $extensionsDirectory" -ForegroundColor Green
    exit 0
}

& $resolvedCode --user-data-dir $userData --extensions-dir $extensionsDirectory --new-window $workspace
if ($LASTEXITCODE -ne 0) { throw "VS Code failed to start (exit code $LASTEXITCODE)." }

