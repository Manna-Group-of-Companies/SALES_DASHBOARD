<#
.SYNOPSIS
  Restores the machine-level SAP configuration the Service Layer's DI core reads
  at Login, then restarts the 11 Service Layer services so they pick it up.

  Values are verbatim from SAP's own template:
    ...\ServiceLayer\Conf\b1-local-machine.xml

  Restarts ONLY b1s50000-b1s50010. Does NOT touch B1LicenseService, so SAP
  Business One client users stay logged in.

  MUST be run elevated (Run as Administrator).
#>
[CmdletBinding()]
param([switch] $SkipRestart)

$ErrorActionPreference = 'Stop'

$principal = New-Object System.Security.Principal.WindowsPrincipal(
    [System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> Run as Administrator, then re-run it."
    exit 1
}

$b1 = 'HKLM:\SOFTWARE\SAP\SAP Manage\SAP Business One'
$lm = 'HKLM:\SOFTWARE\SAP\SAP Manage\LicenseManager'

$settings = @(
    @{ Path = $b1; Name = 'LicenseServer';         Value = 'localhost:40000' }
    @{ Path = $b1; Name = 'LicenseServerProtocol'; Value = 'HTTPS' }
    @{ Path = $b1; Name = 'SLDAddress';            Value = 'https://SERVER:40000' }
    @{ Path = $lm; Name = 'Machine';               Value = 'localhost' }
    @{ Path = $lm; Name = 'Port';                  Value = '40000' }
)

Write-Host "Restoring registry values..." -ForegroundColor Cyan
foreach ($s in $settings) {
    if (-not (Test-Path $s.Path)) { New-Item -Path $s.Path -Force | Out-Null }
    New-ItemProperty -Path $s.Path -Name $s.Name -Value $s.Value -PropertyType String -Force | Out-Null
    Write-Host ("  {0}\{1} = {2}" -f ($s.Path -replace '.*\\',''), $s.Name, $s.Value)
}

Write-Host "`nVerifying..." -ForegroundColor Cyan
$ok = $true
foreach ($s in $settings) {
    $actual = (Get-ItemProperty -Path $s.Path -Name $s.Name -ErrorAction SilentlyContinue).($s.Name)
    if ($actual -ne $s.Value) { Write-Host "  MISMATCH: $($s.Name) = '$actual'" -ForegroundColor Red; $ok = $false }
}
if ($ok) { Write-Host "  all 5 values correct" -ForegroundColor Green } else { Write-Host "  verification failed" -ForegroundColor Red; exit 1 }

if ($SkipRestart) { Write-Host "`n-SkipRestart given; not restarting services."; exit 0 }

Write-Host "`nRestarting Service Layer nodes (client users unaffected)..." -ForegroundColor Cyan
# Nodes first, load balancer last, so the LB comes up to healthy members.
$names = @(1..10 | ForEach-Object { 'b1s{0:D5}' -f (50000 + $_) }) + 'b1s50000'
foreach ($n in $names) {
    try {
        Restart-Service -Name $n -Force -ErrorAction Stop
        Write-Host "  $n restarted"
    } catch {
        Write-Host "  $n FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`nDone. Give it ~20 seconds, then tell Claude to re-test the login." -ForegroundColor Green
