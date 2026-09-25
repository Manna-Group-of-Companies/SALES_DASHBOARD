<#
.SYNOPSIS
  Watches one sync's request flag every few seconds and runs its poller the
  moment somebody asks. Replaces the timed syncs (24 Sep 2026).

.DESCRIPTION
  From 24 September 2026 nothing syncs with SAP on a timer. Orders, stock and
  credit limits all run only when a user presses Sync in either app, or when an
  order is approved. That press raises a flag on an ERPNext Single; this watches
  the flag.

  WHY A LOOP INSIDE A ONE-MINUTE TASK

  Windows Task Scheduler cannot repeat a task more often than once a minute. So
  the task starts this every minute, and this checks the flag every
  -IntervalSeconds (15) until the minute is up, then exits. The next minute's
  instance takes over. With MultipleInstances = IgnoreNew a watcher that is busy
  running a sync simply delays the next one - two never overlap.

  WHY THE POLLER IS NOT CHANGED

  The existing pollers (Invoke-SapOrderSyncPoller.ps1, Invoke-HitechFetchPoller.ps1,
  Invoke-SapSyncPoller.ps1) already do everything right - claim the run, honour
  the cooldown, reclaim a crashed run, write the outcome back. They just exit
  after one look. This does the cheap part - one small HTTPS read of the flag -
  four times a minute, and only starts a poller when there is work. So the
  server starts one short-lived PowerShell per sync per minute, not four, and
  SAP is never touched unless somebody asked.

  The flag check never logs into SAP. SAP licence seats are only used by the
  poller, and only when the flag is up.

  A flag raised inside the cooldown is not a reason to start the poller: it
  would only log that it is waiting. This waits too, and starts it once the
  cooldown has passed. The poller remains the authority on the cooldown.

  LOGGING

  Quiet by design: a line when it starts a poller, and at most one line per
  minute when the flag cannot be read. Checking and finding nothing is the
  normal case and is not logged, or the log would grow by 5,760 lines a day.

.PARAMETER PollerScript   The poller to run when the flag is up.
.PARAMETER PollerConfig   That poller's poller.config.json. Its ERPNext site,
                          bot credentials and control_doctype are reused here.
.PARAMETER FlagField      The flag on the control doc: sync_requested or fetch_requested.
.PARAMETER IntervalSeconds  Seconds between checks. Default 15.
.PARAMETER WindowSeconds  How long this instance keeps checking. Default 55, so
                          it is gone before the next minute's instance starts.
.PARAMETER Once           Check exactly once and exit (for testing by hand).

.EXAMPLE
  .\Invoke-FlagWatch.ps1 -PollerScript C:\Users\eldhose\sap-order-sync\Invoke-SapOrderSyncPoller.ps1 `
      -PollerConfig C:\Users\eldhose\sap-order-sync\poller.config.json -FlagField sync_requested -Once
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $PollerScript,
    [Parameter(Mandatory = $true)] [string] $PollerConfig,
    [Parameter(Mandatory = $true)] [ValidateSet('sync_requested', 'fetch_requested')] [string] $FlagField,
    [ValidateRange(5, 60)] [int] $IntervalSeconds = 15,
    [ValidateRange(5, 58)] [int] $WindowSeconds = 55,
    [switch] $Once
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

foreach ($p in $PollerScript, $PollerConfig) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Error "not found: $p"; exit 2 }
}
$cfg = Get-Content -LiteralPath $PollerConfig -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($k in 'erpnext_site', 'bot_api_key', 'bot_api_secret', 'control_doctype') {
    if (-not "$($cfg.$k)".Trim()) { Write-Error "poller config is missing '$k': $PollerConfig"; exit 2 }
}

$logDir = "$($cfg.log_dir)".Trim()
if (-not $logDir) { $logDir = Split-Path -Parent $PollerConfig }
if (-not [System.IO.Path]::IsPathRooted($logDir)) { $logDir = Join-Path (Split-Path -Parent $PollerConfig) ($logDir -replace '^[.][\\/]', '') }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ('flag-watch-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))

function Log {
    param([string] $Level, [string] $Message)
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$site    = "$($cfg.erpnext_site)".TrimEnd('/')
$docName = "$($cfg.control_doctype)"
$docUrl  = "$site/api/resource/$([uri]::EscapeDataString($docName))/$([uri]::EscapeDataString($docName))"
$authHdr = @{ Authorization = ('token {0}:{1}' -f $cfg.bot_api_key, $cfg.bot_api_secret) }

function Parse-Dt {
    param($Value)
    if (-not "$Value".Trim()) { return $null }
    try { return [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

<#
  What one look at the control doc decides. Pure, so the test can drive it.
  Returns 'run', 'wait' (flag up, cooldown not over) or 'idle' (no flag).
#>
function Get-WatchDecision {
    param($Doc, [string] $FlagField, [datetime] $Now)
    if ($null -eq $Doc) { return 'idle' }
    $flag = 0
    try { $flag = [int]("$($Doc.$FlagField)" -as [int]) } catch { $flag = 0 }
    if ($flag -ne 1) { return 'idle' }
    $until = Parse-Dt $Doc.cooldown_until
    if ($until -and $Now -lt $until) { return 'wait' }
    return 'run'
}

$started   = Get-Date
$deadline  = $started.AddSeconds($WindowSeconds)
$lastError = $null
$ran       = 0
$tag       = Split-Path -Leaf $PollerScript

do {
    $tick = Get-Date
    $decision = 'idle'
    try {
        $doc = (Invoke-RestMethod -Method Get -Uri $docUrl -Headers $authHdr -TimeoutSec 10).data
        $decision = Get-WatchDecision -Doc $doc -FlagField $FlagField -Now (Get-Date)
        $lastError = $null
    } catch {
        $msg = $_.Exception.Message
        # One line per minute at most for a failure that repeats every check.
        if ($msg -ne $lastError) { Log WARN ("cannot read {0}: {1}" -f $docName, $msg) }
        $lastError = $msg
    }

    if ($decision -eq 'run') {
        Log INFO ("{0} is up on {1} - starting {2}." -f $FlagField, $docName, $tag)
        # Quoted by hand: Start-Process joins the list with spaces and quotes nothing.
        $pollerArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                        '-File', ('"{0}"' -f $PollerScript), '-ConfigPath', ('"{0}"' -f $PollerConfig))
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $pollerArgs -NoNewWindow -Wait -PassThru
        $ran++
        Log INFO ("{0} exited {1} after {2:n0}s." -f $tag, $proc.ExitCode, ((Get-Date) - $tick).TotalSeconds)
        # A flag raised during that run is still up; look again straight away
        # rather than waiting out the interval.
        continue
    }

    if ($Once) { break }
    $sleep = $IntervalSeconds - ((Get-Date) - $tick).TotalSeconds
    if ($sleep -gt 0 -and (Get-Date).AddSeconds($sleep) -lt $deadline) { Start-Sleep -Milliseconds ([int]($sleep * 1000)) }
    else { break }
} while ((Get-Date) -lt $deadline)

exit 0
