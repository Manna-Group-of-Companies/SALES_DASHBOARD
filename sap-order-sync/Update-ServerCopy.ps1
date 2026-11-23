<#
.SYNOPSIS
  Puts main's Sync-SapOrders.ps1 on the SAP server, so PASS M sends an order
  to Manna Treads SAP only once it is approved (23 Nov 2026).

.DESCRIPTION
  Run ON THE SAP SERVER, over RDP. Take this file and Sync-SapOrders.ps1 from
  main's sap-order-sync/ (a download or a checkout), put the two side by side
  in any folder that is NOT the live one, and from that folder run:

      powershell -ExecutionPolicy Bypass -File .\Update-ServerCopy.ps1

  The live copy is updated by hand because the server is not a git checkout;
  this is how. Written 23 Nov 2026, after the server's older copy sent four
  unapproved orders to SAP.

  It changes ONE file, and only after these checks pass:
    1. the new script in this folder carries the approval gate;
    2. config.json does not switch the gate off (order_flow.require_approval
       false) - it STOPS if it does, and config.json is never edited here;
    3. no sync is running right now.
  Then it keeps the old script as Sync-SapOrders.ps1.bak-<time>, copies the
  new one in, and runs it once with -DryRun (reads ERPNext and SAP, writes
  NOTHING), saving the output beside it. The orders it says it WOULD send to
  Manna Treads must all be approved ones.

  To undo: copy the .bak file back over Sync-SapOrders.ps1.

  Nothing secret is printed: config.json is read for order_flow only.

.PARAMETER Target      The live sync folder. Default C:\Users\eldhose\sap-order-sync
.PARAMETER SkipDryRun  Copy without the dry run (not recommended).
#>
param(
    [string] $Target = 'C:\Users\eldhose\sap-order-sync',
    [switch] $SkipDryRun
)
$ErrorActionPreference = 'Stop'

function Say([string] $m, [string] $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Stop-Here([string] $m) { Write-Host ''; Write-Host "STOPPED: $m" -ForegroundColor Red; Write-Host 'Nothing was changed.' -ForegroundColor Red; exit 1 }

$new = Join-Path $PSScriptRoot 'Sync-SapOrders.ps1'
$old = Join-Path $Target 'Sync-SapOrders.ps1'
$cfgPath = Join-Path $Target 'config.json'

Say "Live sync folder: $Target" 'Cyan'
if (-not (Test-Path $new)) { Stop-Here "Sync-SapOrders.ps1 is not next to this script ($PSScriptRoot)." }
if (-not (Test-Path $old)) { Stop-Here "No Sync-SapOrders.ps1 in $Target - is this the right folder?" }
if (-not (Test-Path $cfgPath)) { Stop-Here "No config.json in $Target." }

# --- 1. the new script really has the gate -----------------------------------
$newText = Get-Content $new -Raw
if ($newText -notmatch "RequireApproval -and \`$st -ne 'PO Approved - Ready for SAP'" -or
    $newText -notmatch 'if \(\$flow\.RequireApproval\) \{ \$mfFilter') {
    Stop-Here 'The new Sync-SapOrders.ps1 does not contain the approval gate. Wrong file?'
}
Say '1. New script carries the approval gate.' 'Green'

# --- 2. config does not switch it off ----------------------------------------
try { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json } catch { Stop-Here "config.json could not be read as JSON: $($_.Exception.Message)" }
$of = $cfg.order_flow
if ($null -eq $of) {
    Say '2. config.json has no order_flow: the Manna Treads route (PASS M) is off here.' 'Yellow'
} else {
    $mode = "$($of.mode)"
    $since = "$($of.since)"
    $rp = $of.PSObject.Properties['require_approval']
    if ($rp -and $null -ne $rp.Value) { $ra = "$($rp.Value)" } else { $ra = '(not set - means true)' }
    Say ("2. order_flow: mode={0} since={1} require_approval={2}" -f $mode, $since, $ra)
    if ($rp -and $null -ne $rp.Value -and -not [bool]$rp.Value) {
        Stop-Here ('config.json has "require_approval": false, which sends orders before approval. ' +
                   'Open config.json, delete that line (or set it to true), save, and run this again.')
    }
    Say '   The gate is on.' 'Green'
}

# --- 3. nothing running --------------------------------------------------------
$running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'Sync-SapOrders\.ps1' -and $_.ProcessId -ne $PID })
if ($running.Count -gt 0) { Stop-Here ("a sync is running now (process {0}). Wait for it to finish and run this again." -f (($running | ForEach-Object { $_.ProcessId }) -join ', ')) }
Say '3. No sync running.' 'Green'

# --- what is being replaced -----------------------------------------------------
$oldText = Get-Content $old -Raw
$oldHash = (Get-FileHash $old -Algorithm SHA256).Hash.Substring(0, 12)
$newHash = (Get-FileHash $new -Algorithm SHA256).Hash.Substring(0, 12)
if ($oldHash -eq $newHash) { Say 'The live script is already this version. Nothing to copy.' 'Green' }
else {
    if ($oldText -match 'require_approval') { $oldGate = 'has the approval gate' } else { $oldGate = 'has NO approval gate - this is why unapproved orders went to SAP' }
    Say ("   Live script: {0} bytes, sha {1}, modified {2:yyyy-MM-dd HH:mm}; it {3}." -f (Get-Item $old).Length, $oldHash, (Get-Item $old).LastWriteTime, $oldGate) 'Yellow'
    Say ("   New script : {0} bytes, sha {1}." -f (Get-Item $new).Length, $newHash)

    # --- 4. back up and copy ---------------------------------------------------
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bak = "$old.bak-$stamp"
    Copy-Item $old $bak
    Copy-Item $new $old -Force
    if ((Get-FileHash $old -Algorithm SHA256).Hash.Substring(0, 12) -ne $newHash) { Copy-Item $bak $old -Force; Stop-Here 'the copy did not verify; the old script was put back.' }
    Say "4. Copied. Old script kept as $bak" 'Green'
}

# --- 5. dry run ------------------------------------------------------------------
if ($SkipDryRun) { Say 'Dry run skipped (-SkipDryRun).' 'Yellow'; exit 0 }
$log = Join-Path $Target ("update-dryrun-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Say ''
Say "5. Dry run (writes nothing). Output: $log" 'Cyan'
Push-Location $Target
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $old -ConfigPath $cfgPath -DryRun *>&1 | Tee-Object -FilePath $log | Out-Null
    $code = $LASTEXITCODE
} finally { Pop-Location }

$lines = Get-Content $log
Say ''
Say '--- What the dry run says about Manna Treads (PASS M) ---' 'Cyan'
$lines | Select-String -Pattern 'new .* order\(s\) since .* without a Manna Treads order', 'PASS M .*WOULD POST /Orders', 'PASS M .*waits for approval', 'config:', 'FATAL', 'ERROR' |
    ForEach-Object { $_.Line.Substring(0, [Math]::Min(220, $_.Line.Length)) }
$would = @($lines | Select-String -Pattern 'PASS M (\S+): WOULD POST' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
Say ''
if ($would.Count -eq 0) { Say 'PASS M would send no order to Manna Treads SAP right now.' 'Green' }
else { Say ("PASS M WOULD send: {0} - check each is approved in ERPNext before the next real run." -f ($would -join ', ')) 'Yellow' }
Say ("Dry run exit code: {0} (0 = no failures). Full output in {1}" -f $code, $log)
