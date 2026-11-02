param(
    [string]$InstallName = $env:ONE_CLICK_RUN_PORTABLE_LEAN4_INSTALL_NAME,
    [string]$Repository = $(if ($env:ONE_CLICK_RUN_PORTABLE_LEAN4_REPOSITORY) { $env:ONE_CLICK_RUN_PORTABLE_LEAN4_REPOSITORY } else { "one-click-run/portable-lean4" }),
    [string]$ReleaseTag = $(if ($env:ONE_CLICK_RUN_PORTABLE_LEAN4_RELEASE_TAG) { $env:ONE_CLICK_RUN_PORTABLE_LEAN4_RELEASE_TAG } else { "core" }),
    [string]$Archive = $env:ONE_CLICK_RUN_PORTABLE_LEAN4_ARCHIVE,
    [string]$Checksum = $env:ONE_CLICK_RUN_PORTABLE_LEAN4_CHECKSUM,
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
        return
    }
    Invoke-WebRequest -Uri $Uri -Headers $script:headers -UseBasicParsing -OutFile $Destination
}

function Expand-ToolchainArchive([string]$ArchivePath, [string]$DestinationPath) {
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        & $tar.Source -xf $ArchivePath -C $DestinationPath
        if ($LASTEXITCODE -ne 0) { throw "tar failed to extract the verified archive." }
        return
    }
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

