<#
.SYNOPSIS
  Switches the server from timed SAP syncs to "sync only when somebody asks".
  Run this yourself - the agent's session cannot register scheduled tasks.

.DESCRIPTION
  Decided 24 September 2026: orders, stock and credit limits no longer sync on
  a timer. They run when a user presses Sync in either app, or when an order is
  approved. The press raises a flag in ERPNext; Invoke-FlagWatch.ps1 checks the
  flag every 15 seconds.

  REMOVES every scheduled task whose action runs one of these, whatever it is
  called:
      Invoke-SapOrderSyncPoller.ps1   (order Poll every 2 min, Force every 15)
      Sync-HitechStockToTreads.ps1    (stock every 5 min)
      Invoke-HitechFetchPoller.ps1    (the old 1-minute stock fetch poller)
      Sync-SapCreditLimits.ps1        (credit limits nightly at 02:30)
      Invoke-SapSyncPoller.ps1        (the old 2-minute credit poller)
      Invoke-FlagWatch.ps1            (a previous run of this script)
  Matching on the script, not the task name, because the names were chosen by
  hand over several weeks and this cannot be sure of every one.

  KEEPS everything else - in particular Sync-HitechProductsToTreads.ps1, the
  30-minute products/weights sync, which was not part of the change.

  REGISTERS four watchers, each every minute, as SYSTEM:
      SAP-Watch-Orders   -> Invoke-SapOrderSyncPoller.ps1  (sync_requested)
      SAP-Watch-Stock    -> Invoke-HitechFetchPoller.ps1   (fetch_requested)
      SAP-Watch-Credit   -> Invoke-SapSyncPoller.ps1       (sync_requested)
      SAP-Watch-Pricing  -> Invoke-SapPricingPoller.ps1    (sync_requested)
                            the MD's rates screen; reads Hi-Tech prices only,
                            added 25 Sep 2026 (sap-pricing/)

  Without -Apply it only prints what it would do.

.PARAMETER Apply  Actually change the scheduled tasks. Omit to preview.

.EXAMPLE
  .\Register-FlagWatchTasks.ps1            # preview
  .\Register-FlagWatchTasks.ps1 -Apply     # do it
#>
[CmdletBinding()]
param([switch] $Apply)

$ErrorActionPreference = 'Stop'

# MUST RUN ELEVATED. The existing sync tasks run as SYSTEM, and a non-elevated
# session cannot see SYSTEM's tasks at all - Get-ScheduledTask simply leaves
# them out. Run unelevated, this would find nothing to remove and add the
# watchers ALONGSIDE the old timers, so both would run. (It is also why an
# agent session sees no sync tasks on this machine while their logs grow.)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Run this from an elevated PowerShell (Run as administrator).' -ForegroundColor Red
    Write-Host 'Unelevated, the SYSTEM-owned sync tasks are invisible here and would be left running.' -ForegroundColor Red
    exit 1
}

$watch = 'C:\Users\eldhose\sap-order-sync\Invoke-FlagWatch.ps1'
$watchers = @(
    @{ Name = 'SAP-Watch-Orders'
       Poller = 'C:\Users\eldhose\sap-order-sync\Invoke-SapOrderSyncPoller.ps1'
       Config = 'C:\Users\eldhose\sap-order-sync\poller.config.json'
       Flag   = 'sync_requested' },
    @{ Name = 'SAP-Watch-Stock'
       Poller = 'C:\Users\eldhose\sap-treads-stock-sync\Invoke-HitechFetchPoller.ps1'
       Config = 'C:\Users\eldhose\sap-treads-stock-sync\poller.config.json'
       Flag   = 'fetch_requested' },
    @{ Name = 'SAP-Watch-Credit'
       Poller = 'C:\Users\eldhose\sap-credit-sync\Invoke-SapSyncPoller.ps1'
       Config = 'C:\Users\eldhose\sap-credit-sync\poller.config.json'
       Flag   = 'sync_requested' },
    @{ Name = 'SAP-Watch-Pricing'
       Poller = 'C:\Users\eldhose\sap-pricing-sync\Invoke-SapPricingPoller.ps1'
       Config = 'C:\Users\eldhose\sap-pricing-sync\poller.config.json'
       Flag   = 'sync_requested' }
)
$retire = @(
    'Invoke-SapOrderSyncPoller.ps1', 'Sync-HitechStockToTreads.ps1', 'Invoke-HitechFetchPoller.ps1',
    'Sync-SapCreditLimits.ps1', 'Invoke-SapSyncPoller.ps1', 'Invoke-FlagWatch.ps1',
    'Invoke-SapPricingPoller.ps1'
)

# ---- preflight: everything the watchers will run must be there ----
$missing = @()
foreach ($p in @($watch) + @($watchers | ForEach-Object { $_.Poller; $_.Config })) {
    if (-not (Test-Path -LiteralPath $p)) { $missing += $p }
}
if ($missing.Count) {
    Write-Host 'Stopping - these files are missing:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host 'Copy Invoke-FlagWatch.ps1 from the repository to C:\Users\eldhose\sap-order-sync\ first.' -ForegroundColor Yellow
    exit 1
}

# ---- what is scheduled now ----
function Get-Action { param($Task) (@($Task.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; ' }

$all = @(Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })
Write-Host ''
Write-Host "Scheduled tasks outside \Microsoft\ right now: $($all.Count)" -ForegroundColor Cyan
$toRemove = @()
foreach ($t in $all) {
    $act  = Get-Action $t
    $hit  = @($retire | Where-Object { $act -like "*$_*" })
    $mark = if ($hit.Count) { 'REMOVE' } else { 'keep  ' }
    if ($hit.Count) { $toRemove += $t }
    Write-Host ("  {0}  {1}{2}  [{3}]" -f $mark, $t.TaskPath, $t.TaskName, $t.State)
    Write-Host ("          {0}" -f $act) -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Will register (every minute, as SYSTEM, one instance at a time):' -ForegroundColor Cyan
foreach ($w in $watchers) { Write-Host ("  {0,-17} {1}  flag={2}" -f $w.Name, (Split-Path -Leaf $w.Poller), $w.Flag) }

if (-not $Apply) {
    Write-Host ''
    Write-Host 'PREVIEW ONLY - nothing changed. Re-run with -Apply to do it.' -ForegroundColor Yellow
    exit 0
}

# ---- apply ----
foreach ($t in $toRemove) {
    Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false
    Write-Host ("removed  {0}{1}" -f $t.TaskPath, $t.TaskName) -ForegroundColor Green
}

$dur       = New-TimeSpan -Days 3650   # Task Scheduler rejects [TimeSpan]::MaxValue
# 30 minutes, not the watcher's 55 seconds: a watcher that is running a sync
# waits for it, and the order sync alone is allowed up to its own timeout.
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
# SYSTEM for the reason Register-OrderSyncTasks.ps1 gives: a task owned by a
# person only runs while that person is logged on interactively.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Limited
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration $dur

foreach ($w in $watchers) {
    $arg = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PollerScript "{1}" -PollerConfig "{2}" -FlagField {3}' -f `
            $watch, $w.Poller, $w.Config, $w.Flag)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    Register-ScheduledTask -TaskName $w.Name -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
    Write-Host ("registered {0}" -f $w.Name) -ForegroundColor Green
}

Write-Host ''
Get-ScheduledTask -TaskName 'SAP-Watch-*' | Select-Object TaskName, State | Format-Table -AutoSize
Write-Host 'Done. Press Sync in either app; the watcher should pick it up within 15 seconds.' -ForegroundColor Cyan
Write-Host 'Each watcher writes flag-watch-<date>.log next to its poller''s own logs.' -ForegroundColor DarkGray
