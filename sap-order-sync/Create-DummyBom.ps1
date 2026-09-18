<#
.SYNOPSIS
  Create a zero-value dummy component item + stock + a production BOM for each
  of the I-146xx dummy FG test items, so a Production Order can be raised
  against them without touching real items or posting real-value journals.

.DESCRIPTION
  Reuses Sync-SapOrders.ps1's proven Service Layer login (compiled host-scoped
  cert bypass + cookie jar + logout in finally).

  -Inspect : read-only. Prints current stock on the FG test items, the next
             free I-<n> code, warehouses, and one existing BillOfMaterials (if
             any) to confirm the field shape. Writes nothing.

  default  : 1. create ONE dummy component item (zero cost, no price list)
             2. Goods Receipt: component stock + FG item stock (skips any FG
                item that already has stock) at UnitPrice 0
             3. create BOM #1 (first FG item), read it back to confirm the
                shape, then the remaining 9 - one BillOfMaterials per FG item,
                Type botProduction, one line = the dummy component, 1:1 qty.
             -DryRun prints every POST body and writes nothing.

.PARAMETER ConfigPath     config.json (same file Sync-SapOrders.ps1 uses). Required.
.PARAMETER Inspect        Read-only inspection, then exit.
.PARAMETER DryRun         Print POST bodies, write nothing.
.PARAMETER WarehouseCode  Warehouse for component + FG stock and the BOM. Required unless -Inspect.
.PARAMETER ComponentStockQty  Qty of the component to receipt (default 5000).
.PARAMETER FgStockQty     Qty of each FG item to receipt if it has none yet (default 500).
.PARAMETER FgItems        FG item codes to build a BOM for (default I-14636..I-14645).

.EXAMPLE
  .\Create-DummyBom.ps1 -ConfigPath .\config.json -Inspect
.EXAMPLE
  .\Create-DummyBom.ps1 -ConfigPath .\config.json -WarehouseCode 01 -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ConfigPath,
    [switch] $Inspect,
    [switch] $DryRun,
    [string] $WarehouseCode,
    [int]    $ComponentStockQty = 5000,
    [int]    $FgStockQty = 500,
    [string[]] $FgItems = @('I-14636','I-14637','I-14638','I-14639','I-14640','I-14641','I-14642','I-14643','I-14644','I-14645')
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

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

    if ($Inspect) {
        Write-Log INFO '--- FG test item stock ---'
        foreach ($code in $FgItems) {
            $it = (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "Items('$code')" -Label "item $code")[0]
            $rows = @($it.ItemWarehouseInfoCollection) | Where-Object { [double]$_.InStock -gt 0 }
            if ($rows.Count) { $rows | ForEach-Object { Write-Host ("  {0}  wh={1}  InStock={2}" -f $code, $_.WarehouseCode, $_.InStock) } }
            else { Write-Host ("  {0}  (no stock)" -f $code) }
        }
        Write-Log INFO '--- next free I-<n> ---'
        $topI = Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "Items?`$select=ItemCode&`$filter=startswith(ItemCode,'I-')&`$orderby=ItemCode desc&`$top=5" -Label 'top I- codes'
        $nums = @(); foreach ($r in $topI) { if ("$($r.ItemCode)" -match '^I-(\d+)$') { $nums += [int]$Matches[1] } }
        $maxN = if ($nums.Count) { ($nums | Measure-Object -Maximum).Maximum } else { 0 }
        Write-Host ("  max observed I-$maxN -> next free I-$($maxN + 1)")

        Write-Log INFO '--- Warehouses ---'
        (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "Warehouses?`$select=WarehouseCode,WarehouseName" -Label 'Warehouses') | ForEach-Object { Write-Host ("  {0,-10} {1}" -f $_.WarehouseCode, $_.WarehouseName) }

        Write-Log INFO '--- one existing BillOfMaterials (if any) ---'
        try {
            $bom = Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "BillOfMaterials?`$top=1" -Label 'BillOfMaterials'
            if (@($bom).Count) { ($bom[0] | ConvertTo-Json -Depth 6) } else { Write-Host '  (none found - proceeding on standard SL schema)' }
        } catch { Write-Host ("  probe error (non-fatal): {0}" -f $_.Exception.Message) }
        return
    }

    # ---- next free I-<n> for the dummy component ----
    $topI = Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "Items?`$select=ItemCode&`$filter=startswith(ItemCode,'I-')&`$orderby=ItemCode desc&`$top=5" -Label 'top I- codes'
    $nums = @(); foreach ($r in $topI) { if ("$($r.ItemCode)" -match '^I-(\d+)$') { $nums += [int]$Matches[1] } }
    $maxN = if ($nums.Count) { ($nums | Measure-Object -Maximum).Maximum } else { 0 }
    $componentCode = "I-$($maxN + 1)"
    Write-Log INFO ("dummy component code: {0}" -f $componentCode)

    # ---- 1. create the dummy component item ----
    $compPayload = [ordered]@{
        ItemCode      = $componentCode
        ItemName      = 'DUMMY COMPONENT - SYNC TEST - DO NOT USE'
        ItemsGroupCode = 100
        ItemType      = 'itItems'
        InventoryItem = 'tYES'
        SalesItem     = 'tNO'
        PurchaseItem  = 'tYES'
        InventoryUOM  = 'KGS'
    }
    if ($DryRun) { Write-Log INFO ("WOULD POST /Items:`n{0}" -f ($compPayload | ConvertTo-Json -Depth 6)) }
    else {
        $r = Invoke-SapPost -BaseUrl $sapUrl -Session $sess -Entity 'Items' -Payload $compPayload -Label "create $componentCode"
        Write-Log INFO ("created component {0} '{1}'" -f $r.ItemCode, $r.ItemName)
    }

    # ---- 2. Goods Receipt: component + any FG item with no stock yet ----
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add(@{ ItemCode = $componentCode; Quantity = $ComponentStockQty; WarehouseCode = $WarehouseCode; UnitPrice = 0 })
    foreach ($code in $FgItems) {
        $hasStock = $false
        if (-not $DryRun) {
            $it = (Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "Items('$code')" -Label "check stock $code")[0]
            $hasStock = [bool](@($it.ItemWarehouseInfoCollection) | Where-Object { [double]$_.InStock -gt 0 })
        }
        if (-not $hasStock) { [void]$lines.Add(@{ ItemCode = $code; Quantity = $FgStockQty; WarehouseCode = $WarehouseCode; UnitPrice = 0 }) }
        else { Write-Log INFO ("{0} already has stock - skipping in the receipt." -f $code) }
    }
    $gr = [ordered]@{ DocDate = (Get-Date).ToString('yyyy-MM-dd'); Comments = 'SYNC TEST dummy stock - zero value'; DocumentLines = $lines }
    if ($DryRun) { Write-Log INFO ("WOULD POST /InventoryGenEntries:`n{0}" -f ($gr | ConvertTo-Json -Depth 6)) }
    else {
        $r = Invoke-SapPost -BaseUrl $sapUrl -Session $sess -Entity 'InventoryGenEntries' -Payload $gr -Label 'goods receipt'
        Write-Log INFO ("Goods Receipt DocNum {0} - {1} line(s) into {2}" -f $r.DocNum, @($lines).Count, $WarehouseCode)
    }

    # ---- 3. BOM per FG item ----
    $bomOk = 0
    for ($i = 0; $i -lt $FgItems.Count; $i++) {
        $fg = $FgItems[$i]
        $bomPayload = [ordered]@{
            ItemCode      = $fg
            Warehouse     = $WarehouseCode
            Type          = 'botProduction'
            Quantity      = 1
            BillOfMaterialsLines = @(
                @{ ItemCode = $componentCode; Warehouse = $WarehouseCode; Quantity = 1 }
            )
        }
        if ($DryRun) {
            Write-Log INFO ("WOULD POST /BillOfMaterials for {0}:`n{1}" -f $fg, ($bomPayload | ConvertTo-Json -Depth 6))
            continue
        }
        try {
            $r = Invoke-SapPost -BaseUrl $sapUrl -Session $sess -Entity 'BillOfMaterials' -Payload $bomPayload -Label "BOM $fg"
            Write-Log INFO ("BOM created for {0} (component {1})" -f $fg, $componentCode)
            $bomOk++
            if ($i -eq 0) {
                $chk = Invoke-SapGet -BaseUrl $sapUrl -Session $sess -RelUrl "BillOfMaterials('$fg')" -Label 'read-back BOM 1'
                Write-Log INFO ("read-back OK: ItemCode={0} Type={1} lines={2}" -f $chk[0].ItemCode, $chk[0].Type, @($chk[0].BillOfMaterialsLines).Count)
            }
        } catch {
            Write-Log ERROR ("BOM for {0} FAILED: {1}" -f $fg, $_.Exception.Message)
        }
    }
    if (-not $DryRun) { Write-Log INFO ("DONE. {0}/{1} BOM(s) created, component {2}." -f $bomOk, $FgItems.Count, $componentCode) }
}
finally {
    Invoke-SapLogout -BaseUrl $sapUrl -Session $sess
    if ($PSVersionTable.PSVersion.Major -lt 6) { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCb }
}
