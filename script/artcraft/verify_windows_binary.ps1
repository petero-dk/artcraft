param(
  [Parameter(Mandatory)]
  [string]$BinaryPath,
  [Parameter(Mandatory)]
  [ValidateSet('x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc')]
  [string]$Target,
  [switch]$AllowDll
)

$ErrorActionPreference = 'Stop'
$expectedMachine = if ($Target -eq 'aarch64-pc-windows-msvc') {
  [System.Reflection.PortableExecutable.Machine]::Arm64
} else {
  [System.Reflection.PortableExecutable.Machine]::Amd64
}

$stream = [System.IO.File]::OpenRead((Resolve-Path $BinaryPath).Path)
try {
  $reader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
  try {
    $headers = $reader.PEHeaders
    if ($null -eq $headers.PEHeader) {
      throw "Not a PE executable: $BinaryPath"
    }
    if ($headers.CoffHeader.Machine -ne $expectedMachine) {
      throw "Wrong architecture for ${BinaryPath}: expected $expectedMachine, found $($headers.CoffHeader.Machine)."
    }
    if (-not $AllowDll -and ($headers.CoffHeader.Characteristics -band [System.Reflection.PortableExecutable.Characteristics]::Dll)) {
      throw "Expected an application executable, not a DLL: $BinaryPath"
    }
    Write-Host "Verified $expectedMachine PE: $BinaryPath"
  } finally {
    $reader.Dispose()
  }
} finally {
  $stream.Dispose()
}