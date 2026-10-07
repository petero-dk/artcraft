$ErrorActionPreference = 'Stop'
$cliArguments = @($args)
& npx --yes --package '@tauri-apps/cli@2.10.0' tauri @cliArguments
if ($LASTEXITCODE -ne 0) {
  throw "Tauri CLI failed with exit code $LASTEXITCODE."
}

if ($cliArguments[0] -eq 'build') {
  $target = $env:ARTCRAFT_WINDOWS_TARGET
  if ($target -notin @('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc')) {
    throw 'ARTCRAFT_WINDOWS_TARGET must specify a supported Windows target.'
  }
  $binary = Join-Path $env:CARGO_TARGET_DIR "$target/release/artcraft.exe"
  & (Join-Path $PSScriptRoot 'verify_windows_binary.ps1') -BinaryPath $binary -Target $target
}