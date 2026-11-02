Set-StrictMode -Version Latest

function Initialize-PortableLean4Environment {
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [switch]$IsolateUserProfile
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $portableHome = Join-Path $resolvedRoot "data\home"
    $elanHome = Join-Path $portableHome ".elan"
    $elanBin = Join-Path $elanHome "bin"
    $toolchainName = "leanprover/lean4:v4.35.0"
    $toolchainDir = Join-Path $elanHome "toolchains\leanprover--lean4---v4.35.0"

    foreach ($directory in @(
        $portableHome,
        (Join-Path $resolvedRoot "data\xdg-cache"),
        (Join-Path $resolvedRoot "data\xdg-config"),
        (Join-Path $resolvedRoot "data\xdg-data"),
        (Join-Path $resolvedRoot "data\xdg-state")
    )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath (Join-Path $elanBin "elan.exe") -PathType Leaf)) {
        throw "Bundled elan is missing: $elanBin"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $toolchainDir "bin\lean.exe") -PathType Leaf)) {
        throw "Bundled Lean toolchain is missing: $toolchainDir"
    }

    $env:ELAN_HOME = $elanHome
    $env:ELAN_TOOLCHAIN = $toolchainName
    $env:HOME = $portableHome
    $env:XDG_CACHE_HOME = Join-Path $resolvedRoot "data\xdg-cache"
    $env:XDG_CONFIG_HOME = Join-Path $resolvedRoot "data\xdg-config"
    $env:XDG_DATA_HOME = Join-Path $resolvedRoot "data\xdg-data"
    $env:XDG_STATE_HOME = Join-Path $resolvedRoot "data\xdg-state"
    $env:ONE_CLICK_RUN_OFFLINE_RUNTIME = "1"

    # The Lean extension prepends %USERPROFILE%\.elan\bin during activation.
    # Point USERPROFILE at the bundle only for the VS Code process so that it
    # cannot discover or modify the user's real elan installation.
    if ($IsolateUserProfile) {
        $env:USERPROFILE = $portableHome
        $env:HOMEDRIVE = [IO.Path]::GetPathRoot($portableHome).TrimEnd('\')
        $env:HOMEPATH = $portableHome.Substring($env:HOMEDRIVE.Length)
    }

    $systemPaths = @(
        $elanBin,
        (Join-Path $toolchainDir "bin"),
        (Join-Path $env:SystemRoot "System32"),
        $env:SystemRoot,
        (Join-Path $env:SystemRoot "System32\Wbem")
    )
    $env:PATH = ($systemPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) -join ';'

    [pscustomobject]@{
        Root = $resolvedRoot
        PortableHome = $portableHome
        ElanHome = $elanHome
        ElanBin = $elanBin
        Toolchain = $toolchainName
        ToolchainDirectory = $toolchainDir
    }
}

