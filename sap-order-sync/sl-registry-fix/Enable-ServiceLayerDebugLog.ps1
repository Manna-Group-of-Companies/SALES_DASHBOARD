<#
.SYNOPSIS
  Raises the Service Layer's Apache log level to debug so the b1s module records
  why /Login fails, then restarts the nodes. Run Restore mode afterwards to undo.

  Only changes logging. Does not touch B1LicenseService, so B1 client users are
  unaffected.

  MUST be run elevated.

.EXAMPLE
  .\Enable-ServiceLayerDebugLog.ps1
  .\Enable-ServiceLayerDebugLog.ps1 -Restore
#>
[CmdletBinding()]
param([switch] $Restore)

$ErrorActionPreference = 'Stop'

$principal = New-Object System.Security.Principal.WindowsPrincipal(
    [System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Must be run as Administrator." -ForegroundColor Red
    exit 1
}

$conf   = 'C:\Program Files\SAP\SAP Business One ServerTools\ServiceLayer\Conf\httpd-b1s-lb-member-common.conf'
$backup = "$conf.bak-debuglog"

if ($Restore) {
    if (-not (Test-Path $backup)) { Write-Host "No backup found at $backup" -ForegroundColor Red; exit 1 }
    Copy-Item $backup $conf -Force
    Write-Host "Restored original conf." -ForegroundColor Green
} else {
    if (-not (Test-Path $backup)) { Copy-Item $conf $backup -Force; Write-Host "Backed up -> $backup" }
    $text = Get-Content $conf -Raw
    if ($text -notmatch '(?m)^\s*LogLevel\s') { Write-Host "No LogLevel directive found; aborting." -ForegroundColor Red; exit 1 }
    ($text -replace '(?m)^\s*LogLevel\s+\w+', 'LogLevel debug') | Set-Content $conf -Encoding ASCII
    Write-Host "LogLevel set to debug." -ForegroundColor Green
}

Write-Host "`nRestarting Service Layer nodes..." -ForegroundColor Cyan
foreach ($n in @(1..10 | ForEach-Object { 'b1s{0:D5}' -f (50000 + $_) }) + 'b1s50000') {
    try { Restart-Service -Name $n -Force -ErrorAction Stop; Write-Host "  $n restarted" }
    catch { Write-Host "  $n FAILED: $($_.Exception.Message)" -ForegroundColor Red }
}

if ($Restore) { Write-Host "`nDone. Logging is back to normal." -ForegroundColor Green }
else { Write-Host "`nDone. Tell Claude - it will trigger a login and read the debug output." -ForegroundColor Green }
