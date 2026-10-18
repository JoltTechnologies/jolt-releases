[CmdletBinding()]
param([string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Jolt\bin'), [switch]$Purge)
$ErrorActionPreference = 'Stop'
function Get-JoltSHA256([string]$Path) {
 $stream = [IO.File]::OpenRead($Path)
 $sha = [Security.Cryptography.SHA256]::Create()
 try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
 finally { $sha.Dispose(); $stream.Dispose() }
}

if ($env:OS -ne 'Windows_NT') { throw 'Use the Bash uninstaller on Linux/macOS.' }
if (![IO.Path]::IsPathRooted($InstallDir)) { throw 'Installation directory must be absolute.' }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$Target = Join-Path $InstallDir 'jolt.exe'; $Receipt = Join-Path $InstallDir '.jolt-install.json'
if (!(Test-Path -LiteralPath $InstallDir)) { Write-Host 'Jolt is not installed here.'; return }
foreach ($file in @($InstallDir,$Target,$Receipt)) { if (!(Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'No ordinary managed installation; nothing was removed.' } }
$record = Get-Content -LiteralPath $Receipt -Raw | ConvertFrom-Json
if ($record.schema -ne 1 -or $record.binary -ne 'jolt.exe' -or (Get-JoltSHA256 $Target) -ne $record.sha256) { throw 'Managed binary changed; inspect it before removing manually.' }
$Lock = Join-Path $InstallDir '.jolt-update.lock'; $lockFile = [IO.File]::Open($Lock,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {
 # Windows refuses deletion if a CLI process still maps the binary. Leave the
 # receipt intact on failure and tell the user to close Jolt processes first.
 Remove-Item -LiteralPath $Target -Force
 Remove-Item -LiteralPath $Receipt -Force
 foreach ($prefix in @('.jolt-previous-','.jolt-running-','.jolt-update-','.jolt-receipt-')) { Get-ChildItem -LiteralPath $InstallDir -Filter "$prefix*" -File -Force | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force } }
 if ($record.ownedPathEntry) {
  $UserPath = [Environment]::GetEnvironmentVariable('Path','User')
  $remaining = @($UserPath -split ';' | Where-Object { $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\') }) -join ';'
  [Environment]::SetEnvironmentVariable('Path',$remaining,'User')
 }
 $env:PATH = @($env:PATH -split ';' | Where-Object { $_.TrimEnd('\') -ine $InstallDir.TrimEnd('\') }) -join ';'
 if ($Purge) { Remove-Item -LiteralPath (Join-Path $env:APPDATA 'jolt') -Recurse -Force -ErrorAction SilentlyContinue }
 Write-Host 'Jolt uninstalled. Credentials are retained unless -Purge was selected. Revoke machine access in JoltCode device settings when retiring a machine.'
} catch { throw "Uninstallation stopped: close all Jolt processes and retry. $($_.Exception.Message)" }
finally { $lockFile.Dispose(); Remove-Item -LiteralPath $Lock -Force }
