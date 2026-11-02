param(
    [string]$Edition = $env:ONE_CLICK_RUN_PORTABLE_LEAN4_EDITION,
    [string]$InstallName = $env:ONE_CLICK_RUN_PORTABLE_LEAN4_INSTALL_NAME,
    [string]$Repository = $(if ($env:ONE_CLICK_RUN_PORTABLE_LEAN4_REPOSITORY) { $env:ONE_CLICK_RUN_PORTABLE_LEAN4_REPOSITORY } else { "one-click-run/portable-lean4" }),
    [string]$ReleaseTag = $(if ($env:ONE_CLICK_RUN_PORTABLE_LEAN4_RELEASE_TAG) { $env:ONE_CLICK_RUN_PORTABLE_LEAN4_RELEASE_TAG } else { "core" }),
    [string]$Archive = $env:ONE_CLICK_RUN_PORTABLE_LEAN4_ARCHIVE,
    [string]$Checksum = $env:ONE_CLICK_RUN_PORTABLE_LEAN4_CHECKSUM,
    [string]$CoreArchive,
    [string]$CoreChecksum,
    [string]$MathlibArchive,
    [string]$MathlibChecksum,
    [switch]$Force = ($env:ONE_CLICK_RUN_PORTABLE_LEAN4_FORCE -eq "1")
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Select-Edition {
    if ($Edition) {
        $normalized = $Edition.Trim().ToLowerInvariant()
        if ($normalized -eq "mathlib" -or $normalized -eq "complete") { $normalized = "full" }
        if ($normalized -notin @("core", "full")) {
            throw "Unknown edition '$Edition'. Choose core or full."
        }
        return $normalized
    }

    $choices = @(
        [pscustomobject]@{
            Edition = "core"
            Name = "Core"
            Download = "about 0.9 GB"
            Contents = "Lean 4, Lake, compiler toolchain, and offline VS Code extensions"
        },
        [pscustomobject]@{
            Edition = "full"
            Name = "Full (Mathlib)"
            Download = "about 3.0 GB"
            Contents = "Core plus Mathlib sources, dependencies, and official build cache"
        }
    )

    $grid = Get-Command Out-GridView -ErrorAction SilentlyContinue
    if ($grid -and [Environment]::UserInteractive) {
        $selected = $choices | Select-Object Name, Download, Contents, Edition |
            Out-GridView -Title "Select a portable Lean 4 edition" -OutputMode Single
        if ($selected) { return $selected.Edition }
        return $null
    }

    Write-Host "Available portable Lean 4 editions:"
    for ($index = 0; $index -lt $choices.Count; $index++) {
        $choice = $choices[$index]
        Write-Host ("  [{0}] {1,-15} {2} - {3}" -f ($index + 1), $choice.Name, $choice.Download, $choice.Contents)
    }
    $answer = Read-Host "Enter a number"
    $selectedIndex = 0
    if (-not [int]::TryParse($answer, [ref]$selectedIndex) -or $selectedIndex -lt 1 -or $selectedIndex -gt $choices.Count) {
        throw "Invalid selection."
    }
    return $choices[$selectedIndex - 1].Edition
}

function Invoke-FullInstaller {
    $localInstaller = if ($PSScriptRoot) { Join-Path $PSScriptRoot "init-full.ps1" } else { $null }
    if ($localInstaller -and (Test-Path -LiteralPath $localInstaller -PathType Leaf)) {
        $installerSource = [IO.File]::ReadAllText($localInstaller)
    } else {
        $installerUri = "https://raw.githubusercontent.com/$Repository/main/init-full.ps1"
        Write-Step "Loading the Full edition installer"
        $installerSource = (Invoke-WebRequest -Uri $installerUri -Headers @{ "User-Agent" = "one-click-run-portable-lean4" } -UseBasicParsing).Content
    }
    $arguments = @{ Repository = $Repository }
    if ($InstallName) { $arguments.InstallName = $InstallName }
    if ($Force) { $arguments.Force = $true }
    if ($CoreArchive) { $arguments.CoreArchive = $CoreArchive }
    if ($CoreChecksum) { $arguments.CoreChecksum = $CoreChecksum }
    if ($MathlibArchive) { $arguments.MathlibArchive = $MathlibArchive }
    if ($MathlibChecksum) { $arguments.MathlibChecksum = $MathlibChecksum }
    & ([scriptblock]::Create($installerSource)) @arguments
}

if ($Archive -and ($CoreArchive -or $CoreChecksum -or $MathlibArchive -or $MathlibChecksum)) {
    throw "Do not combine the Core -Archive option with Full edition archive options."
}
if (-not $Edition -and ($CoreArchive -or $CoreChecksum -or $MathlibArchive -or $MathlibChecksum)) {
    $Edition = "full"
}
if (-not $Archive) {
    $selectedEdition = Select-Edition
    if (-not $selectedEdition) {
        Write-Host "No edition selected. Installation cancelled."
        return
    }
    if ($selectedEdition -eq "full") {
        Invoke-FullInstaller
        return
    }
} elseif ($Edition -and $Edition.Trim().ToLowerInvariant() -notin @("core")) {
    throw "The Core -Archive option cannot be combined with Edition '$Edition'. Use -CoreArchive and -MathlibArchive for an offline Full installation."
}

function Receive-File([string]$Uri, [string]$Destination) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source --fail --location --retry 8 --retry-delay 2 --retry-all-errors `
            --continue-at - --output $Destination $Uri
        if ($LASTEXITCODE -ne 0) { throw "curl failed to download $Uri (exit code $LASTEXITCODE)." }
        return
    }
    Invoke-WebRequest -Uri $Uri -Headers $script:headers -UseBasicParsing -OutFile $Destination
}

function Expand-ToolchainArchive([string]$ArchivePath, [string]$DestinationPath) {
    # Windows bsdtar cannot reliably chdir to non-ASCII destination paths.
    # ZipFile handles Unicode paths and avoids Expand-Archive's cleanup bug on
    # large archives in Windows PowerShell 5.1.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $DestinationPath)
}

if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64" -and $env:PROCESSOR_ARCHITEW6432 -ne "AMD64") {
    throw "Only Windows x86-64 is currently supported."
}

$installBase = (Get-Location).Path
$script:headers = @{ Accept = "application/vnd.github+json"; "User-Agent" = "one-click-run-portable-lean4" }
$localArchive = $null
$localChecksum = $null
if ($Archive) {
    $localArchive = (Resolve-Path -LiteralPath $Archive).Path
    if ((Split-Path -Leaf $localArchive) -notmatch '^portable-lean4-core-.*-windows-x86_64\.zip$') {
        throw "The local archive name is not a portable Lean 4 Core Windows x86-64 asset."
    }
    if (-not $Checksum) { $Checksum = "$localArchive.sha256" }
    $localChecksum = (Resolve-Path -LiteralPath $Checksum).Path
    $asset = [pscustomobject]@{ name = (Split-Path -Leaf $localArchive) }
    Write-Step "Using local release archive $($asset.name)"
} else {
    Write-Step "Reading the $ReleaseTag release from $Repository"
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/$ReleaseTag" -Headers $script:headers
    $assets = @($release.assets | Where-Object { $_.name -match '^portable-lean4-core-.*-windows-x86_64\.zip$' })
    if ($assets.Count -eq 0) { throw "The release has no Windows x86-64 Core archive. Run the Publish Core workflow first." }
    $asset = $assets | Sort-Object updated_at -Descending | Select-Object -First 1
}

$versionLabel = $asset.name -replace '^portable-lean4-core-', '' -replace '-windows-x86_64\.zip$', ''
if (-not $InstallName) { $InstallName = $versionLabel }
if ($InstallName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "The install name may contain only letters, digits, dots, underscores, and hyphens."
}

$folderName = "OCR-portable-lean4-$InstallName"
$destination = Join-Path $installBase $folderName
$launcher = Join-Path $installBase "$folderName.cmd"
$vscodeLauncher = Join-Path $installBase "$folderName-VSCode.cmd"
$expectedPrefix = $installBase.TrimEnd('\') + '\'
foreach ($target in @($destination, $launcher, $vscodeLauncher)) {
    $full = [IO.Path]::GetFullPath($target)
    if (-not $full.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a target outside the selected installation directory: $full"
    }
}

if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $launcher) -or (Test-Path -LiteralPath $vscodeLauncher)) {
    if (-not $Force) { throw "$folderName already exists. Choose another name or use -Force." }
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    if (Test-Path -LiteralPath $launcher) { Remove-Item -LiteralPath $launcher -Force }
    if (Test-Path -LiteralPath $vscodeLauncher) { Remove-Item -LiteralPath $vscodeLauncher -Force }
}

$checksumName = "$($asset.name).sha256"
if (-not $localArchive) {
    $checksumAsset = @($release.assets | Where-Object { $_.name -eq $checksumName })
    if ($checksumAsset.Count -ne 1) { throw "Missing checksum asset $checksumName. Refusing an unverified installation." }
}

$work = Join-Path $installBase ".$folderName.installing"
$workFull = [IO.Path]::GetFullPath($work)
if (-not $workFull.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use an installation workspace outside the selected directory."
}
$downloadedArchive = Join-Path $work $asset.name
$downloadedChecksum = Join-Path $work $checksumName
$staging = Join-Path $work "payload"
$installationComplete = $false
try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null

    if ($localArchive) {
        $archiveForInstall = $localArchive
        $checksumForInstall = $localChecksum
    } else {
        $cachedValid = $false
        if ((Test-Path -LiteralPath $downloadedArchive) -and (Test-Path -LiteralPath $downloadedChecksum)) {
            $cachedExpected = ([regex]::Match([IO.File]::ReadAllText($downloadedChecksum), '(?i)\b[0-9a-f]{64}\b')).Value.ToLowerInvariant()
            if ($cachedExpected) {
                $cachedActual = (Get-FileHash -LiteralPath $downloadedArchive -Algorithm SHA256).Hash.ToLowerInvariant()
                $cachedValid = ($cachedActual -eq $cachedExpected)
            }
        }
        if ($cachedValid) {
            Write-Step "Reusing the verified download $($asset.name)"
        } else {
            Write-Step "Downloading $($asset.name)"
            Receive-File $asset.browser_download_url $downloadedArchive
            Receive-File $checksumAsset[0].browser_download_url $downloadedChecksum
        }
        $archiveForInstall = $downloadedArchive
        $checksumForInstall = $downloadedChecksum
    }

    Write-Step "Verifying SHA-256"
    $expected = ([regex]::Match([IO.File]::ReadAllText($checksumForInstall), '(?i)\b[0-9a-f]{64}\b')).Value.ToLowerInvariant()
    if (-not $expected) { throw "Could not parse the SHA-256 file." }
    $actual = (Get-FileHash -LiteralPath $archiveForInstall -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "SHA-256 verification failed. Expected $expected but got $actual." }

    Write-Step "Extracting the Core environment"
    Expand-ToolchainArchive $archiveForInstall $staging
    if (-not (Test-Path -LiteralPath (Join-Path $staging "Enter-PortableLean4.ps1") -PathType Leaf)) {
        throw "The release archive has an invalid layout."
    }

    Write-Step "Checking the extracted environment"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $staging "Enter-PortableLean4.ps1") -Check
    if ($LASTEXITCODE -ne 0) { throw "The extracted environment failed its self-check." }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $staging "Open-PortableLean4-VSCode.ps1") -Check
    if ($LASTEXITCODE -ne 0) { throw "The VS Code integration failed its self-check." }

    Move-Item -LiteralPath $staging -Destination $destination

    $launcherContent = @"
@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0$folderName\Enter-PortableLean4.ps1"
"@
    [IO.File]::WriteAllText($launcher, $launcherContent, [Text.UTF8Encoding]::new($false))

    $vscodeLauncherContent = @"
@echo off
setlocal
title Portable Lean 4 - VS Code
echo Portable VS Code settings and extensions are stored under:
echo   %~dp0$folderName\data
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0$folderName\Open-PortableLean4-VSCode.ps1"
set "OCR_EXIT=%ERRORLEVEL%"
if not "%OCR_EXIT%"=="0" (
  echo.
  echo Portable Lean 4 VS Code startup failed. See the message above.
  pause
)
exit /b %OCR_EXIT%
"@
    [IO.File]::WriteAllText($vscodeLauncher, $vscodeLauncherContent, [Text.UTF8Encoding]::new($false))
    $installationComplete = $true
} finally {
    if ($installationComplete -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    } elseif (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        if (-not $localArchive -and (Test-Path -LiteralPath $downloadedArchive)) {
            Write-Warning "Installation failed. The partial or completed download remains at $downloadedArchive for a later retry."
        }
    }
}

Write-Step "Installation complete"
Write-Host "Double-click $folderName.cmd for the portable terminal." -ForegroundColor Green
Write-Host "Double-click $folderName-VSCode.cmd for the isolated VS Code environment." -ForegroundColor Green

