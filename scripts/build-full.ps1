param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "..\dist-full"),
    [string]$CacheDirectory = (Join-Path $PSScriptRoot "..\.cache")
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Copy-OverlayFile([string]$RelativePath, [string]$SourceRoot, [string]$DestinationRoot) {
    $source = Join-Path $SourceRoot $RelativePath
    $destination = Join-Path $DestinationRoot $RelativePath
    $parent = Split-Path -Parent $destination
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}

function Convert-ManifestToLocalPackages([string]$ManifestPath, [string]$PackagesRoot, [string]$DirectoryPrefix) {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    foreach ($entry in @($manifest.packages)) {
        $packageDirectory = Join-Path $PackagesRoot $entry.name
        if (-not (Test-Path -LiteralPath $packageDirectory -PathType Container)) {
            throw "Manifest $ManifestPath refers to a package that was not materialized: $($entry.name)"
        }
        $entry.type = "path"
        foreach ($property in @("url", "rev", "inputRev", "subDir")) {
            $entry.PSObject.Properties.Remove($property)
        }
        $entry | Add-Member -NotePropertyName dir -NotePropertyValue "$DirectoryPrefix/$($entry.name)" -Force
        $entry | Add-Member -NotePropertyName copy -NotePropertyValue $false -Force
    }
    [IO.File]::WriteAllText(
        $ManifestPath,
        (($manifest | ConvertTo-Json -Depth 20) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$versions = Import-PowerShellDataFile (Join-Path $PSScriptRoot "versions.psd1")
$powerShellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
if ($versions.Mathlib.Version -ne $versions.Lean.Version) {
    throw "Lean and Mathlib release versions must match."
}

$buildRoot = Join-Path $repoRoot ".full-build"
$combined = Join-Path $buildRoot "combined"
$overlay = Join-Path $buildRoot "overlay"
$coreDist = Join-Path $buildRoot "core-dist"
$resolvedBuildRoot = [IO.Path]::GetFullPath($buildRoot)
if (-not $resolvedBuildRoot.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean a build directory outside the repository: $resolvedBuildRoot"
}
if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
New-Item -ItemType Directory -Path $combined, $overlay, $coreDist, $OutputDirectory, $CacheDirectory -Force | Out-Null

Write-Step "Building the pinned Core prerequisite"
& (Join-Path $PSScriptRoot "build-core.ps1") -OutputDirectory $coreDist -CacheDirectory $CacheDirectory
if ($LASTEXITCODE -ne 0) { throw "Core build failed." }
$coreArchive = Get-ChildItem -LiteralPath $coreDist -Filter "portable-lean4-core-*-windows-x86_64.zip" -File | Select-Object -First 1
if (-not $coreArchive) { throw "The Core build did not produce an archive." }

# build-core.ps1 leaves its unpacked payload behind. It is no longer needed and
# consumes several gigabytes on hosted runners.
$coreBuildRoot = Join-Path $repoRoot ".build"
if (Test-Path -LiteralPath $coreBuildRoot) { Remove-Item -LiteralPath $coreBuildRoot -Recurse -Force }

Write-Step "Expanding Core and resolving the pinned Mathlib dependency graph"
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($coreArchive.FullName, $combined)
$mathlibProject = Join-Path $combined "examples\mathlib"
if (-not (Test-Path -LiteralPath (Join-Path $mathlibProject "lakefile.toml") -PathType Leaf)) {
    New-Item -ItemType Directory -Path $mathlibProject -Force | Out-Null
    Copy-Item -Path (Join-Path $repoRoot "examples\mathlib\*") -Destination $mathlibProject -Recurse -Force
}

$savedPath = $env:PATH
$savedGitConfigCount = $env:GIT_CONFIG_COUNT
$savedGitConfigKey = $env:GIT_CONFIG_KEY_0
$savedGitConfigValue = $env:GIT_CONFIG_VALUE_0
$savedGitPrompt = $env:GIT_TERMINAL_PROMPT
. (Join-Path $combined "Initialize-PortableLean4.ps1")
$portable = Initialize-PortableLean4Environment -Root $combined
$env:PATH = "$($env:PATH);$savedPath"
$env:GIT_CONFIG_COUNT = "1"
$env:GIT_CONFIG_KEY_0 = "core.longpaths"
$env:GIT_CONFIG_VALUE_0 = "true"
$env:GIT_TERMINAL_PROMPT = "0"

try {
    Push-Location $mathlibProject
    try {
        & lake update
        if ($LASTEXITCODE -ne 0) { throw "lake update failed while resolving Mathlib." }

        $mathlibSource = Join-Path $mathlibProject ".lake\packages\mathlib"
        $actualCommit = (& git -C $mathlibSource rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $versions.Mathlib.Commit) {
            throw "Unexpected Mathlib commit: $actualCommit"
        }

        Write-Step "Downloading the official Mathlib build cache"
        & lake exe cache get
        if ($LASTEXITCODE -ne 0) { throw "Mathlib cache download failed." }

        & lake env lean Main.lean
        if ($LASTEXITCODE -ne 0) { throw "Mathlib example typecheck failed." }
    } finally {
        Pop-Location
    }
} finally {
    $env:PATH = $savedPath
    $env:GIT_CONFIG_COUNT = $savedGitConfigCount
    $env:GIT_CONFIG_KEY_0 = $savedGitConfigKey
    $env:GIT_CONFIG_VALUE_0 = $savedGitConfigValue
    $env:GIT_TERMINAL_PROMPT = $savedGitPrompt
}

$rootManifestPath = Join-Path $mathlibProject "lake-manifest.json"
$resolvedManifest = Get-Content -LiteralPath $rootManifestPath -Raw | ConvertFrom-Json
$mathlibEntry = @($resolvedManifest.packages | Where-Object { $_.name -eq "mathlib" })
if ($mathlibEntry.Count -ne 1 -or $mathlibEntry[0].rev -ne $versions.Mathlib.Commit) {
    throw "The generated Lake manifest does not pin the expected Mathlib commit."
}

$packagesDirectory = Join-Path $mathlibProject ".lake\packages"
Write-Step "Converting the resolved graph to relocatable local path dependencies"
Convert-ManifestToLocalPackages $rootManifestPath $packagesDirectory ".lake/packages"
Get-ChildItem -LiteralPath $packagesDirectory -Directory | ForEach-Object {
    Convert-ManifestToLocalPackages (Join-Path $_.FullName "lake-manifest.json") $packagesDirectory ".."
}
$offlineLakefile = @"
name = "portable_mathlib"
version = "0.1.0"

[[require]]
name = "mathlib"
path = ".lake/packages/mathlib"
"@
[IO.File]::WriteAllText((Join-Path $mathlibProject "lakefile.toml"), $offlineLakefile, [Text.UTF8Encoding]::new($false))

Write-Step "Removing repository metadata and testing without network access"
Get-ChildItem -LiteralPath $packagesDirectory -Directory | ForEach-Object {
    $gitMetadata = Join-Path $_.FullName ".git"
    if (Test-Path -LiteralPath $gitMetadata) { Remove-Item -LiteralPath $gitMetadata -Recurse -Force }
}
$savedPath = $env:PATH
$savedHttpProxy = $env:HTTP_PROXY
$savedHttpsProxy = $env:HTTPS_PROXY
try {
    . (Join-Path $combined "Initialize-PortableLean4.ps1")
    [void](Initialize-PortableLean4Environment -Root $combined)
    $env:HTTP_PROXY = "http://127.0.0.1:9"
    $env:HTTPS_PROXY = "http://127.0.0.1:9"
    & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $combined "Enter-PortableLean4.ps1") -CheckMathlib
    if ($LASTEXITCODE -ne 0) { throw "The combined environment failed its offline Mathlib test." }
} finally {
    $env:PATH = $savedPath
    $env:HTTP_PROXY = $savedHttpProxy
    $env:HTTPS_PROXY = $savedHttpsProxy
}
$repositoryCommit = if ($env:GITHUB_SHA) {
    $env:GITHUB_SHA
} else {
    $commit = (& git -C $repoRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0) { $commit.Trim() } else { "working-tree" }
}
$components = @(
    [ordered]@{
        name = "Mathlib"
        version = $versions.Mathlib.Version
        source = $versions.Mathlib.Url
        revision = $versions.Mathlib.Commit
        license = $versions.Mathlib.License
    }
) + @($resolvedManifest.packages | Where-Object { $_.name -ne "mathlib" } | ForEach-Object {
    [ordered]@{
        name = $_.name
        version = $_.rev
        source = $_.url
        revision = $_.rev
        license = "NOASSERTION"
    }
})
$manifest = [ordered]@{
    schema = "https://one-click-run.github.io/source-manifest/v1"
    project = "one-click-run/portable-lean4"
    platform = "windows-x86_64"
    flavor = "mathlib-overlay"
    offlineRuntime = $true
    leanVersion = $versions.Lean.Version
    repositoryCommit = $repositoryCommit
    components = $components
}
$manifestPath = Join-Path $combined "MATHLIB-SOURCE-MANIFEST.json"
[IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))

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
    name = "portable-lean4-mathlib-$($versions.Mathlib.Version)-windows-x86_64"
    documentNamespace = "https://github.com/one-click-run/portable-lean4/releases/tag/full/spdx/$($versions.Mathlib.Version)"
    creationInfo = [ordered]@{
        created = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        creators = @("Tool: one-click-run portable-lean4 build-full.ps1")
    }
    packages = $spdxPackages
}
$sbomPath = Join-Path $combined "MATHLIB-SBOM.spdx.json"
[IO.File]::WriteAllText($sbomPath, (($sbom | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $combined "MATHLIB-VERSION.txt"), "$($versions.Mathlib.Version)`n$($versions.Mathlib.Commit)`n", [Text.UTF8Encoding]::new($false))

Write-Step "Assembling the Mathlib overlay"
foreach ($relativePath in @(
    "examples\mathlib",
    "Enter-PortableLean4.ps1",
    "Open-PortableLean4-VSCode.ps1",
    "OFFLINE-GUARANTEE.md",
    "REPRODUCING.md",
    "THIRD_PARTY_NOTICES.md",
    "MATHLIB-SOURCE-MANIFEST.json",
    "MATHLIB-SBOM.spdx.json",
    "MATHLIB-VERSION.txt"
)) {
    Copy-OverlayFile -RelativePath $relativePath -SourceRoot $combined -DestinationRoot $overlay
}

$assetName = "portable-lean4-mathlib-$($versions.Mathlib.Version)-windows-x86_64.zip"
$archive = Join-Path $OutputDirectory $assetName
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
$sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
if (-not $sevenZip) { $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue }
if ($sevenZip) {
    Push-Location $overlay
    try {
        & $sevenZip.Source a -tzip -mx=5 $archive ".\*"
        if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to create the Mathlib overlay." }
    } finally {
        Pop-Location
    }
} else {
    Compress-Archive -Path (Join-Path $overlay "*") -DestinationPath $archive -CompressionLevel Optimal
}

$archiveInfo = Get-Item -LiteralPath $archive
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$archive.sha256", "$hash  $assetName`n", [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $OutputDirectory "$assetName.source-manifest.json") -Force
Copy-Item -LiteralPath $sbomPath -Destination (Join-Path $OutputDirectory "$assetName.spdx.json") -Force

if ($archiveInfo.Length -ge 1500000000) {
    Write-Step "Splitting the overlay into GitHub-safe release assets"
    $partSize = 1500000000L
    $buffer = New-Object byte[] (8MB)
    $input = [IO.File]::OpenRead($archive)
    try {
        $partNumber = 1
        while ($input.Position -lt $input.Length) {
            $partPath = "{0}.part{1:D3}" -f $archive, $partNumber
            $output = [IO.File]::Create($partPath)
            try {
                $remaining = [Math]::Min($partSize, $input.Length - $input.Position)
                while ($remaining -gt 0) {
                    $readLength = [int][Math]::Min([long]$buffer.Length, $remaining)
                    $count = $input.Read($buffer, 0, $readLength)
                    if ($count -le 0) { throw "Unexpected end of Mathlib archive while creating release parts." }
                    $output.Write($buffer, 0, $count)
                    $remaining -= $count
                }
            } finally {
                $output.Dispose()
            }
            $partName = Split-Path -Leaf $partPath
            $partHash = (Get-FileHash -LiteralPath $partPath -Algorithm SHA256).Hash.ToLowerInvariant()
            [IO.File]::WriteAllText("$partPath.sha256", "$partHash  $partName`n", [Text.UTF8Encoding]::new($false))
            $partNumber++
        }
    } finally {
        $input.Dispose()
    }
    Remove-Item -LiteralPath $archive -Force
    Write-Host "Created $($partNumber - 1) verified parts for $assetName ($($archiveInfo.Length) bytes total)" -ForegroundColor Green
} else {
    Write-Host "Created $archive ($($archiveInfo.Length) bytes)" -ForegroundColor Green
}
Write-Host "Created $archive.sha256" -ForegroundColor Green
