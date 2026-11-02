param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "..\dist"),
    [string]$CacheDirectory = (Join-Path $PSScriptRoot "..\.cache")
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Receive-VerifiedFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Sha256
    )

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $cachedHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($cachedHash -eq $Sha256) {
            Write-Host "Using verified cache: $Destination"
            return
        }
        Remove-Item -LiteralPath $Destination -Force
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source --fail --location --retry 8 --retry-delay 2 --retry-all-errors `
            --continue-at - --output $Destination $Uri
        if ($LASTEXITCODE -ne 0) { throw "curl failed to download $Uri (exit code $LASTEXITCODE)." }
    } else {
        Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $Destination
    }

    $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $Sha256) {
        throw "Checksum mismatch for $Destination. Expected $Sha256, got $actualHash."
    }
}

function Expand-Zip([string]$Archive, [string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        & $tar.Source -xf $Archive -C $Destination
        if ($LASTEXITCODE -ne 0) { throw "tar failed to extract $Archive." }
        return
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$versions = Import-PowerShellDataFile (Join-Path $PSScriptRoot "versions.psd1")
$buildRoot = Join-Path $repoRoot ".build"
$payload = Join-Path $buildRoot "payload"
$resolvedBuildRoot = [IO.Path]::GetFullPath($buildRoot)
if (-not $resolvedBuildRoot.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean a build directory outside the repository: $resolvedBuildRoot"
}
if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
New-Item -ItemType Directory -Path $payload, $OutputDirectory, $CacheDirectory -Force | Out-Null

$leanArchive = Join-Path $CacheDirectory $versions.Lean.Asset
$elanArchive = Join-Path $CacheDirectory $versions.Elan.Asset
Write-Step "Downloading and verifying pinned upstream archives"
Receive-VerifiedFile -Uri $versions.Lean.Url -Destination $leanArchive -Sha256 $versions.Lean.Sha256
Receive-VerifiedFile -Uri $versions.Elan.Url -Destination $elanArchive -Sha256 $versions.Elan.Sha256

Write-Step "Installing elan into the portable home"
$elanUnpacked = Join-Path $buildRoot "elan-unpacked"
Expand-Zip $elanArchive $elanUnpacked
$elanInit = Join-Path $elanUnpacked "elan-init.exe"
if (-not (Test-Path -LiteralPath $elanInit -PathType Leaf)) { throw "elan-init.exe is missing from the verified archive." }
$portableHome = Join-Path $payload "data\home"
$elanHome = Join-Path $portableHome ".elan"
New-Item -ItemType Directory -Path $portableHome -Force | Out-Null
$savedElanHome = $env:ELAN_HOME
$savedUserProfile = $env:USERPROFILE
try {
    $env:ELAN_HOME = $elanHome
    $env:USERPROFILE = $portableHome
    & $elanInit -y --no-modify-path --default-toolchain none
    if ($LASTEXITCODE -ne 0) { throw "elan-init failed with exit code $LASTEXITCODE." }
} finally {
    $env:ELAN_HOME = $savedElanHome
    $env:USERPROFILE = $savedUserProfile
}

Write-Step "Extracting Lean $($versions.Lean.Version)"
$leanUnpacked = Join-Path $buildRoot "lean-unpacked"
Expand-Zip $leanArchive $leanUnpacked
$leanRoots = @(Get-ChildItem -LiteralPath $leanUnpacked -Directory)
if ($leanRoots.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $leanRoots[0].FullName "bin\lean.exe") -PathType Leaf)) {
    throw "The Lean archive has an unexpected layout."
}
$toolchainsRoot = Join-Path $elanHome "toolchains"
New-Item -ItemType Directory -Path $toolchainsRoot -Force | Out-Null
$toolchainDirectory = Join-Path $toolchainsRoot $versions.Lean.EncodedToolchain
Move-Item -LiteralPath $leanRoots[0].FullName -Destination $toolchainDirectory

$savedElanHome = $env:ELAN_HOME
$savedToolchain = $env:ELAN_TOOLCHAIN
try {
    $env:ELAN_HOME = $elanHome
    $env:ELAN_TOOLCHAIN = $versions.Lean.Toolchain
    & (Join-Path $elanHome "bin\elan.exe") default $versions.Lean.Toolchain
    if ($LASTEXITCODE -ne 0) { throw "Could not set the bundled default toolchain." }
} finally {
    $env:ELAN_HOME = $savedElanHome
    $env:ELAN_TOOLCHAIN = $savedToolchain
}

Write-Step "Copying launchers, examples, and documentation"
$payloadFiles = @(
    "Initialize-PortableLean4.ps1",
    "Enter-PortableLean4.ps1",
    "Open-PortableLean4-VSCode.ps1",
    "run.cmd",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "OFFLINE-GUARANTEE.md",
    "REPRODUCING.md"
)
foreach ($file in $payloadFiles) {
    Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination $payload
}
Copy-Item -LiteralPath (Join-Path $repoRoot "examples") -Destination $payload -Recurse
[IO.File]::WriteAllText((Join-Path $payload "VERSION.txt"), "$($versions.Lean.Version)`n", [Text.UTF8Encoding]::new($false))

Write-Step "Downloading pinned VS Code extensions"
$extensionManifestSource = Join-Path $repoRoot "vscode-extensions\manifest.json"
$extensionManifest = Get-Content -LiteralPath $extensionManifestSource -Raw | ConvertFrom-Json
$payloadExtensions = Join-Path $payload "vscode-extensions"
New-Item -ItemType Directory -Path $payloadExtensions -Force | Out-Null
Copy-Item -LiteralPath $extensionManifestSource -Destination (Join-Path $payloadExtensions "extensions.json")
foreach ($extension in $extensionManifest.extensions) {
    $cachedVsix = Join-Path $CacheDirectory $extension.file
    Receive-VerifiedFile -Uri $extension.downloadUrl -Destination $cachedVsix -Sha256 $extension.sha256
    Copy-Item -LiteralPath $cachedVsix -Destination (Join-Path $payloadExtensions $extension.file)
}

$repositoryCommit = if ($env:GITHUB_SHA) {
    $env:GITHUB_SHA
} else {
    $commit = (& git -C $repoRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0) { $commit.Trim() } else { "working-tree" }
}
$components = @(
    [ordered]@{
        name = "Lean 4"
        version = $versions.Lean.Version
        source = $versions.Lean.Url
        sha256 = $versions.Lean.Sha256
        license = $versions.Lean.License
    },
    [ordered]@{
        name = "elan"
        version = $versions.Elan.Version
        source = $versions.Elan.Url
        sha256 = $versions.Elan.Sha256
        license = $versions.Elan.License
    }
) + @($extensionManifest.extensions | ForEach-Object {
    [ordered]@{
        name = "VS Code extension $($_.id)"
        version = $_.version
        source = $_.upstream
        hostedInput = $_.downloadUrl
        sha256 = $_.sha256
        license = $_.license
    }
})
$manifest = [ordered]@{
    schema = "https://one-click-run.github.io/source-manifest/v1"
    project = "one-click-run/portable-lean4"
    platform = "windows-x86_64"
    flavor = "core"
    offlineRuntime = $true
    repositoryCommit = $repositoryCommit
    components = $components
}
[IO.File]::WriteAllText(
    (Join-Path $payload "SOURCE-MANIFEST.json"),
    (($manifest | ConvertTo-Json -Depth 8) + "`n"),
    [Text.UTF8Encoding]::new($false)
)

$spdxPackages = @($components | ForEach-Object {
    [ordered]@{
        SPDXID = "SPDXRef-Package-" + ($_.name -replace '[^A-Za-z0-9.-]', '-')
        name = $_.name
        versionInfo = $_.version
        downloadLocation = $_.source
        filesAnalyzed = $false
        licenseConcluded = $_.license
        licenseDeclared = $_.license
        copyrightText = "NOASSERTION"
    }
})
$sbom = [ordered]@{
    spdxVersion = "SPDX-2.3"
    dataLicense = "CC0-1.0"
    SPDXID = "SPDXRef-DOCUMENT"
    name = "portable-lean4-core-$($versions.Lean.Version)-windows-x86_64"
    documentNamespace = "https://github.com/one-click-run/portable-lean4/releases/tag/core/spdx/$($versions.Lean.Version)"
    creationInfo = [ordered]@{
        created = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        creators = @("Tool: one-click-run portable-lean4 build-core.ps1")
    }
    packages = $spdxPackages
}
[IO.File]::WriteAllText(
    (Join-Path $payload "SBOM.spdx.json"),
    (($sbom | ConvertTo-Json -Depth 8) + "`n"),
    [Text.UTF8Encoding]::new($false)
)

Write-Step "Testing the unpacked portable environment"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $payload "Enter-PortableLean4.ps1") -CheckProject
if ($LASTEXITCODE -ne 0) { throw "The unpacked portable environment failed its CLI test." }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $payload "Open-PortableLean4-VSCode.ps1") -Check
if ($LASTEXITCODE -ne 0) { throw "The unpacked portable environment failed its VS Code configuration test." }

$exampleBuild = Join-Path $payload "examples\hello\.lake"
if (Test-Path -LiteralPath $exampleBuild) { Remove-Item -LiteralPath $exampleBuild -Recurse -Force }

Write-Step "Creating the release archive"
$assetName = "portable-lean4-core-$($versions.Lean.Version)-windows-x86_64.zip"
$archive = Join-Path $OutputDirectory $assetName
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
$sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
if (-not $sevenZip) { $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue }
if ($sevenZip) {
    Push-Location $payload
    try {
        & $sevenZip.Source a -tzip -mx=5 $archive ".\*"
        if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to create the release archive." }
    } finally {
        Pop-Location
    }
} else {
    Compress-Archive -Path (Join-Path $payload "*") -DestinationPath $archive -CompressionLevel Optimal
}

$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$archive.sha256", "$hash  $assetName`n", [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $payload "SOURCE-MANIFEST.json") -Destination (Join-Path $OutputDirectory "$assetName.source-manifest.json") -Force
Copy-Item -LiteralPath (Join-Path $payload "SBOM.spdx.json") -Destination (Join-Path $OutputDirectory "$assetName.spdx.json") -Force

Write-Host "Created $archive" -ForegroundColor Green
Write-Host "Created $archive.sha256" -ForegroundColor Green

