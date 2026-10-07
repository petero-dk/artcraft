$ErrorActionPreference = 'Stop'
$global:artcraftBuildTestState = @{}
function Invoke-BuildTests {
  $buildScript = Join-Path $PSScriptRoot 'windows_build.ps1'
  $originalLocation = Get-Location
  $savedEnvironment = @{}
  foreach ($name in @('RUSTFLAGS', 'SQLX_OFFLINE', 'VITE_ENVIRONMENT_TYPE', 'TAURI_FRONTEND_PATH', 'TAURI_APP_PATH')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
  }

  try {
    foreach ($target in @('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc')) {
      Reset-Mocks
      $env:RUSTFLAGS = '-C debuginfo=1'
      & $buildScript -Target $target
      $buildArgs = $global:artcraftBuildTestState.cargoCalls[0]
      Assert-True ($buildArgs -contains $target) "Missing target $target"
      Assert-True ($buildArgs[-1] -eq '--locked') 'Build must use the lockfile'
      Assert-True (($buildArgs -contains 'nsis') -eq ($target -eq 'aarch64-pc-windows-msvc')) 'ARM64 must use NSIS without changing x64 bundles'
      Assert-True ($env:RUSTFLAGS -eq '-C debuginfo=1 -C target-feature=+crt-static') 'Existing flags must be preserved'
      Assert-True ($env:SQLX_OFFLINE -eq 'true') 'Build must use SQLx offline mode'
      Assert-True ($global:artcraftBuildTestState.explorerArguments -eq "`"$(Join-Path $global:artcraftBuildTestState.targetDirectory "$target/release/bundle/nsis")`"") 'Explorer must use Cargo target_directory and target'
      Assert-True ((Get-Location).Path -eq $originalLocation.Path) 'Working directory must be restored'
    }

    Reset-Mocks
    $env:RUSTFLAGS = '-C target-feature=+crt-static'
    & $buildScript -NoOpen
    $nativeTarget = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
      'X64' { 'x86_64-pc-windows-msvc' }
      'Arm64' { 'aarch64-pc-windows-msvc' }
    }
    Assert-True ($global:artcraftBuildTestState.cargoCalls[0] -contains $nativeTarget) 'Default must use OS architecture'
    Assert-True ($env:RUSTFLAGS -eq '-C target-feature=+crt-static') 'Static CRT flag must not be duplicated'
    Assert-True ($null -eq $global:artcraftBuildTestState.explorerArguments) '-NoOpen must skip Explorer'

    foreach ($failure in @('npm', 'build', 'metadata')) {
      Reset-Mocks
      $global:artcraftBuildTestState.failure = $failure
      $caught = $false
      try {
        & $buildScript -Target aarch64-pc-windows-msvc
      } catch {
        $caught = $_.Exception.Message -match 'failed with exit code 42'
      }
      Assert-True $caught "$failure failure must terminate the build"
      Assert-True ($null -eq $global:artcraftBuildTestState.explorerArguments) 'Failed builds must not open Explorer'
      Assert-True ((Get-Location).Path -eq $originalLocation.Path) 'Failed builds must restore working directory'
      if ($failure -eq 'npm') {
        Assert-True ($global:artcraftBuildTestState.cargoCalls.Count -eq 0) 'npm failure must prevent Rust compilation'
      }
    }

    Reset-Mocks
    $caught = $false
    try {
      & $buildScript -Target invalid-target
    } catch {
      $caught = $true
    }
    Assert-True $caught 'Invalid target must be rejected'
    Assert-True ($global:artcraftBuildTestState.cargoCalls.Count -eq 0) 'Invalid target must not invoke Cargo'
    Write-Host 'Windows build script tests passed.'
  } finally {
    foreach ($name in $savedEnvironment.Keys) {
      [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
  }
}

function Invoke-ArchitectureTests {
  $verifyScript = Join-Path $PSScriptRoot 'verify_windows_binary.ps1'
  $cliScript = Join-Path $PSScriptRoot 'windows_tauri_cli.ps1'
  $originalTargetDirectory = $env:CARGO_TARGET_DIR
  $originalWindowsTarget = $env:ARTCRAFT_WINDOWS_TARGET
  $originalPath = $env:PATH
  $originalCapturePath = $env:ARTCRAFT_CLI_TEST_CAPTURE_PATH
  $fixtureDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
  try {
    $shimDirectory = Join-Path $fixtureDirectory 'mock tools'
    New-Item -ItemType Directory -Path $shimDirectory | Out-Null
    $nodePath = (Get-Command node -ErrorAction Stop).Source
    [System.IO.File]::WriteAllText((Join-Path $shimDirectory 'npx.cmd'), "@echo off`r`n`"$nodePath`" `"%~dp0capture-npx.cjs`" %*`r`n")
    [System.IO.File]::WriteAllText((Join-Path $shimDirectory 'capture-npx.cjs'), "require('node:fs').writeFileSync(process.env.ARTCRAFT_CLI_TEST_CAPTURE_PATH, JSON.stringify(process.argv.slice(2)));")
    $env:PATH = "$shimDirectory;$originalPath"
    $env:ARTCRAFT_CLI_TEST_CAPTURE_PATH = Join-Path $fixtureDirectory 'captured-arguments.json'
    $bytes = [System.IO.File]::ReadAllBytes((Get-Process -Id $PID).Path)
    $reader = [System.Reflection.PortableExecutable.PEReader]::new([System.IO.MemoryStream]::new($bytes))
    try {
      $machineOffset = $reader.PEHeaders.CoffHeaderStartOffset
    } finally {
      $reader.Dispose()
    }
    foreach ($target in @('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc')) {
      $machine = if ($target -eq 'aarch64-pc-windows-msvc') { 0xAA64 } else { 0x8664 }
      $bytes[$machineOffset] = $machine -band 0xFF
      $bytes[$machineOffset + 1] = $machine -shr 8
      $fixture = Join-Path $fixtureDirectory "$target.exe"
      [System.IO.File]::WriteAllBytes($fixture, $bytes)
      & $verifyScript -BinaryPath $fixture -Target $target
      $env:CARGO_TARGET_DIR = $fixtureDirectory
      $env:ARTCRAFT_WINDOWS_TARGET = $target
      $releaseDirectory = Join-Path $fixtureDirectory "$target/release"
      New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
      $application = Join-Path $releaseDirectory 'artcraft.exe'
      Copy-Item $fixture $application
      & $cliScript build --target $target --no-bundle '--' --locked
      $expectedArguments = @('--yes', '--package', '@tauri-apps/cli@2.10.0', 'tauri', 'build', '--target', $target, '--no-bundle', '--', '--locked')
      Assert-True (($global:artcraftBuildTestState.cliArguments | ConvertTo-Json -Compress) -eq ($expectedArguments | ConvertTo-Json -Compress)) 'CLI wrapper must preserve the complete argument list, including the Cargo separator'
      $releaseArguments = @('build', '--target', $target)
      if ($target -eq 'aarch64-pc-windows-msvc') {
        $releaseArguments += @('--bundles', 'nsis')
      }
      $releaseArguments += @('--', '--locked')
      & (Get-Process -Id $PID).Path -NoProfile -File $cliScript @releaseArguments
      Assert-True ($LASTEXITCODE -eq 0) 'Release action invocation must succeed through pwsh -File'
      $capturedArguments = Get-Content $env:ARTCRAFT_CLI_TEST_CAPTURE_PATH | ConvertFrom-Json
      $expectedArguments = @('--yes', '--package', '@tauri-apps/cli@2.10.0', 'tauri') + $releaseArguments
      Assert-True (($capturedArguments | ConvertTo-Json -Compress) -eq ($expectedArguments | ConvertTo-Json -Compress)) 'Release action invocation must preserve every native CLI argument'
      $otherTarget = if ($target -eq 'aarch64-pc-windows-msvc') { 'x86_64-pc-windows-msvc' } else { 'aarch64-pc-windows-msvc' }
      $caught = $false
      try {
        & $verifyScript -BinaryPath $fixture -Target $otherTarget
      } catch {
        $caught = $_.Exception.Message -match 'Wrong architecture'
      }
      Assert-True $caught 'PE machine mismatch must fail'
      $env:ARTCRAFT_WINDOWS_TARGET = $otherTarget
      $otherDirectory = Join-Path $fixtureDirectory "$otherTarget/release"
      New-Item -ItemType Directory -Path $otherDirectory -Force | Out-Null
      Copy-Item $fixture (Join-Path $otherDirectory 'artcraft.exe') -Force
      $caught = $false
      try {
        & $cliScript build --target $otherTarget
      } catch {
        $caught = $_.Exception.Message -match 'Wrong architecture'
      }
      Assert-True $caught 'CLI wrapper must fail before publication on an architecture mismatch'
    }

    $global:artcraftBuildTestState.failure = 'cli'
    $caught = $false
    try {
      & $cliScript build --target aarch64-pc-windows-msvc
    } catch {
      $caught = $_.Exception.Message -match 'Tauri CLI failed with exit code 42'
    }
    Assert-True $caught 'CLI wrapper must propagate build failure'
    $global:artcraftBuildTestState.failure = ''

    $dllFixture = Join-Path $fixtureDirectory 'library.dll'
    $bytes[$machineOffset + 19] = $bytes[$machineOffset + 19] -bor 0x20
    [System.IO.File]::WriteAllBytes($dllFixture, $bytes)
    & $verifyScript -BinaryPath $dllFixture -Target aarch64-pc-windows-msvc -AllowDll
    $caught = $false
    try {
      & $verifyScript -BinaryPath $dllFixture -Target aarch64-pc-windows-msvc
    } catch {
      $caught = $_.Exception.Message -match 'not a DLL'
    }
    Assert-True $caught 'DLL must not pass as an application'

    $malformed = Join-Path $fixtureDirectory 'malformed.exe'
    [System.IO.File]::WriteAllBytes($malformed, [byte[]](1, 2, 3))
    foreach ($path in @($malformed, (Join-Path $fixtureDirectory 'missing.exe'))) {
      $caught = $false
      try {
        & $verifyScript -BinaryPath $path -Target aarch64-pc-windows-msvc
      } catch {
        $caught = $true
      }
      Assert-True $caught 'Missing or malformed PE must fail'
    }
    Write-Host 'Windows PE verification tests passed.'
  } finally {
    $env:CARGO_TARGET_DIR = $originalTargetDirectory
    $env:ARTCRAFT_WINDOWS_TARGET = $originalWindowsTarget
    $env:PATH = $originalPath
    $env:ARTCRAFT_CLI_TEST_CAPTURE_PATH = $originalCapturePath
    Remove-Item $fixtureDirectory -Recurse -Force
  }
}

function Assert-True([bool]$condition, [string]$message) {
  if (-not $condition) { throw $message }
}

function Reset-Mocks {
  $global:artcraftBuildTestState.cargoCalls = [System.Collections.Generic.List[object]]::new()
  $global:artcraftBuildTestState.targetDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'Artcraft test target'
  $global:artcraftBuildTestState.explorerArguments = $null
  $global:artcraftBuildTestState.failure = ''
}

function npm {
  $global:LASTEXITCODE = if ($global:artcraftBuildTestState.failure -eq 'npm') { 42 } else { 0 }
}

function cargo {
  $global:artcraftBuildTestState.cargoCalls.Add(@($args))
  $command = if ($args[0] -eq 'metadata') { 'metadata' } else { 'build' }
  $global:LASTEXITCODE = if ($global:artcraftBuildTestState.failure -eq $command) { 42 } else { 0 }
  if ($command -eq 'metadata') {
    @{ target_directory = $global:artcraftBuildTestState.targetDirectory } | ConvertTo-Json
  }
}

function Start-Process {
  param($FilePath, $ArgumentList)
  Assert-True ($FilePath -eq 'explorer.exe') 'Only Explorer should be started'
  $global:artcraftBuildTestState.explorerArguments = $ArgumentList
}

function npx {
  $global:artcraftBuildTestState.cliArguments = @($args)
  $global:LASTEXITCODE = if ($global:artcraftBuildTestState.failure -eq 'cli') { 42 } else { 0 }
}

Invoke-BuildTests
Invoke-ArchitectureTests