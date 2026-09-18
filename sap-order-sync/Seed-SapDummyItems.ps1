<#
.SYNOPSIS
  Create N zero-value DUMMY items in SAP B1 (HITECH_PRETREADS_LIVE) + seed stock,
  for end-to-end testing of the ERPNext <-> SAP order sync. Test data only.

.DESCRIPTION
  Reuses Sync-SapOrders.ps1's proven Service Layer login (compiled host-scoped
  cert bypass + cookie jar + logout in finally).

  -Inspect : read-only. Prints a model OITM item, the current max I-<n> code,
             ItemGroups, Warehouses, and one existing Goods Receipt
             (InventoryGenEntries) so the create body can be modelled. Writes
             nothing.

  default  : ensure item group <GroupName> exists, then create <Count> items
             with sequential I-<n> codes after the current max, each:
               InventoryItem=tYES, SalesItem=tYES, PurchaseItem=tNO,
               no price list rows, U_BeltsPerRoll / U_WeightPerRoll set,
               ItemName "<NamePrefix> ## - SYNC TEST - DO NOT USE".
             Then one InventoryGenEntries (Goods Receipt) putting <StockQty>
             of each into <WarehouseCode> at UnitPrice 0.
             -DryRun prints every POST body and writes nothing.
             Item #1 is created and read back before the rest (unless -DryRun).

.PARAMETER ConfigPath   config.json (same file Sync-SapOrders.ps1 uses). Required.
.PARAMETER Inspect      Read-only inspection, then exit.
.PARAMETER DryRun       Print POST bodies, write nothing.
.PARAMETER Count        How many items (default 10).
.PARAMETER GroupName    SAP item group for the dummies (default 'ZZ - Test').
.PARAMETER NamePrefix   ItemName prefix (default 'TEST TREAD').
.PARAMETER WarehouseCode  Warehouse to receipt stock into. Required unless -Inspect.
.PARAMETER StockQty     Qty of each item to receipt (default 500).
.PARAMETER StartAfter   Force the numeric part to start after this (default: read max I-<n>).

.EXAMPLE
  .\Seed-SapDummyItems.ps1 -ConfigPath .\config.json -Inspect
.EXAMPLE
  .\Seed-SapDummyItems.ps1 -ConfigPath .\config.json -WarehouseCode 01 -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ConfigPath,
    [switch] $Inspect,
    [switch] $DryRun,
    [int]    $Count = 10,
    [string] $GroupName = 'ZZ - Test',
    [string] $NamePrefix = 'TEST TREAD',
    [string] $WarehouseCode,
    [int]    $StockQty = 500,
    [int]    $StartAfter = 0
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# Dummy belt/weight values, index 0..9 (extended if -Count > 10).
$BELTS  = @(3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
$WEIGHT = @(20, 24, 28, 32, 36, 40, 44, 48, 52, 56)

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
            if ($e) { $m = Get-JsonProp $e 'message'; if ($m) { $v = Get-JsonProp $m 'value'; $detail = if ($v) { "$v" } else { "$m" } }
                $c = Get-JsonProp $e 'code'; if ($detail -and $null -ne $c) { $detail = "$detail (code $c)" } }
        } catch { $detail = "$body" }
    }
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }
    $detail = ($detail -replace '\s+', ' ').Trim()
    if ($status) { return "$Context [HTTP $status]: $detail" }
    return "${Context}: $detail"
}

function Enable-SapCertBypass {
    param([string] $SapHost)
    if (-not ([System.Management.Automation.PSTypeName]'SapCertBypass').Type) {
        Add-Type @'
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SapCertBypass {
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
    [SapCertBypass]::Enable($SapHost)
}

function New-SapWebSession {
    param([string] $BaseUrl, [string] $Username, [string] $Password, [string] $CompanyDb)
    $u = [System.Uri] $BaseUrl
    $splat = @{
        Method = 'Post'; Uri = "$BaseUrl/Login"
        Body = (@{ CompanyDB = $CompanyDb; UserName = $Username; Password = $Password } | ConvertTo-Json -Compress)
        ContentType = 'application/json'; UseBasicParsing = $true
        SessionVariable = 'sess'; ErrorAction = 'Stop'; TimeoutSec = 120
    }
    $resp = $null
    for ($try = 1; $try -le 4; $try++) {
        try { $resp = Invoke-WebRequest @splat; break }
        catch {
            $code = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
            $retryable = ($code -eq 500 -or $code -eq 502 -or $code -eq 503 -or $code -eq 504 -or $null -eq $code)
            if (-not $retryable -or $try -eq 4) { throw (Format-HttpError $_ "SAP Login [$CompanyDb] (attempt $try/4)") }
            $wait = 5 * $try
            Write-Log WARN ("SAP login attempt {0}/4 failed (HTTP {1}); retry in {2}s" -f $try, $(if ($null -eq $code) { 'no response' } else { "$code" }), $wait)
            Start-Sleep -Seconds $wait
        }
    }
    $names = @()
    try { $names = @($sess.Cookies.GetCookies($u) | ForEach-Object { $_.Name }) } catch { }
    if ($names -notcontains 'B1SESSION') { throw "SAP Login [$CompanyDb]: no B1SESSION cookie." }
    Write-Log INFO ("SAP login OK [{0}] (cookies: {1})" -f $CompanyDb, ($names -join ','))
    return $sess
}

function Invoke-SapLogout {
    param([string] $BaseUrl, $Session)
    if (-not $Session) { return }
    try { $null = Invoke-RestMethod -Method Post -Uri "$BaseUrl/Logout" -WebSession $Session -TimeoutSec 60 -ErrorAction Stop; Write-Log INFO "SAP logout OK" }
    catch { Write-Log WARN ("SAP logout failed: {0}" -f $_.Exception.Message) }
}

function Invoke-SapGet {
    param([string] $BaseUrl, $Session, [string] $RelUrl, [string] $Label)
    $rows = New-Object System.Collections.ArrayList
    $next = "$BaseUrl/$RelUrl"
    while ($next) {
        try { $resp = Invoke-RestMethod -Method Get -Uri $next -Headers @{ Prefer = 'odata.maxpagesize=200' } -WebSession $Session -TimeoutSec 180 -ErrorAction Stop }
        catch { throw (Format-HttpError $_ "SAP GET $Label") }
        if ($resp -and $resp.PSObject.Properties['value']) { foreach ($r in @($resp.value)) { [void]$rows.Add($r) } }
        else { [void]$rows.Add($resp) }
        $link = Get-JsonProp $resp 'odata.nextLink'; if (-not $link) { $link = Get-JsonProp $resp '@odata.nextLink' }
        if ($link) { $link = "$link"; if ($link -match '^https?://') { $next = $link } elseif ($link.StartsWith('/')) { $uu = [System.Uri]$BaseUrl; $next = ('{0}://{1}{2}' -f $uu.Scheme, $uu.Authority, $link) } else { $next = "$BaseUrl/$link" } }
        else { $next = $null }
    }
    return $rows
}

function Invoke-SapPost {
    param([string] $BaseUrl, $Session, [string] $Entity, $Payload, [string] $Label)
    try { return Invoke-RestMethod -Method Post -Uri "$BaseUrl/$Entity" -Body ($Payload | ConvertTo-Json -Depth 8) -ContentType 'application/json' -WebSession $Session -TimeoutSec 180 -ErrorAction Stop }
    catch { throw (Format-HttpError $_ "SAP POST /$Entity ($Label)") }
}

# ---------------------------------------------------------------- config -------
$cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sap = $cfg.sap
$sapUrl = "$($sap.url)".TrimEnd('/')
$sapHost = ([System.Uri]$sapUrl).Host
$companyDb = "$($sap.company.company_db)"

if (-not $Inspect -and -not $WarehouseCode) { throw "-WarehouseCode is required unless -Inspect (run -Inspect first to see the codes)." }
if ($Count -gt $BELTS.Count) { throw "Count $Count > built-in dummy value table ($($BELTS.Count)). Extend `$BELTS/`$WEIGHT." }

# Empty-body 500 from the Service Layer on any POST carrying this header.
# Must precede the first request; it is read only at ServicePoint creation.
[System.Net.ServicePointManager]::Expect100Continue = $false
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls
}
$prevCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$verify = $true; $vp = $sap.PSObject.Properties['verify_ssl']; if ($vp) { $verify = [bool]$vp.Value }
if (-not $verify) { Enable-SapCertBypass -SapHost $sapHost; Write-Log WARN ("TLS cert validation bypassed for '{0}' only." -f $sapHost) }

$sess = $null
try {
    $sess = New-SapWebSession -BaseUrl $sapUrl -Username $sap.username -Password $sap.password -CompanyDb $companyDb

    # ---- current max I-<n> ----
    $maxN = $StartAfter
    $topI = Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "Items?`$select=ItemCode&`$filter=startswith(ItemCode,'I-')&`$orderby=ItemCode desc&`$top=20" -Label 'top I- codes'
    $nums = @()
    foreach ($r in $topI) { if ("$($r.ItemCode)" -match '^I-(\d+)$') { $nums += [int]$Matches[1] } }
    if ($nums.Count) { $obs = ($nums | Measure-Object -Maximum).Maximum; if ($obs -gt $maxN) { $maxN = $obs } }
    Write-Log INFO ("max I-<n> observed: I-$maxN   (top codes: $(($topI | ForEach-Object { $_.ItemCode }) -join ', '))")

    if ($Inspect) {
        Write-Log INFO '--- model item I-11688 ---'
        $m = Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "Items('I-11688')" -Label 'model item'
        $m = $m[0]
        foreach ($p in 'ItemCode', 'ItemName', 'ItemsGroupCode', 'ItemType', 'InventoryItem', 'SalesItem', 'PurchaseItem', 'GLMethod', 'InventoryUOM', 'DefaultWarehouse', 'U_BeltsPerRoll', 'U_WeightPerRoll', 'Valid', 'Frozen') {
            Write-Host ("  {0,-18}= {1}" -f $p, (Get-JsonProp $m $p))
        }
        Write-Host '  -- cost/valuation-ish props --'
        $m.PSObject.Properties | Where-Object { $_.Name -match 'Cost|Valuat|Method|Serie' } | ForEach-Object { Write-Host ("  {0,-24}= {1}" -f $_.Name, $_.Value) }
        Write-Host '  -- model item warehouse rows (first 8) --'
        @($m.ItemWarehouseInfoCollection) | Select-Object -First 8 | ForEach-Object { Write-Host ("    {0,-10} InStock={1}" -f $_.WarehouseCode, $_.InStock) }

        Write-Log INFO '--- ItemGroups ---'
        (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "ItemGroups?`$select=Number,GroupName" -Label 'ItemGroups') | ForEach-Object { Write-Host ("  {0,-5} {1}" -f $_.Number, $_.GroupName) }

        Write-Log INFO '--- Warehouses ---'
        (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "Warehouses?`$select=WarehouseCode,WarehouseName" -Label 'Warehouses') | ForEach-Object { Write-Host ("  {0,-10} {1}" -f $_.WarehouseCode, $_.WarehouseName) }

        Write-Log INFO '--- one recent InventoryGenEntries (Goods Receipt) ---'
        $gr = Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "InventoryGenEntries?`$orderby=DocEntry desc&`$top=1" -Label 'InventoryGenEntries'
        if (@($gr).Count) { ($gr[0] | ConvertTo-Json -Depth 4) } else { Write-Host '  (none found)' }

        Write-Log INFO ("--- would use codes: I-{0} .. I-{1} ---" -f ($maxN + 1), ($maxN + $Count))
        return
    }

    # ---- ensure item group ----
    $grps = Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "ItemGroups?`$select=Number,GroupName" -Label 'ItemGroups'
    $grp = $grps | Where-Object { "$($_.GroupName)" -eq $GroupName } | Select-Object -First 1
    if ($grp) {
        $groupCode = [int]$grp.Number
        Write-Log INFO ("item group '{0}' exists (Number {1})" -f $GroupName, $groupCode)
    }
    else {
        if ($DryRun) { Write-Log INFO ("WOULD POST /ItemGroups {{ GroupName = '{0}' }}" -f $GroupName); $groupCode = -1 }
        else {
            $g = Invoke-SapPost -BaseUrl $sapUrl -Session $sess -Entity 'ItemGroups' -Payload @{ GroupName = $GroupName } -Label 'create group'
            $groupCode = [int]$g.Number
            Write-Log INFO ("created item group '{0}' (Number {1})" -f $GroupName, $groupCode)
        }
    }

    # ---- create items ----
    $created = @()
    for ($k = 0; $k -lt $Count; $k++) {
        $n = $maxN + 1 + $k
        $code = "I-$n"
        $nn = '{0:D2}' -f ($k + 1)
        $payload = [ordered]@{
            ItemCode      = $code
            ItemName      = ("{0} {1} - SYNC TEST - DO NOT USE" -f $NamePrefix, $nn)
            ItemsGroupCode = $groupCode
            ItemType      = 'itItems'
            InventoryItem = 'tYES'
            SalesItem     = 'tYES'
            PurchaseItem  = 'tNO'
            InventoryUOM  = 'KGS'
            U_BeltsPerRoll  = $BELTS[$k]
            U_WeightPerRoll = $WEIGHT[$k]
        }
        if ($DryRun) {
            Write-Log INFO ("WOULD POST /Items:`n{0}" -f ($payload | ConvertTo-Json -Depth 6))
            $created += $code
            continue
        }
        $r = Invoke-SapPost -BaseUrl $sapUrl -Session $sess -Entity 'Items' -Payload $payload -Label "create $code"
        Write-Log INFO ("created {0}  '{1}'  belts={2} weight={3}" -f $r.ItemCode, $r.ItemName, $r.U_BeltsPerRoll, $r.U_WeightPerRoll)
        $created += $code
        if ($k -eq 0) {
            $chk = Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "Items('$code')" -Label 'read-back item 1'
            Write-Log INFO ("read-back OK: {0} group={1} inv={2} sales={3} purch={4}" -f $chk[0].ItemCode, $chk[0].ItemsGroupCode, $chk[0].InventoryItem, $chk[0].SalesItem, $chk[0].PurchaseItem)
        }
    }

    # ---- seed stock: one Goods Receipt ----
    $lines = New-Object System.Collections.ArrayList
    foreach ($c in $created) { [void]$lines.Add(@{ ItemCode = $c; Quantity = $StockQty; WarehouseCode = $WarehouseCode; UnitPrice = 0 }) }
    $gr = [ordered]@{ DocDate = (Get-Date).ToString('yyyy-MM-dd'); Comments = 'SYNC TEST dummy stock - zero value'; DocumentLines = $lines }
    if ($DryRun) {
        Write-Log INFO ("WOULD POST /InventoryGenEntries:`n{0}" -f ($gr | ConvertTo-Json -Depth 6))
    }
    else {
        $r = Invoke-SapPost -BaseUrl $sapUrl -Session $sess -Entity 'InventoryGenEntries' -Payload $gr -Label 'goods receipt'
        Write-Log INFO ("Goods Receipt DocNum {0} (DocEntry {1}) - {2} line(s) x {3} into {4}" -f $r.DocNum, $r.DocEntry, @($created).Count, $StockQty, $WarehouseCode)
    }

    Write-Log INFO ("DONE. Items: {0}" -f ($created -join ', '))
}
finally {
    Invoke-SapLogout -BaseUrl $sapUrl -Session $sess
    if ($PSVersionTable.PSVersion.Major -lt 6) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCb }
}
