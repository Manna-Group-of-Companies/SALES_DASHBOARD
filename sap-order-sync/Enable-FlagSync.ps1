<#
.SYNOPSIS
  The release switch: invoice-only order status + sync only when asked.
  Run this from an ELEVATED PowerShell, at the moment the new apps ship.

.DESCRIPTION
  Staged 24 September 2026. Two decisions go live together here:
    1. the order sync reports Pushed to SAP -> Dispatched on the A/R invoice,
       with no production stages (the new Sync-SapOrders.ps1);
    2. nothing syncs on a timer: orders, stock and credit run only when
       somebody presses Sync or approves an order (Register-FlagWatchTasks.ps1).

  WHY IT WAITS FOR THE APPS. The phones still carry the old APK, which does not
  raise the order flag when a manager approves. Remove the timers before the
  new APK is installed and a phone-approved order never reaches SAP. And the
  live dashboard has no stock Sync button until it is redeployed.

  WHAT IT DOES, stopping and putting everything back at the first failure:
    1. backs up the live scripts it replaces into pre-flagsync-<time>\
    2. copies the staged scripts from release-2026-09-24\ into place, and
       retires Test-PoLinking.ps1 (it tests functions that no longer exist)
    3. runs the offline test suites here, against the files now in place
    4. dry-runs the new order sync against live SAP and ERPNext (writes nothing)
    5. removes the order/stock/credit timers and registers the three watchers

  The ERPNext side needs nothing: the invoice fields, the stock control Single
  and all six Server Scripts are already live.

.PARAMETER Preview  Check everything and show the task changes; change nothing.

.NOTES
  ALREADY RUN - kept as the record of the 24 September 2026 release. Running it
  again copies release-2026-09-24\ over the live scripts: the September
  Sync-SapOrders.ps1 (no approval step, no B1if fix) and that release's README.
  So it refuses unless told otherwise. The live copy is updated with
  Update-ServerCopy.ps1 now. Added to the repository 24 Nov 2026 from the SAP
  server, where it was never committed; only this guard is new.
#>
[CmdletBinding()]
param([switch] $Preview, [switch] $IKnowThisRestoresTheSeptemberRelease)

if (-not $IKnowThisRestoresTheSeptemberRelease) {
    Write-Host 'Already run (24 Sep 2026). This would copy the September release over the live scripts, losing everything since - the approval step among it.' -ForegroundColor Yellow
    Write-Host 'Use Update-ServerCopy.ps1 instead. Pass -IKnowThisRestoresTheSeptemberRelease if that is really what you want.' -ForegroundColor Yellow
    exit 1
}

$ErrorActionPreference = 'Stop'
$live = 'C:\Users\eldhose\sap-order-sync'
$rel  = Join-Path $live 'release-2026-09-24'
$swap = 'Sync-SapOrders.ps1', 'Invoke-SapOrderSyncPoller.ps1', 'Test-InvoiceLinking.ps1',
        'Register-OrderSyncTasks.ps1', 'README.md', 'config.example.json'

function Say { param([string]$m, [string]$c = 'Gray') Write-Host $m -ForegroundColor $c }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Say 'Run this from an elevated PowerShell (Run as administrator).' Red; exit 1 }

foreach ($f in $swap) {
    if (-not (Test-Path -LiteralPath (Join-Path $rel $f))) { Say "Staged file missing: $rel\$f" Red; exit 1 }
}

if ($Preview) {
    Say 'PREVIEW - nothing will change.' Yellow
    Say "Would replace in ${live}: $($swap -join ', ')" Cyan
    Say 'Would retire: Test-PoLinking.ps1' Cyan
    & (Join-Path $live 'Register-FlagWatchTasks.ps1')
    exit 0
}

$stamp  = Get-Date -Format yyyyMMdd-HHmmss
$backup = Join-Path $live "pre-flagsync-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null

function Restore {
    Say "Restoring the previous scripts from $backup ..." Yellow
    foreach ($f in Get-ChildItem -LiteralPath $backup -File) { Copy-Item $f.FullName (Join-Path $live $f.Name) -Force }
    foreach ($f in $swap) {
        # a file that did not exist before the swap is removed again
        if (-not (Test-Path -LiteralPath (Join-Path $backup $f))) { Remove-Item (Join-Path $live $f) -Force -ErrorAction SilentlyContinue }
    }
    Say 'Restored. Nothing else was changed; the timers are as they were.' Yellow
}

# ---- 1-2. swap the scripts ----
foreach ($f in $swap + 'Test-PoLinking.ps1') {
    $p = Join-Path $live $f
    if (Test-Path -LiteralPath $p) { Copy-Item $p (Join-Path $backup $f) -Force }
}
foreach ($f in $swap) { Copy-Item (Join-Path $rel $f) (Join-Path $live $f) -Force }
Remove-Item (Join-Path $live 'Test-PoLinking.ps1') -Force -ErrorAction SilentlyContinue
Say "scripts swapped (previous copies in $backup)" Green

# ---- 3. offline tests, against what is now in place ----
foreach ($t in 'Test-InvoiceLinking.ps1', 'Test-FlagWatch.ps1', 'Test-LineReconcile.ps1') {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $live $t) 2>&1
    $code = $LASTEXITCODE
    $line = ($out | Where-Object { "$_" -match 'passed' }) -join ''
    if ($code -ne 0) { Say "FAILED $t : $line" Red; $out | Where-Object { "$_" -match 'FAIL' } | ForEach-Object { Say "  $_" Red }; Restore; exit 1 }
    Say "tests  $t : $line" Green
}

# ---- 4. read-only dry run of the new order sync ----
Say 'dry run of the new order sync (reads SAP and ERPNext, writes nothing) ...' Cyan
$out  = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $live 'Sync-SapOrders.ps1') -ConfigPath (Join-Path $live 'config.json') -DryRun 2>&1
$code = $LASTEXITCODE
$sum  = ($out | Where-Object { "$_" -match 'SUMMARY' }) -join ''
if ($code -ne 0) { Say "dry run FAILED (exit $code): $sum" Red; $out | Select-Object -Last 15 | ForEach-Object { Say "  $_" Red }; Restore; exit 1 }
Say "dry run OK: $sum" Green

# ---- 5. timers out, watchers in ----
& (Join-Path $live 'Register-FlagWatchTasks.ps1') -Apply
if ($LASTEXITCODE -ne 0) {
    Say 'The task switch did not complete. The NEW scripts are in place and the old timers may still be running them - which works, but is not flag-only yet. Fix the error above and re-run Register-FlagWatchTasks.ps1 -Apply.' Red
    exit 1
}

Say ''
Say 'LIVE. From now on SAP syncs only when somebody presses Sync or approves an order.' Cyan
Say "To undo the scripts: copy $backup\* back into $live." DarkGray
Say 'To undo the timers:  Register-OrderSyncTasks.ps1 -IKnowThisBringsBackTheTimer (and the stock/credit equivalents).' DarkGray
