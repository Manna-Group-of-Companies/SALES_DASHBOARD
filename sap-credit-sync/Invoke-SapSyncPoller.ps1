<#
.SYNOPSIS
  Bridge between the ERPNext "Reload from SAP" button and the on-prem SAP sync.

.DESCRIPTION
  Runs every ~2 minutes from Task Scheduler. Talks ONLY to ERPNext / Frappe
  Cloud (never to SAP directly - Sync-SapCreditLimits.ps1 does that).

  Normal cycle:
    1. GET the "SAP Sync Control" single doc.
    2. If sync_requested != 1 -> nothing to do, exit.
    3. If status == "Running" and last_run_started_at is recent -> another run is
       in progress, exit. If it is stale (crashed run) -> reclaim.
    4. If cooldown_until is in the future -> DO NOT log in to SAP. Leave the flag
       set; a later cycle past the cooldown will pick it up. (A stale flag from a
       crashed run must never become a premature SAP login.)
    5. Claim: PUT status="Running", last_run_started_at=now, sync_requested=0.
    6. Run Sync-SapCreditLimits.ps1 -ResultJsonPath <tmp>.
    7. PUT status="Success"/"Failed", last_result_message, last_rows_changed,
       cooldown_until = now + cooldown_minutes  (read cooldown_minutes from the
       doc - it is admin-tunable), and last_sync_at=now on success.

  -Force  : ignore sync_requested AND cooldown_until, run now, still write status
            back. For the nightly Scheduled Task.

  A local lock file guards against overlap on top of Task Scheduler's own
  "IgnoreNew". The ERPNext status field is the cross-restart source of truth.

  safe_exec note (ERPNext side, for whoever maintains the Server Scripts):
  frappe.get_roles / frappe.has_permission / hasattr / frappe.get_single are NOT
  whitelisted; read roles from the Has Role table and Singles via
  frappe.get_doc("SAP Sync Control").

.PARAMETER ConfigPath
  poller.config.json. Defaults to the file next to this script.

.PARAMETER Force
  Run regardless of the request flag and the cooldown (nightly task).
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [switch] $Force
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably populated inside a param() default on PS 5.1.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir 'poller.config.json' }

# ------------------------------------------------------------------ config + log
if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Error "poller config not found: $ConfigPath"; exit 2 }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$logDir = "$($cfg.log_dir)".Trim()
if (-not $logDir) { $logDir = $PSScriptRoot }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$pollerLog = Join-Path $logDir ('poller-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))

function Log {
    param([ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO', [string]$Message)
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    switch ($Level) { 'ERROR' { Write-Host $line -ForegroundColor Red } 'WARN' { Write-Host $line -ForegroundColor Yellow } default { Write-Host $line } }
    try { Add-Content -LiteralPath $pollerLog -Value $line -Encoding UTF8 } catch { }
}

foreach ($k in 'erpnext_site','bot_api_key','bot_api_secret','control_doctype','sync_script','sync_config') {
    if (-not "$($cfg.$k)".Trim() -or "$($cfg.$k)" -match 'PUT_.*_HERE') {
        Log ERROR "poller config '$k' is missing or still a placeholder."; exit 2
    }
}
foreach ($p in @($cfg.sync_script, $cfg.sync_config)) {
    if (-not (Test-Path -LiteralPath $p)) { Log ERROR "path not found: $p"; exit 2 }
}

$staleMin     = if ($cfg.PSObject.Properties['running_stale_minutes'] -and $cfg.running_stale_minutes) { [int]$cfg.running_stale_minutes } else { 20 }
$syncTimeout  = if ($cfg.PSObject.Properties['sync_timeout_seconds'] -and $cfg.sync_timeout_seconds) { [int]$cfg.sync_timeout_seconds } else { 600 }
$defCooldown  = if ($cfg.PSObject.Properties['default_cooldown_minutes'] -and $cfg.default_cooldown_minutes) { [int]$cfg.default_cooldown_minutes } else { 25 }
$resultJson   = "$($cfg.result_json)".Trim(); if (-not $resultJson) { $resultJson = Join-Path $logDir 'last-result.json' }
$lockFile     = "$($cfg.lock_file)".Trim();   if (-not $lockFile)   { $lockFile   = Join-Path $logDir 'poller.lock' }

# Frappe Cloud needs TLS 1.2; poller only talks to Frappe (real cert - no bypass).
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
}

$site    = "$($cfg.erpnext_site)".TrimEnd('/')
$docName = "$($cfg.control_doctype)"
$docUrl  = "$site/api/resource/$([uri]::EscapeDataString($docName))/$([uri]::EscapeDataString($docName))"
$authHdr = @{ Authorization = "token $($cfg.bot_api_key):$($cfg.bot_api_secret)" }

function Get-Control {
    $r = Invoke-RestMethod -Method Get -Uri $docUrl -Headers $authHdr -TimeoutSec 60
    return $r.data
}
function Set-Control {
    param([hashtable] $Fields)
    $body = ($Fields | ConvertTo-Json -Compress)
    $null = Invoke-RestMethod -Method Put -Uri $docUrl -Headers $authHdr -ContentType 'application/json' -Body $body -TimeoutSec 60
}
function Parse-Dt {
    param($Value)
    if (-not "$Value".Trim()) { return $null }
    try { return [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}
function Now-Str { (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }

# ------------------------------------------------------------------ local lock
if (Test-Path -LiteralPath $lockFile) {
    $age = (Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime
    if ($age.TotalMinutes -lt $staleMin) {
        Log INFO ("another poller run holds the lock (age {0:n1} min) - exiting." -f $age.TotalMinutes)
        exit 0
    }
    Log WARN ("stale lock (age {0:n1} min) - taking it over." -f $age.TotalMinutes)
}
Set-Content -LiteralPath $lockFile -Value ("{0} {1}" -f $PID, (Now-Str)) -Encoding UTF8

$pollerExit = 0
try {
    $doc = Get-Control
    $flag         = [int]("$($doc.sync_requested)" -as [int])
    $status       = "$($doc.status)"
    $cooldownMin  = if ("$($doc.cooldown_minutes)".Trim()) { [int]$doc.cooldown_minutes } else { $defCooldown }
    $cooldownUntil = Parse-Dt $doc.cooldown_until
    $startedAt     = Parse-Dt $doc.last_run_started_at

    if (-not $Force) {
        if ($flag -ne 1) { Log INFO "no request pending (sync_requested=$flag, status=$status) - exiting."; exit 0 }

        if ($status -eq 'Running') {
            if ($startedAt -and ((Get-Date) - $startedAt).TotalMinutes -lt $staleMin) {
                Log INFO ("status=Running and started {0:n1} min ago - a run is in progress, exiting." -f ((Get-Date) - $startedAt).TotalMinutes)
                exit 0
            }
            Log WARN "status=Running but last_run_started_at is stale/missing - treating the previous run as crashed and reclaiming."
        }

        if ($cooldownUntil -and (Get-Date) -lt $cooldownUntil) {
            $mins = [math]::Ceiling(($cooldownUntil - (Get-Date)).TotalMinutes)
            Log INFO ("request pending but inside the SAP cooldown (until {0}, ~{1} min) - NOT logging in; a later cycle will pick it up." -f $cooldownUntil.ToString('yyyy-MM-dd HH:mm:ss'), $mins)
            exit 0
        }
    } else {
        Log INFO "-Force: ignoring sync_requested and cooldown_until."
    }

    # ---- claim ----
    $trigger = if ($Force) { 'schedule' } else { "$($doc.sync_requested_by)" }
    Log INFO ("claiming the run (trigger: {0})." -f $(if ($trigger) { $trigger } else { 'unknown' }))
    Set-Control @{ status = 'Running'; last_run_started_at = (Now-Str); sync_requested = 0 }

    # ---- run the sync as a child process, with a hard timeout ----
    if (Test-Path -LiteralPath $resultJson) { Remove-Item -LiteralPath $resultJson -Force -ErrorAction SilentlyContinue }
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }
    $syncArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $cfg.sync_script,
                  '-ConfigPath', $cfg.sync_config, '-ResultJsonPath', $resultJson)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $psExe
    $psi.Arguments       = ($syncArgs | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = (Split-Path -LiteralPath $cfg.sync_script)
    Log INFO ("running: {0} {1}" -f $psExe, $psi.Arguments)
    $runStart = Get-Date
    $proc = [System.Diagnostics.Process]::Start($psi)
    $timedOut = $false
    if (-not $proc.WaitForExit($syncTimeout * 1000)) {
        $timedOut = $true
        try { $proc.Kill() } catch { }
        Log ERROR ("sync exceeded {0}s - killed." -f $syncTimeout)
        Set-Control @{
            status              = 'Failed'
            last_result_message = "Sync timed out after $syncTimeout s and was killed."
            last_rows_changed   = 0
            cooldown_until      = (Get-Date).AddMinutes($cooldownMin).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }
    if (-not $timedOut) {
        $syncExit = $proc.ExitCode
        $elapsed  = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
        Log INFO ("sync process exited {0} after {1}s." -f $syncExit, $elapsed)

        # ---- read result + report back ----
        $res = $null
        if (Test-Path -LiteralPath $resultJson) {
            try { $res = Get-Content -LiteralPath $resultJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Log WARN "could not parse result json: $($_.Exception.Message)" }
        }

        $rows = 0
        $msg  = $null
        $failures = 0
        if ($res) {
            if ($res.PSObject.Properties['customersChanged']) { $rows = [int]$res.customersChanged }
            if ($res.PSObject.Properties['failures'])         { $failures = [int]$res.failures }
            if ($res.PSObject.Properties['summary'] -and "$($res.summary)".Trim()) { $msg = "$($res.summary)" }
            elseif ($res.PSObject.Properties['error'] -and "$($res.error)".Trim()) { $msg = "FATAL: $($res.error)" }
        }
        if (-not $msg) { $msg = "sync exited $syncExit after ${elapsed}s (no result file)." }
        if ($msg.Length -gt 500) { $msg = $msg.Substring(0, 500) + ' ...' }

        $success = ($syncExit -eq 0 -and $failures -eq 0 -and -not ($res -and $res.PSObject.Properties['error'] -and "$($res.error)".Trim()))

        $final = @{
            status              = $(if ($success) { 'Success' } else { 'Failed' })
            last_result_message = $msg
            last_rows_changed   = $rows
            cooldown_until      = (Get-Date).AddMinutes($cooldownMin).ToString('yyyy-MM-dd HH:mm:ss')
        }
        if ($success) { $final.last_sync_at = (Now-Str) }
        Set-Control $final
        Log INFO ("reported back: status={0} rows={1} cooldown_until={2}" -f $final.status, $rows, $final.cooldown_until)
    }
}
catch {
    $pollerExit = 1
    Log ERROR ("poller error: {0}" -f $_.Exception.Message)
    Log ERROR ("at: {0}" -f $_.ScriptStackTrace)
    # best effort: don't leave the doc stuck on "Running"
    try {
        Set-Control @{
            status = 'Failed'
            last_result_message = "Poller error: $($_.Exception.Message)"
            cooldown_until = (Get-Date).AddMinutes($defCooldown).ToString('yyyy-MM-dd HH:mm:ss')
        }
    } catch { Log ERROR "could not write Failed status back: $($_.Exception.Message)" }
}
finally {
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

exit $pollerExit
