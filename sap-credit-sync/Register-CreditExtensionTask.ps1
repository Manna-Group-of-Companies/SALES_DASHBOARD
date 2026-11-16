<#
.SYNOPSIS
  Registers the scheduled task that runs Sync-CreditExtensions.ps1 (temporary
  credit extensions, 16 Nov 2026) on the office server. Run elevated, by hand.

.DESCRIPTION
  One task, 'SAP-Credit-Extensions', as SYSTEM, every 5 minutes. Each run reads
  ERPNext first and logs in to SAP only when an extension is waiting to be
  raised or restored, or an active one is due a payment check (at most hourly,
  and always from its commitment date on). This is what makes the expiry,
  the payment check and the credit-limit restore happen without anyone
  pressing anything. It does not touch the existing SAP-Watch-* tasks.

  Previews unless given -Apply. Registering with -Apply makes the task run the
  job WITH -Apply - i.e. writing credit limits in the company named in the
  config. Do that only with the user's go-ahead for that company.

.EXAMPLE
  .\Register-CreditExtensionTask.ps1                         # preview
  .\Register-CreditExtensionTask.ps1 -Apply                  # register
  .\Register-CreditExtensionTask.ps1 -Remove -Apply          # take it away
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = '',
    [int] $EveryMinutes = 5,
    [switch] $Remove,
    [switch] $Apply
)
$ErrorActionPreference = 'Stop'
# Not a parameter default: Windows PowerShell 5.1 has no $PSScriptRoot there.
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$name = 'SAP-Credit-Extensions'
$job = Join-Path $PSScriptRoot 'Sync-CreditExtensions.ps1'
$arg = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -Apply' -f $job, $ConfigPath)

if (-not $Apply) {
    if ($Remove) { Write-Host "Would remove task $name." }
    else { Write-Host ("Would register task {0}: every {1} min as SYSTEM: powershell.exe {2}" -f $name, $EveryMinutes, $arg) }
    Write-Host 'Preview only - nothing changed. -Apply to do it.'
    exit 0
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this elevated (as Administrator).' }

if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Write-Host "Removed the old $name."
}
if ($Remove) { exit 0 }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "No config at $ConfigPath." }

$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
# SYSTEM, as the SAP-Watch-* tasks: a task owned by a person only runs while
# that person is logged on.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Limited
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
Get-ScheduledTask -TaskName $name | Select-Object TaskName, State | Format-Table -AutoSize
