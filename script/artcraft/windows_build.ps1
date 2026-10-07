param(
    [ValidateSet('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc')]
    [string]$Target,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'

if (-not $Target) {
    $Target = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'x86_64-pc-windows-msvc' }
        'Arm64' { 'aarch64-pc-windows-msvc' }
        default { throw 'Only Windows x64 and ARM64 builds are supported.' }
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Write-Host "Building production Artcraft for $Target..."

Push-Location $repoRoot
try {
    Push-Location './frontend'
    try {
        npm install --verbose
        if ($LASTEXITCODE -ne 0) {
            throw "npm install failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }

    $env:VITE_ENVIRONMENT_TYPE = 'production'
    $env:SQLX_OFFLINE = 'true'
    $env:TAURI_FRONTEND_PATH = '.\frontend'
    $env:TAURI_APP_PATH = '.\crates\desktop\artcraft'
    if ($env:RUSTFLAGS -notmatch 'target-feature=\S*\+crt-static') {
        $env:RUSTFLAGS = "$env:RUSTFLAGS -C target-feature=+crt-static".Trim()
    }

    $buildArgs = @('tauri', 'build', '--config', '.\crates\desktop\artcraft\tauri.conf.json', '--target', $Target)
    if ($Target -eq 'aarch64-pc-windows-msvc') {
        $buildArgs += @('--bundles', 'nsis')
    }
    $buildArgs += @('--', '--locked')
    & cargo @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Artcraft build failed with exit code $LASTEXITCODE."
    }

    $metadata = & cargo metadata --no-deps --format-version 1 --locked
    if ($LASTEXITCODE -ne 0) {
        throw "cargo metadata failed with exit code $LASTEXITCODE."
    }
    $targetDirectory = ($metadata | ConvertFrom-Json).target_directory
    $releaseDirectory = Join-Path $targetDirectory "$Target/release"
    $installerDirectory = Join-Path $releaseDirectory 'bundle/nsis'

    Write-Host 'Production Build Done!' -ForegroundColor Green
    Write-Host "Application: $(Join-Path $releaseDirectory 'artcraft.exe')"
    Write-Host "Installers: $installerDirectory"
    if (-not $NoOpen) {
        Start-Process 'explorer.exe' -ArgumentList "`"$installerDirectory`""
    }
} finally {
    Pop-Location
}
