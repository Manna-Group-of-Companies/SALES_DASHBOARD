<#
.SYNOPSIS
  Registers the two Windows Scheduled Tasks that drive the order sync poller.
  Run this yourself (in an elevated or normal PowerShell as eldhose) - the
  agent's session is blocked from registering scheduled tasks directly.

.DESCRIPTION
  - SAP-Hitech-OrderSync-Poll  : every 2 min. Honours the "SAP Order Sync
    Control" sync_requested flag (set automatically by the Server Script once
    you create it - see server-script.py in this folder).
  - SAP-Hitech-OrderSync-Force : every 15 min, offset 5 min from Poll. Runs
    regardless of the flag, so PASS B (stage/delivery pulls) keeps moving even
    if nobody approved anything new.

  Safe to re-run: unregisters and recreates both tasks.

  SUPERSEDED 24 September 2026 by Register-FlagWatchTasks.ps1. The order sync
  no longer runs on a timer at all - only when somebody presses Sync or
  approves an order. Running this would bring back the 15-minute Force run the
  user decided to remove, so it refuses unless told otherwise.
#>
param([switch] $IKnowThisBringsBackTheTimer)
if (-not $IKnowThisBringsBackTheTimer) {
    Write-Host 'Superseded by Register-FlagWatchTasks.ps1 (24 Sep 2026): the order sync now runs only when asked.' -ForegroundColor Yellow
    Write-Host 'This would restore the 15-minute timed sync. Pass -IKnowThisBringsBackTheTimer if that is really what you want.' -ForegroundColor Yellow
    exit 1
}
$dir = 'C:\Users\eldhose\sap-order-sync'
$dur = New-TimeSpan -Days 3650   # Task Scheduler rejects [TimeSpan]::MaxValue - out of range

Unregister-ScheduledTask -TaskName 'SAP-Hitech-OrderSync-Poll'  -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'SAP-Hitech-OrderSync-Force' -Confirm:$false -ErrorAction SilentlyContinue

$aPoll = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dir\Invoke-SapOrderSyncPoller.ps1`"")
$tPoll = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration $dur

$aForce = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dir\Invoke-SapOrderSyncPoller.ps1`" -Force")
$tForce = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddMinutes(5)) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration $dur

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)

# Runs as SYSTEM, which is the whole point: a task registered without a
# principal belongs to whoever ran this script and, by default, only runs while
# THAT account is logged on interactively. Registered from an elevated prompt
# that account is Administrator, who is not sitting at the desktop - so the
# task reports Ready forever and never fires. SYSTEM is always logged on,
# needs no stored password, and survives a reboot.
#
# Safe here because the poller reads everything it needs from files on disk
# (poller.config.json, config.json) and touches nothing in a user profile.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Limited

Register-ScheduledTask -TaskName 'SAP-Hitech-OrderSync-Poll'  -Action $aPoll  -Trigger $tPoll  -Settings $settings -Principal $principal | Out-Null
Register-ScheduledTask -TaskName 'SAP-Hitech-OrderSync-Force' -Action $aForce -Trigger $tForce -Settings $settings -Principal $principal | Out-Null

Get-ScheduledTask -TaskName 'SAP-Hitech-OrderSync-*' | Select-Object TaskName, State
Write-Host "Registered. First Poll run within 2 minutes; first Force run within ~5-7 minutes."
