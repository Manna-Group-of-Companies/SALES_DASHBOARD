<#
.SYNOPSIS
  Bridge between the Managing Director's "Sync from SAP" button (rates screen)
  and Sync-SapPricingSnapshot.ps1, which copies Manna Treads' prices, and
  Hi-Tech Pretreads' for the same items, out of SAP into ERPNext and checks
  them. Started by Invoke-FlagWatch.ps1 when sync_requested is up.
.DESCRIPTION
  Generated on 25 Sep 2026 from Invoke-HitechFetchPoller.ps1, with the flag and
  field names of "SAP Pricing Control": sync_requested, last_sync_at. The cycle
  is the same:
    1. GET the control Single. No request -> exit.
    2. Running and recent -> exit; stale -> reclaim.
    3. Inside cooldown_until -> leave the flag up, do not log in to SAP.
    4. Claim: status=Running, last_run_started_at=now, sync_requested=0.
    5. Run the sync script with -ConfigPath <sync_config> -ResultJsonPath <tmp>.
    6. Report: status Success/Failed, last_result_message, last_rows_changed,
       cooldown_until = now + cooldown_minutes, last_sync_at on success.
  The sync only READS SAP. Prices reach SAP as DTW files from the rates screen.
.PARAMETER ConfigPath  poller.config.json. Defaults to the file next to this script.
.PARAMETER Force        Run regardless of the request flag and the cooldown.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [switch] $Force
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir 'poller.config.json' }

if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Error "poller config not found: $ConfigPath"; exit 2 }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$logDir = "$($cfg.log_dir)".Trim()
if (-not $logDir) { $logDir = $scriptDir }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$pollerLog = Join-Path $logDir ('pricing-poller-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))

function Log {
    param([ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO', [string]$Message)
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    switch ($Level) { 'ERROR' { Write-Host $line -ForegroundColor Red } 'WARN' { Write-Host $line -ForegroundColor Yellow } default { Write-Host $line } }
    try { Add-Content -LiteralPath $pollerLog -Value $line -Encoding UTF8 } catch { }
}

foreach ($k in 'erpnext_site','bot_api_key','bot_api_secret','control_doctype','sync_script','sync_config') {
    if (-not "$($cfg.$k)".Trim() -or "$($cfg.$k)" -match 'PUT_.*_HERE') { Log ERROR "poller config '$k' is missing or still a placeholder."; exit 2 }
}
foreach ($p in @($cfg.sync_script, $cfg.sync_config)) { if (-not (Test-Path -LiteralPath $p)) { Log ERROR "path not found: $p"; exit 2 } }

$staleMin    = if ($cfg.PSObject.Properties['running_stale_minutes'] -and $cfg.running_stale_minutes) { [int]$cfg.running_stale_minutes } else { 15 }
$syncTimeout = if ($cfg.PSObject.Properties['sync_timeout_seconds'] -and $cfg.sync_timeout_seconds) { [int]$cfg.sync_timeout_seconds } else { 600 }
$defCooldown = if ($cfg.PSObject.Properties['default_cooldown_minutes'] -and $cfg.default_cooldown_minutes) { [int]$cfg.default_cooldown_minutes } else { 2 }
$resultJson  = "$($cfg.result_json)".Trim(); if (-not $resultJson) { $resultJson = Join-Path $logDir 'pricing-last-result.json' }
$lockFile    = "$($cfg.lock_file)".Trim();   if (-not $lockFile)   { $lockFile   = Join-Path $logDir 'pricing-poller.lock' }

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
}

$site    = "$($cfg.erpnext_site)".TrimEnd('/')
$docName = "$($cfg.control_doctype)"
$docUrl  = "$site/api/resource/$([uri]::EscapeDataString($docName))/$([uri]::EscapeDataString($docName))"
$authHdr = @{ Authorization = "token $($cfg.bot_api_key):$($cfg.bot_api_secret)" }

function Get-Control { (Invoke-RestMethod -Method Get -Uri $docUrl -Headers $authHdr -TimeoutSec 60).data }
function Set-Control { param([hashtable] $Fields) $null = Invoke-RestMethod -Method Put -Uri $docUrl -Headers $authHdr -ContentType 'application/json' -Body ($Fields | ConvertTo-Json -Compress) -TimeoutSec 60 }
function Parse-Dt { param($Value) if (-not "$Value".Trim()) { return $null } try { return [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture) } catch { return $null } }
function Now-Str { (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }

if (Test-Path -LiteralPath $lockFile) {
    $age = (Get-Date) - (Get-Item -LiteralPath $lockFile).LastWriteTime
    if ($age.TotalMinutes -lt $staleMin) { Log INFO ("another poller run holds the lock (age {0:n1} min) - exiting." -f $age.TotalMinutes); exit 0 }
    Log WARN ("stale lock (age {0:n1} min) - taking it over." -f $age.TotalMinutes)
}
Set-Content -LiteralPath $lockFile -Value ("{0} {1}" -f $PID, (Now-Str)) -Encoding UTF8

$pollerExit = 0
try {
    $doc = Get-Control
    $flag          = [int]("$($doc.sync_requested)" -as [int])
    $status        = "$($doc.status)"
    $cooldownMin   = if ("$($doc.cooldown_minutes)".Trim()) { [int]$doc.cooldown_minutes } else { $defCooldown }
    $cooldownUntil = Parse-Dt $doc.cooldown_until
    $startedAt     = Parse-Dt $doc.last_run_started_at

    if (-not $Force) {
        if ($flag -ne 1) { Log INFO "no request pending (sync_requested=$flag, status=$status) - exiting."; exit 0 }
        if ($status -eq 'Running') {
            if ($startedAt -and ((Get-Date) - $startedAt).TotalMinutes -lt $staleMin) {
                Log INFO ("status=Running, started {0:n1} min ago - a run is in progress, exiting." -f ((Get-Date) - $startedAt).TotalMinutes); exit 0
            }
            Log WARN "status=Running but last_run_started_at is stale/missing - reclaiming the crashed run."
        }
        if ($cooldownUntil -and (Get-Date) -lt $cooldownUntil) {
            $mins = [math]::Ceiling(($cooldownUntil - (Get-Date)).TotalMinutes)
            Log INFO ("request pending but inside the cooldown (until {0}, ~{1} min) - NOT logging in to SAP; a later cycle picks it up." -f $cooldownUntil.ToString('yyyy-MM-dd HH:mm:ss'), $mins)
            exit 0
        }
    } else { Log INFO "-Force: ignoring sync_requested and cooldown_until." }

    $trigger = if ($Force) { 'schedule' } else { "$($doc.sync_requested_by)" }
    Log INFO ("claiming the run (trigger: {0})." -f $(if ($trigger) { $trigger } else { 'unknown' }))
    Set-Control @{ status = 'Running'; last_run_started_at = (Now-Str); sync_requested = 0 }

    if (Test-Path -LiteralPath $resultJson) { Remove-Item -LiteralPath $resultJson -Force -ErrorAction SilentlyContinue }
    $psExe = (Get-Process -Id $PID).Path; if (-not $psExe) { $psExe = 'powershell.exe' }
    $syncArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $cfg.sync_script, '-ConfigPath', $cfg.sync_config, '-ResultJsonPath', $resultJson)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName         = $psExe
    $psi.Arguments        = ($syncArgs | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }) -join ' '
    $psi.UseShellExecute  = $false
    $psi.WorkingDirectory = (Split-Path -LiteralPath $cfg.sync_script)
    Log INFO ("running: {0} {1}" -f $psExe, $psi.Arguments)
    $runStart = Get-Date
    $proc = [System.Diagnostics.Process]::Start($psi)
    $timedOut = $false
    if (-not $proc.WaitForExit($syncTimeout * 1000)) {
        $timedOut = $true
        try { $proc.Kill() } catch { }
        Log ERROR ("sync exceeded {0}s - killed." -f $syncTimeout)
        Set-Control @{ status = 'Failed'; last_result_message = "Price sync timed out after $syncTimeout s and was killed."; last_rows_changed = 0
                       cooldown_until = (Get-Date).AddMinutes($cooldownMin).ToString('yyyy-MM-dd HH:mm:ss') }
    }
    if (-not $timedOut) {
        $syncExit = $proc.ExitCode
        $elapsed  = [math]::Round(((Get-Date) - $runStart).TotalSeconds, 1)
        Log INFO ("sync process exited {0} after {1}s." -f $syncExit, $elapsed)

        $res = $null
        if (Test-Path -LiteralPath $resultJson) { try { $res = Get-Content -LiteralPath $resultJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Log WARN "could not parse result json: $($_.Exception.Message)" } }

        $rows = 0; $msg = $null; $failures = 0
        if ($res) {
            if ($res.PSObject.Properties['changed'])  { $rows = [int]$res.changed }
            if ($res.PSObject.Properties['failures']) { $failures = [int]$res.failures }
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
    try { Set-Control @{ status = 'Failed'; last_result_message = "Poller error: $($_.Exception.Message)"; cooldown_until = (Get-Date).AddMinutes($defCooldown).ToString('yyyy-MM-dd HH:mm:ss') } }
    catch { Log ERROR "could not write Failed status back: $($_.Exception.Message)" }
}
finally { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }

exit $pollerExit
