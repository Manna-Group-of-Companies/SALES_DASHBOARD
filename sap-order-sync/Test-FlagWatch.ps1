<#
.SYNOPSIS
  Proves Invoke-FlagWatch.ps1 starts a poller exactly when it should.

.DESCRIPTION
  Extracts the real functions from Invoke-FlagWatch.ps1 (by AST, so its main
  loop never runs) and drives Get-WatchDecision with control documents built
  in memory. Nothing is read or written; runs with ERPNext and SAP both down.

  The decision matters in both directions: starting a poller for nothing costs
  a PowerShell start every 15 seconds, and failing to start one leaves a user's
  Sync press - or an approved order - sitting unseen.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$path = Join-Path $PSScriptRoot 'Invoke-FlagWatch.ps1'
$ast  = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
$fns  = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
         Where-Object { $_.Name -in 'Parse-Dt', 'Get-WatchDecision' } | ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($fns))

$script:pass = 0; $script:fail = 0
function Check { param([string] $What, [bool] $Ok, [string] $Got = '')
    if ($Ok) { $script:pass++; Write-Host "  PASS  $What" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $What  ->  $Got" -ForegroundColor Red } }

$now = [datetime]'2026-09-24 16:00:00'
function Doc { param($Flag, $Until = '', $Field = 'sync_requested')
    $o = [pscustomobject]@{ cooldown_until = $Until; status = 'Success' }
    $o | Add-Member -NotePropertyName $Field -NotePropertyValue $Flag
    $o }

Write-Host "`nGet-WatchDecision" -ForegroundColor Cyan
$d = Get-WatchDecision -Doc (Doc 1) -FlagField sync_requested -Now $now
Check 'flag up, no cooldown -> run' ($d -eq 'run') $d

$d = Get-WatchDecision -Doc (Doc 0) -FlagField sync_requested -Now $now
Check 'flag down -> idle (the normal case, nothing started)' ($d -eq 'idle') $d

$d = Get-WatchDecision -Doc (Doc 1 '2026-09-24 16:00:40') -FlagField sync_requested -Now $now
Check 'flag up inside the cooldown -> wait, do not start the poller just to log' ($d -eq 'wait') $d

$d = Get-WatchDecision -Doc (Doc 1 '2026-09-24 15:59:00') -FlagField sync_requested -Now $now
Check 'flag up, cooldown over -> run' ($d -eq 'run') $d

$d = Get-WatchDecision -Doc (Doc 1 '' 'fetch_requested') -FlagField fetch_requested -Now $now
Check 'the stock flag has a different name and is read by it' ($d -eq 'run') $d

$d = Get-WatchDecision -Doc (Doc 1 '' 'fetch_requested') -FlagField sync_requested -Now $now
Check 'the wrong flag name reads as no request, never as one' ($d -eq 'idle') $d

$d = Get-WatchDecision -Doc (Doc '1') -FlagField sync_requested -Now $now
Check 'a flag that arrives as text still counts' ($d -eq 'run') $d

$d = Get-WatchDecision -Doc (Doc 1 'not a date') -FlagField sync_requested -Now $now
Check 'an unreadable cooldown does not block a request' ($d -eq 'run') $d

$d = Get-WatchDecision -Doc $null -FlagField sync_requested -Now $now
Check 'no document (read failed) -> idle' ($d -eq 'idle') $d

Write-Host ''
Write-Host ("{0} passed, {1} failed." -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
