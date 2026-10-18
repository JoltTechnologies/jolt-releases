# Download this versioned installer over HTTPS and inspect it before running.
[CmdletBinding()]
param([string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Jolt\bin'), [switch]$NoPath)
$ErrorActionPreference = 'Stop'
function Get-JoltSHA256([string]$Path) {
 $stream = [IO.File]::OpenRead($Path)
 $sha = [Security.Cryptography.SHA256]::Create()
 try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
 finally { $sha.Dispose(); $stream.Dispose() }
}

$Version = '0.1.0-beta.6'
$Repository = 'JoltTechnologies/jolt-releases'
$PublicKey = 's8jxgpAzaPAgu0EVjzyokZCtDmjAwQ4WoFubIPXj4ks=' # Pinned trust anchor; never downloaded.
$Pins = @{ amd64 = '6dc2b3eb038a403ea65c1855c1d7297713463fdfd366d2af6ccaa51c4dd6bafc'; arm64 = 'cc0a57a131ccb035dd9e422ad266c78659891eddb4e8fac7066b4716602d9b9e' }
if ($env:OS -ne 'Windows_NT') { throw 'Use the Bash installer on Linux/macOS.' }
$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
switch ($architecture) { 'x64' { $Arch = 'amd64' }; 'arm64' { $Arch = 'arm64' }; default { throw 'Unsupported Windows CPU architecture.' } }
if (![IO.Path]::IsPathRooted($InstallDir)) { throw 'Installation directory must be absolute.' }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
if ($InstallDir.IndexOfAny([char[]]";`r`n") -ge 0) { throw 'Installation directory cannot contain PATH separators or newlines.' }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
if ((Get-Item -LiteralPath $InstallDir).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing a symlink/junction installation directory.' }
$Target = Join-Path $InstallDir 'jolt.exe'
$Receipt = Join-Path $InstallDir '.jolt-install.json'
$OwnedPathEntry = $false
if (Test-Path -LiteralPath $Target) {
 if (!(Test-Path -LiteralPath $Receipt)) { throw 'Refusing to overwrite an unmanaged jolt.exe; choose another -InstallDir.' }
 foreach ($file in @($Target, $Receipt)) { if ((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing a reparse-point installation.' } }
 $PreviousReceipt = Get-Content -LiteralPath $Receipt -Raw | ConvertFrom-Json
 if ($PreviousReceipt.schema -ne 1 -or $PreviousReceipt.binary -ne 'jolt.exe' -or (Get-JoltSHA256 $Target) -ne $PreviousReceipt.sha256) { throw 'Existing managed binary changed; refusing replacement.' }
 $OwnedPathEntry = [bool]$PreviousReceipt.ownedPathEntry
}
function Get-VerifiedTransportFile([string]$Url, [string]$Destination) {
 Add-Type -AssemblyName System.Net.Http
 [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
 $handler = New-Object Net.Http.HttpClientHandler
 $handler.AllowAutoRedirect = $false
 $client = [Net.Http.HttpClient]::new($handler)
 $client.Timeout = [TimeSpan]::FromSeconds(120)
 try {
  $uri = [Uri]$Url
  for ($redirect = 0; $redirect -le 3; $redirect++) {
   if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or @('github.com','release-assets.githubusercontent.com','objects.githubusercontent.com') -notcontains $uri.Host) { throw 'Untrusted download URL/redirect.' }
   $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
   if ([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) {
    $next = [Uri]::new($uri, $response.Headers.Location); $response.Dispose(); $uri = $next; continue
   }
   $response.EnsureSuccessStatusCode() | Out-Null
   if ($response.Content.Headers.ContentLength -gt 104857600) { throw 'Artifact exceeds the maximum size.' }
   $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
   $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
   try { $buffer = New-Object byte[] 8192; $total = 0; while (($read = $source.Read($buffer,0,$buffer.Length)) -gt 0) { $total += $read; if ($total -gt 104857600) { throw 'Artifact exceeds the maximum size.' }; $output.Write($buffer,0,$read) }; $output.Flush($true) }
   finally { $output.Dispose(); $source.Dispose(); $response.Dispose() }
   return
  }
  throw 'Too many download redirects.'
 } finally { $client.Dispose(); $handler.Dispose() }
}
$Lock = Join-Path $InstallDir '.jolt-update.lock'
$LockFile = [IO.File]::Open($Lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$Stage = Join-Path $InstallDir ('.jolt-update-' + [Guid]::NewGuid().ToString('N') + '.exe')
$ReceiptStage = Join-Path $InstallDir ('.jolt-receipt-' + [Guid]::NewGuid().ToString('N'))
$ManifestStage = Join-Path $InstallDir ('.jolt-manifest-' + [Guid]::NewGuid().ToString('N'))
$ReceiptBackup = Join-Path $InstallDir ('.jolt-receipt-backup-' + [Guid]::NewGuid().ToString('N'))
$Backup = $null
try {
 Get-VerifiedTransportFile "https://github.com/$Repository/releases/download/v$Version/jolt-windows-$Arch.exe" $Stage
 if ((Get-JoltSHA256 $Stage) -ne $Pins[$Arch]) { throw 'Artifact checksum mismatch. Nothing was installed.' }
 Get-VerifiedTransportFile "https://github.com/$Repository/releases/download/v$Version/manifest.json" $ManifestStage
 & $Stage verify-release --manifest $ManifestStage --expected-key $PublicKey
 if ($LASTEXITCODE -ne 0) { throw 'Release signature verification failed. Nothing was installed.' }
 $versionOutput = & $Stage version
 if ($LASTEXITCODE -ne 0 -or "$versionOutput" -ne "jolt version $Version") { throw 'Wrong executable/version. Nothing was installed.' }
 [string]$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
 $HasPath = @($UserPath -split ';' | Where-Object { $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\') }).Count -gt 0
 if (!$NoPath -and !$HasPath) { $OwnedPathEntry = $true }
 $record = @{ schema = 1; binary = 'jolt.exe'; version = $Version; sha256 = $Pins[$Arch]; ownedPathEntry = $OwnedPathEntry } | ConvertTo-Json
 [IO.File]::WriteAllText($ReceiptStage, $record, [Text.UTF8Encoding]::new($false))
 if (Test-Path -LiteralPath $Target) { $Backup = Join-Path $InstallDir ('.jolt-previous-' + [Guid]::NewGuid().ToString('N')); [IO.File]::Move($Target, $Backup) }
 try { [IO.File]::Move($Stage,$Target); if (Test-Path -LiteralPath $Receipt) { [IO.File]::Replace($ReceiptStage,$Receipt,$ReceiptBackup) } else { [IO.File]::Move($ReceiptStage,$Receipt) } }
 catch { if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force }; if ($Backup) { [IO.File]::Move($Backup,$Target) }; throw }
 if (!$NoPath -and !$HasPath) { [Environment]::SetEnvironmentVariable('Path', (($UserPath.TrimEnd(';') + ';' + $InstallDir).TrimStart(';')), 'User') }
 if (!$NoPath -and !(@($env:PATH -split ';' | Where-Object { $_.TrimEnd('\') -ieq $InstallDir.TrimEnd('\') }).Count)) { $env:PATH = "$InstallDir;$env:PATH" }
 Write-Host "JoltCLI installed successfully!`nVersion: v$Version`nExecutable: $Target"
 Write-Host "`nNext steps:`n1. Run: jolt --version`n2. Enter your project directory and run: jolt connect`n3. Sign in and approve your machine.`n4. Open JoltCode Desktop or https://joltcode.pages.dev`n5. Select your connected workspace."
 Write-Host 'Other terminals may need reopening to pick up the user PATH change.'
 if ($NoPath) { Write-Host "Run directly: & '$Target' connect" }
} finally {
 $LockFile.Dispose()
 foreach ($file in @($Stage,$ReceiptStage,$ReceiptBackup,$ManifestStage,$Lock)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
}
