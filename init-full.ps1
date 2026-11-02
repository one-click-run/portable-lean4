param(
    [string]$InstallName = $env:ONE_CLICK_RUN_PORTABLE_LEAN4_INSTALL_NAME,
    [string]$Repository = $(if ($env:ONE_CLICK_RUN_PORTABLE_LEAN4_REPOSITORY) { $env:ONE_CLICK_RUN_PORTABLE_LEAN4_REPOSITORY } else { "one-click-run/portable-lean4" }),
    [string]$CoreReleaseTag = "core",
    [string]$FullReleaseTag = "full",
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

function Receive-File([string]$Uri, [string]$Destination) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source --fail --location --retry 8 --retry-delay 2 --retry-all-errors `
            --continue-at - --output $Destination $Uri
        if ($LASTEXITCODE -ne 0) { throw "curl failed to download $Uri (exit code $LASTEXITCODE)." }
    } else {
        Invoke-WebRequest -Uri $Uri -Headers $script:headers -UseBasicParsing -OutFile $Destination
    }
}

function Expand-Zip([string]$ArchivePath, [string]$DestinationPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $DestinationPath)
}

function Read-ExpectedHash([string]$ChecksumPath) {
    $hash = ([regex]::Match([IO.File]::ReadAllText($ChecksumPath), '(?i)\b[0-9a-f]{64}\b')).Value.ToLowerInvariant()
    if (-not $hash) { throw "Could not parse the SHA-256 file: $ChecksumPath" }
    return $hash
}

function Assert-Verified([string]$ArchivePath, [string]$ChecksumPath) {
    $expected = Read-ExpectedHash $ChecksumPath
    $actual = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "SHA-256 verification failed for $ArchivePath. Expected $expected but got $actual." }
}

function Get-ReleasePair([string]$Tag, [string]$Pattern) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/$Tag" -Headers $script:headers
    $assets = @($release.assets | Where-Object { $_.name -match $Pattern })
    if ($assets.Count -ne 1) { throw "Release $Tag must contain exactly one matching archive." }
    $archiveAsset = $assets[0]
    $checksumAssets = @($release.assets | Where-Object { $_.name -eq "$($archiveAsset.name).sha256" })
    if ($checksumAssets.Count -ne 1) { throw "Missing checksum for $($archiveAsset.name)." }
    return [pscustomobject]@{ Archive = $archiveAsset; Checksum = $checksumAssets[0] }
}

function Receive-ReleasePair($Pair, [string]$WorkDirectory) {
    $archivePath = Join-Path $WorkDirectory $Pair.Archive.name
    $checksumPath = Join-Path $WorkDirectory $Pair.Checksum.name
    $cached = $false
    if ((Test-Path -LiteralPath $archivePath -PathType Leaf) -and (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        try {
            Assert-Verified $archivePath $checksumPath
            $cached = $true
        } catch {
            $cached = $false
        }
    }
    if ($cached) {
        Write-Step "Reusing verified download $($Pair.Archive.name)"
    } else {
        Write-Step "Downloading $($Pair.Archive.name)"
        Receive-File $Pair.Archive.browser_download_url $archivePath
        Receive-File $Pair.Checksum.browser_download_url $checksumPath
    }
    return [pscustomobject]@{ Archive = $archivePath; Checksum = $checksumPath }
}

if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64" -and $env:PROCESSOR_ARCHITEW6432 -ne "AMD64") {
    throw "Only Windows x86-64 is currently supported."
}
if (($CoreArchive -or $CoreChecksum -or $MathlibArchive -or $MathlibChecksum) -and -not ($CoreArchive -and $MathlibArchive)) {
    throw "Offline installation requires both -CoreArchive and -MathlibArchive."
}

$installBase = (Get-Location).Path
$script:headers = @{ Accept = "application/vnd.github+json"; "User-Agent" = "one-click-run-portable-lean4" }
$localMode = [bool]$CoreArchive
if ($localMode) {
    $coreLocal = (Resolve-Path -LiteralPath $CoreArchive).Path
    $mathlibLocal = (Resolve-Path -LiteralPath $MathlibArchive).Path
    if (-not $CoreChecksum) { $CoreChecksum = "$coreLocal.sha256" }
    if (-not $MathlibChecksum) { $MathlibChecksum = "$mathlibLocal.sha256" }
    $coreChecksumLocal = (Resolve-Path -LiteralPath $CoreChecksum).Path
    $mathlibChecksumLocal = (Resolve-Path -LiteralPath $MathlibChecksum).Path
    $mathlibName = Split-Path -Leaf $mathlibLocal
} else {
    Write-Step "Reading the Core and Full releases from $Repository"
    $corePair = Get-ReleasePair $CoreReleaseTag '^portable-lean4-core-.*-windows-x86_64\.zip$'
    $mathlibPair = Get-ReleasePair $FullReleaseTag '^portable-lean4-mathlib-.*-windows-x86_64\.zip$'
    $mathlibName = $mathlibPair.Archive.name
}

$versionLabel = $mathlibName -replace '^portable-lean4-mathlib-', '' -replace '-windows-x86_64\.zip$', ''
if (-not $InstallName) { $InstallName = "full-$versionLabel" }
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

$work = Join-Path $installBase ".$folderName.installing"
$workFull = [IO.Path]::GetFullPath($work)
if (-not $workFull.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use an installation workspace outside the selected directory."
}
$staging = Join-Path $work "payload"
$overlayStaging = Join-Path $work "overlay"
$installationComplete = $false
try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    foreach ($directory in @($staging, $overlayStaging)) {
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    if ($localMode) {
        $coreFiles = [pscustomobject]@{ Archive = $coreLocal; Checksum = $coreChecksumLocal }
        $mathlibFiles = [pscustomobject]@{ Archive = $mathlibLocal; Checksum = $mathlibChecksumLocal }
    } else {
        $coreFiles = Receive-ReleasePair $corePair $work
        $mathlibFiles = Receive-ReleasePair $mathlibPair $work
    }

    Write-Step "Verifying Core and Mathlib SHA-256 files"
    Assert-Verified $coreFiles.Archive $coreFiles.Checksum
    Assert-Verified $mathlibFiles.Archive $mathlibFiles.Checksum

    Write-Step "Extracting Core"
    Expand-Zip $coreFiles.Archive $staging
    Write-Step "Applying the Mathlib offline layer"
    Expand-Zip $mathlibFiles.Archive $overlayStaging
    Copy-Item -Path (Join-Path $overlayStaging "*") -Destination $staging -Recurse -Force

    if (-not (Test-Path -LiteralPath (Join-Path $staging "examples\mathlib\.lake\packages\mathlib\Mathlib.lean") -PathType Leaf)) {
        throw "The Mathlib overlay has an invalid layout."
    }
    Write-Step "Checking the extracted full environment"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $staging "Enter-PortableLean4.ps1") -CheckMathlib
    if ($LASTEXITCODE -ne 0) { throw "The extracted Mathlib environment failed its self-check." }
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
title Portable Lean 4 + Mathlib - VS Code
echo Portable VS Code settings and extensions are stored under:
echo   %~dp0$folderName\data
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0$folderName\Open-PortableLean4-VSCode.ps1"
set "OCR_EXIT=%ERRORLEVEL%"
if not "%OCR_EXIT%"=="0" (
  echo.
  echo Portable Lean 4 + Mathlib VS Code startup failed. See the message above.
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
        Write-Warning "Installation failed. Verified downloads in $work were kept for a later retry."
    }
}

Write-Step "Installation complete"
Write-Host "Double-click $folderName.cmd for the portable terminal." -ForegroundColor Green
Write-Host "Double-click $folderName-VSCode.cmd for the isolated Mathlib workspace." -ForegroundColor Green
