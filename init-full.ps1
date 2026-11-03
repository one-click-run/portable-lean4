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

function Get-MathlibReleasePackage([string]$Tag) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/$Tag" -Headers $script:headers
    $wholeArchives = @($release.assets | Where-Object { $_.name -match '^portable-lean4-mathlib-.*-windows-x86_64\.zip$' })
    if ($wholeArchives.Count -eq 1) {
        $checksum = @($release.assets | Where-Object { $_.name -eq "$($wholeArchives[0].name).sha256" })
        if ($checksum.Count -ne 1) { throw "Missing checksum for $($wholeArchives[0].name)." }
        return [pscustomobject]@{
            Mode = "whole"
            BaseName = $wholeArchives[0].name
            Archive = $wholeArchives[0]
            Checksum = $checksum[0]
            Parts = @()
        }
    }

    $parts = @($release.assets | Where-Object { $_.name -match '^portable-lean4-mathlib-.*-windows-x86_64\.zip\.part\d{3}$' } | Sort-Object name)
    if ($parts.Count -lt 2) { throw "Release $Tag contains neither a complete Mathlib archive nor a valid multipart archive." }
    $baseName = $parts[0].name -replace '\.part\d{3}$', ''
    for ($index = 0; $index -lt $parts.Count; $index++) {
        $expectedName = "{0}.part{1:D3}" -f $baseName, ($index + 1)
        if ($parts[$index].name -ne $expectedName) { throw "Mathlib release parts are not contiguous at $expectedName." }
    }
    $wholeChecksum = @($release.assets | Where-Object { $_.name -eq "$baseName.sha256" })
    if ($wholeChecksum.Count -ne 1) { throw "Missing whole-archive checksum for $baseName." }
    $partPairs = @($parts | ForEach-Object {
        $part = $_
        $partChecksum = @($release.assets | Where-Object { $_.name -eq "$($part.name).sha256" })
        if ($partChecksum.Count -ne 1) { throw "Missing checksum for $($part.name)." }
        [pscustomobject]@{ Archive = $part; Checksum = $partChecksum[0] }
    })
    return [pscustomobject]@{
        Mode = "parts"
        BaseName = $baseName
        Archive = $null
        Checksum = $wholeChecksum[0]
        Parts = $partPairs
    }
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

function Receive-MathlibPackage($Package, [string]$WorkDirectory) {
    if ($Package.Mode -eq "whole") {
        return (Receive-ReleasePair $Package $WorkDirectory)
    }

    $archivePath = Join-Path $WorkDirectory $Package.BaseName
    $checksumPath = Join-Path $WorkDirectory $Package.Checksum.name
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        Receive-File $Package.Checksum.browser_download_url $checksumPath
    }
    if ((Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        try {
            Assert-Verified $archivePath $checksumPath
            Write-Step "Reusing verified assembled archive $($Package.BaseName)"
            return [pscustomobject]@{ Archive = $archivePath; Checksum = $checksumPath }
        } catch {
            Remove-Item -LiteralPath $archivePath -Force
        }
    }

    $partFiles = @($Package.Parts | ForEach-Object { Receive-ReleasePair $_ $WorkDirectory })
    Write-Step "Assembling $($Package.BaseName) from $($partFiles.Count) verified parts"
    $output = [IO.File]::Create($archivePath)
    try {
        foreach ($part in $partFiles) {
            $input = [IO.File]::OpenRead($part.Archive)
            try { $input.CopyTo($output) } finally { $input.Dispose() }
        }
    } finally {
        $output.Dispose()
    }
    Assert-Verified $archivePath $checksumPath
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
$mathlibPartFilesLocal = @()
if ($localMode) {
    $coreLocal = (Resolve-Path -LiteralPath $CoreArchive).Path
    $mathlibInput = (Resolve-Path -LiteralPath $MathlibArchive).Path
    if (-not $CoreChecksum) { $CoreChecksum = "$coreLocal.sha256" }
    $coreChecksumLocal = (Resolve-Path -LiteralPath $CoreChecksum).Path
    if ((Split-Path -Leaf $mathlibInput) -match '^(.*\.zip)\.part001$') {
        $mathlibName = $Matches[1]
        $partPrefix = Join-Path (Split-Path -Parent $mathlibInput) $mathlibName
        $mathlibPartFilesLocal = @(Get-ChildItem -Path "$partPrefix.part*" -File | Where-Object { $_.Name -match '\.part\d{3}$' } | Sort-Object Name | ForEach-Object { $_.FullName })
        if ($mathlibPartFilesLocal.Count -lt 2) { throw "The local multipart Mathlib archive is incomplete." }
        for ($index = 0; $index -lt $mathlibPartFilesLocal.Count; $index++) {
            $expectedName = "{0}.part{1:D3}" -f $mathlibName, ($index + 1)
            if ((Split-Path -Leaf $mathlibPartFilesLocal[$index]) -ne $expectedName) { throw "Local Mathlib parts are not contiguous at $expectedName." }
            [void](Resolve-Path -LiteralPath "$($mathlibPartFilesLocal[$index]).sha256")
        }
        if (-not $MathlibChecksum) { $MathlibChecksum = "$partPrefix.sha256" }
        $mathlibLocal = $null
    } else {
        $mathlibLocal = $mathlibInput
        $mathlibName = Split-Path -Leaf $mathlibLocal
        if (-not $MathlibChecksum) { $MathlibChecksum = "$mathlibLocal.sha256" }
    }
    $mathlibChecksumLocal = (Resolve-Path -LiteralPath $MathlibChecksum).Path
} else {
    Write-Step "Reading the Core and Full releases from $Repository"
    $corePair = Get-ReleasePair $CoreReleaseTag '^portable-lean4-core-.*-windows-x86_64\.zip$'
    $mathlibPackage = Get-MathlibReleasePackage $FullReleaseTag
    $mathlibName = $mathlibPackage.BaseName
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
        if ($mathlibPartFilesLocal.Count -gt 0) {
            $assembledLocal = Join-Path $work $mathlibName
            $output = [IO.File]::Create($assembledLocal)
            try {
                foreach ($partPath in $mathlibPartFilesLocal) {
                    Assert-Verified $partPath "$partPath.sha256"
                    $input = [IO.File]::OpenRead($partPath)
                    try { $input.CopyTo($output) } finally { $input.Dispose() }
                }
            } finally {
                $output.Dispose()
            }
            $mathlibFiles = [pscustomobject]@{ Archive = $assembledLocal; Checksum = $mathlibChecksumLocal }
        } else {
            $mathlibFiles = [pscustomobject]@{ Archive = $mathlibLocal; Checksum = $mathlibChecksumLocal }
        }
    } else {
        $coreFiles = Receive-ReleasePair $corePair $work
        $mathlibFiles = Receive-MathlibPackage $mathlibPackage $work
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
    Write-Host "Mathlib's first self-check may be quiet for several minutes." -ForegroundColor Yellow
    Write-Host "The rotating marker below means the check is still running; please keep this window open." -ForegroundColor Yellow
    Write-Host "Windows Defender may scan thousands of cached files during this step." -ForegroundColor DarkGray
    $checkScript = Join-Path $staging "Enter-PortableLean4.ps1"
    $checkArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$checkScript`" -CheckMathlib"
    $checkStdout = Join-Path $work "mathlib-check.stdout.log"
    $checkStderr = Join-Path $work "mathlib-check.stderr.log"
    $checkProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $checkArguments `
        -RedirectStandardOutput $checkStdout -RedirectStandardError $checkStderr -PassThru
    $spinner = @("|", "/", "-", "\")
    $spinnerIndex = 0
    $checkTimer = [Diagnostics.Stopwatch]::StartNew()
    if ([Console]::IsOutputRedirected) {
        $checkProcess.WaitForExit()
    } else {
        while (-not $checkProcess.HasExited) {
            $elapsed = $checkTimer.Elapsed.ToString("hh\:mm\:ss")
            Write-Host ("`r[{0}] Checking Mathlib... {1}" -f $spinner[$spinnerIndex], $elapsed) -NoNewline -ForegroundColor Yellow
            $spinnerIndex = ($spinnerIndex + 1) % $spinner.Count
            Start-Sleep -Milliseconds 150
            $checkProcess.Refresh()
        }
    }
    $checkProcess.WaitForExit()
    $checkTimer.Stop()
    Write-Host ("`r{0}`r" -f (" " * 78)) -NoNewline
    $checkOutput = if (Test-Path -LiteralPath $checkStdout) { Get-Content -LiteralPath $checkStdout -Raw } else { "" }
    $checkErrors = if (Test-Path -LiteralPath $checkStderr) { Get-Content -LiteralPath $checkStderr -Raw } else { "" }
    if ($checkOutput) { Write-Host ($checkOutput.TrimEnd()) }
    if ($checkErrors) { Write-Host ($checkErrors.TrimEnd()) -ForegroundColor Red }
    if ($checkProcess.ExitCode -ne 0) { throw "The extracted Mathlib environment failed its self-check." }
    Write-Host ("Mathlib self-check completed in {0}." -f $checkTimer.Elapsed.ToString("hh\:mm\:ss")) -ForegroundColor Green
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
