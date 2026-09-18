<#
.SYNOPSIS
  Sets SAP stock for the ten TEST TREAD items to a whole number of rolls, at
  nil value. Service Layer only.

.DESCRIPTION
  Create-DummyStock.ps1 put 500 kg of each test item into warehouse 07 when
  they were created. 500 kg is 25 rolls of TEST TREAD 01 - far more than a
  shelf, and an order can never be made to split against it. This brings each
  item to -Rolls rolls instead.

  It reaches a TARGET rather than adding a delta, so it is safe to re-run and
  the direction is worked out per item:

    OnHand > target  ->  InventoryGenExits   (Goods Issue)
    OnHand < target  ->  InventoryGenEntries (Goods Receipt)
    equal            ->  nothing

  NIL VALUE. Every line carries UnitPrice = 0, exactly as the original receipt
  did, so the issue takes out what the receipt put in at the same zero cost and
  no value reaches a P&L account. The items carry no price list row and no
  standard cost, which is what makes that true - see Seed-SapDummyItems.ps1.

  ONLY the ten items named in $TEST_ITEMS are touched. They share SAP item
  group 100 ("Items") with thirty unrelated items, so the group is deliberately
  NOT used to select them.

.PARAMETER ConfigPath  config.json (same file Sync-SapOrders.ps1 uses). Required.
.PARAMETER Rolls       Target rolls per item. Default 5.
.PARAMETER Warehouse   SAP warehouse. Default 07.
.PARAMETER DryRun      Print the plan and the documents, write nothing.

.EXAMPLE
  .\Set-SapTestStock.ps1 -ConfigPath .\config.json -DryRun
  .\Set-SapTestStock.ps1 -ConfigPath .\config.json -Rolls 5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ConfigPath,
    [int]    $Rolls     = 5,
    [string] $Warehouse = '07',
    [switch] $DryRun
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# Named one by one on purpose. Group 100 is "Items" and holds 40 items, only
# these ten of which are test data; selecting by group would move real stock.
$TEST_ITEMS = @('I-14636','I-14637','I-14638','I-14639','I-14640',
                'I-14641','I-14642','I-14643','I-14644','I-14645')

function Write-Log {
    param([ValidateSet('INFO', 'WARN', 'ERROR')][string] $Level = 'INFO', [Parameter(Mandatory = $true)][string] $Message)
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    switch ($Level) { 'ERROR' { Write-Host $line -ForegroundColor Red } 'WARN' { Write-Host $line -ForegroundColor Yellow } default { Write-Host $line } }
}
function Get-JsonProp { param($Object, [string] $Name) if ($null -eq $Object) { return $null } $p = $Object.PSObject.Properties[$Name]; if ($p) { return $p.Value }; return $null }

function Format-HttpError {
    param($ErrorRecord, [string] $Context)
    $status = $null
    try { if ($ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) { $status = [int]$ErrorRecord.Exception.Response.StatusCode } } catch { }
    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $body = $ErrorRecord.ErrorDetails.Message }
    elseif ($ErrorRecord.Exception -and $ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) {
        try { $s = $ErrorRecord.Exception.Response.GetResponseStream(); $r = New-Object System.IO.StreamReader($s); $body = $r.ReadToEnd(); $r.Close() } catch { }
    }
    $detail = $null
    if ($body) {
        try { $j = $body | ConvertFrom-Json; $e = Get-JsonProp $j 'error'
            if ($e) { $m = Get-JsonProp $e 'message'; if ($m) { $v = Get-JsonProp $m 'value'; $detail = if ($v) { "$v" } else { "$m" } } }
        } catch { $detail = "$body" }
    }
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }
    $detail = ($detail -replace '\s+', ' ').Trim()
    if ($status) { return "$Context [HTTP $status]: $detail" }
    return "${Context}: $detail"
}

function Enable-SapCertBypass {
    param([string] $SapHost)
    if (-not ([System.Management.Automation.PSTypeName]'SapCertBypass2').Type) {
        Add-Type @'
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SapCertBypass2 {
    public static string AllowedHost;
    public static void Enable(string host) {
        AllowedHost = host;
        ServicePointManager.ServerCertificateValidationCallback =
            delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
                if (errors == SslPolicyErrors.None) return true;
                HttpWebRequest req = sender as HttpWebRequest;
                return (req != null && string.Equals(req.RequestUri.Host, AllowedHost, StringComparison.OrdinalIgnoreCase));
            };
    }
}
'@
    }
    [SapCertBypass2]::Enable($SapHost)
}

# ---------------------------------------------------------------- config -------
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sap = $cfg.sap
$sapUrl   = "$($sap.url)".TrimEnd('/')
$sapHost  = ([System.Uri]$sapUrl).Host
$companyDb = "$($sap.company.company_db)"

# Empty-body 500 from the Service Layer on any POST carrying this header.
[System.Net.ServicePointManager]::Expect100Continue = $false
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}
$prevCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$verify = $true; $vp = $sap.PSObject.Properties['verify_ssl']; if ($vp) { $verify = [bool]$vp.Value }
if (-not $verify) { Enable-SapCertBypass -SapHost $sapHost; Write-Log WARN ("TLS cert validation bypassed for '{0}' only." -f $sapHost) }

if ($Rolls -lt 0) { throw "-Rolls cannot be negative." }

$sess = $null
try {
    # ------------------------------------------------------------- login -------
    $login = @{ CompanyDB = $companyDb; UserName = "$($sap.username)"; Password = "$($sap.password)" } | ConvertTo-Json -Compress
    $lr = Invoke-WebRequest -Method Post -Uri "$sapUrl/Login" -Body $login -ContentType 'application/json' -UseBasicParsing -SessionVariable sess -TimeoutSec 120
    $u = [System.Uri] $sapUrl
    $names = @(); try { $names = @($sess.Cookies.GetCookies($u) | ForEach-Object { $_.Name }) } catch { }
    if ($names -notcontains 'B1SESSION') {
        # The load balancer hands back ROUTEID in the jar and the session id in
        # the body; add it by hand or every following call is a 401.
        $sid = ($lr.Content | ConvertFrom-Json).SessionId
        $sess.Cookies.Add((New-Object System.Net.Cookie('B1SESSION', "$sid", '/', $u.Host)))
    }
    Write-Log INFO ("SAP login OK [{0}]." -f $companyDb)

    # ---------------------------------------------- read the current figure ----
    # Per WAREHOUSE, not the company-wide Items figure: the receipt went into
    # one warehouse and the issue has to come out of the same one.
    $plan = New-Object System.Collections.ArrayList
    foreach ($code in $TEST_ITEMS) {
        $rel = "Items('$code')?`$select=ItemCode,ItemName,U_WeightPerRoll,ItemWarehouseInfoCollection"
        $it  = Invoke-RestMethod -Method Get -Uri "$sapUrl/$rel" -WebSession $sess -TimeoutSec 180 -ErrorAction Stop
        $wpr = [double](Get-JsonProp $it 'U_WeightPerRoll')
        if ($wpr -le 0) { Write-Log WARN ("{0}: U_WeightPerRoll is {1} - cannot turn rolls into kilos, skipping." -f $code, $wpr); continue }

        $whs = @(Get-JsonProp $it 'ItemWarehouseInfoCollection') |
               Where-Object { "$(Get-JsonProp $_ 'WarehouseCode')" -eq $Warehouse } | Select-Object -First 1
        $onHand = if ($whs) { [double](Get-JsonProp $whs 'InStock') } else { 0.0 }

        $target = [double]($Rolls * $wpr)
        $delta  = [math]::Round($target - $onHand, 6)
        [void]$plan.Add([pscustomobject]@{
            ItemCode = $code
            PerRoll  = $wpr
            OnHand   = $onHand
            Target   = $target
            Delta    = $delta
        })
    }
    if ($plan.Count -eq 0) { throw "nothing to do: no test item had a usable U_WeightPerRoll." }

    Write-Log INFO ("target {0} roll(s) per item in warehouse {1}, nil value:" -f $Rolls, $Warehouse)
    foreach ($p in $plan) {
        $word = if ($p.Delta -gt 0) { "receive {0}" -f $p.Delta } elseif ($p.Delta -lt 0) { "issue {0}" -f [math]::Abs($p.Delta) } else { 'already right' }
        Write-Log INFO ("  {0,-10} on hand {1,8} -> {2,6} kg  ({3} x {4} kg/roll)   {5}" -f $p.ItemCode, $p.OnHand, $p.Target, $Rolls, $p.PerRoll, $word)
    }

    $issues   = @($plan | Where-Object { $_.Delta -lt 0 })
    $receipts = @($plan | Where-Object { $_.Delta -gt 0 })
    if ($issues.Count -eq 0 -and $receipts.Count -eq 0) { Write-Log INFO "every item is already at target - nothing to post."; return }

    function New-StockDoc {
        param([string] $Entity, $Rows, [string] $What)
        $lines = New-Object System.Collections.ArrayList
        foreach ($r in $Rows) {
            [void]$lines.Add([ordered]@{
                ItemCode      = $r.ItemCode
                Quantity      = [double][math]::Abs($r.Delta)
                WarehouseCode = $Warehouse
                UnitPrice     = 0            # nil value, deliberately
            })
        }
        $doc = [ordered]@{
            DocDate       = (Get-Date).ToString('yyyy-MM-dd')
            Comments      = "SYNC TEST - set test tread stock to $Rolls roll(s) - zero value"
            DocumentLines = @($lines)
        }
        if ($DryRun) {
            Write-Log INFO ("WOULD POST /{0} ({1}, {2} line(s)):`n{3}" -f $Entity, $What, $lines.Count, ($doc | ConvertTo-Json -Depth 8))
            return
        }
        $json = $doc | ConvertTo-Json -Depth 8
        try {
            $r = Invoke-RestMethod -Method Post -Uri "$sapUrl/$Entity" `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
                    -ContentType 'application/json; charset=utf-8' `
                    -WebSession $sess -TimeoutSec 300 -ErrorAction Stop
            Write-Log INFO ("{0}: DocNum {1} (DocEntry {2}), {3} line(s)." -f $What, (Get-JsonProp $r 'DocNum'), (Get-JsonProp $r 'DocEntry'), $lines.Count)
        } catch { throw (Format-HttpError $_ "SAP POST /$Entity ($What)") }
    }

    if ($issues.Count)   { New-StockDoc -Entity 'InventoryGenExits'   -Rows $issues   -What 'Goods Issue' }
    if ($receipts.Count) { New-StockDoc -Entity 'InventoryGenEntries' -Rows $receipts -What 'Goods Receipt' }

    if ($DryRun) { return }

    # ------------------------------------------------------------ verify -------
    Write-Log INFO "SAP after:"
    $bad = 0
    foreach ($p in $plan) {
        $rel = "Items('$($p.ItemCode)')?`$select=ItemCode,ItemWarehouseInfoCollection"
        $it  = Invoke-RestMethod -Method Get -Uri "$sapUrl/$rel" -WebSession $sess -TimeoutSec 180 -ErrorAction Stop
        $whs = @(Get-JsonProp $it 'ItemWarehouseInfoCollection') |
               Where-Object { "$(Get-JsonProp $_ 'WarehouseCode')" -eq $Warehouse } | Select-Object -First 1
        $now = if ($whs) { [double](Get-JsonProp $whs 'InStock') } else { 0.0 }
        $ok  = ([math]::Abs($now - $p.Target) -lt 0.001)
        if (-not $ok) { $bad++ }
        Write-Log INFO ("  {0,-10} {1,8} kg  = {2} roll(s)   {3}" -f $p.ItemCode, $now, [math]::Round($now / $p.PerRoll, 2), $(if ($ok) { 'as planned' } else { 'UNEXPECTED' }))
    }
    if ($bad) { Write-Log ERROR "$bad item(s) did not land on target."; exit 1 }
    Write-Log INFO ("done - {0} test item(s) at {1} roll(s) each, nil value." -f $plan.Count, $Rolls)
}
finally {
    if ($sess) { try { $null = Invoke-RestMethod -Method Post -Uri "$sapUrl/Logout" -WebSession $sess -TimeoutSec 60 -ErrorAction Stop; Write-Log INFO "SAP logout OK" } catch { Write-Log WARN "SAP logout failed." } }
    if ($PSVersionTable.PSVersion.Major -lt 6) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCb }
}
