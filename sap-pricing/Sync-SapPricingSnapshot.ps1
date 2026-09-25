<#
.SYNOPSIS
  Copy Manna Treads' quality-wise prices, and Hi-Tech Pretreads' prices for the
  same items, out of SAP into ERPNext for the Managing Director's rates screen -
  and check them. Reads SAP only; never writes to it.

.DESCRIPTION
  Service Layer GETs only, then one PUT to the ERPNext Single "SAP Pricing
  Control", field snapshot_json. The rates screen computes every proposed
  change from this snapshot and hands the MD DTW files; SAP itself is changed
  only by those files, imported in DTW. Decided 25 Sep 2026: price changes must
  not go through the Service Layer.

  Also decided 25 Sep 2026: the dealers are Manna Treads' customers, so their
  prices live in MANNA_TREADS_LIVE, and Hi-Tech bills Manna Treads a fixed
  number of rupees per kg below Manna Treads' own price - so Hi-Tech's Price
  List 01 follows Manna Treads' Price List 01 item by item. Every price is
  GST-inclusive as it stands; nothing here adds or removes GST.

  What is copied (snapshot version 3):
    properties   the qualities: Manna Treads' NAMED item properties. A property
                 still unnamed in Manna Treads ("Items Property N") takes
                 Hi-Tech's name for the same number, marked nameFrom = Hi-Tech,
                 so the screen can say it still needs naming.
    items        every valid Manna Treads item with one of those properties
                 ticked: code, name, group, type (PRECURED / HOT / BONDING GUM,
                 from the name by Get-ItemKind - Manna Treads has no
                 U_ProductType; prices move per type x quality), quality (U_SubTypeA), UoM,
                 stock, last change, Price List 01 price - and its twin.
    twin         the Hi-Tech item with the SAME CODE AND THE SAME NAME. The same
                 code alone is not enough: of 1,119 Manna Treads treads only one
                 shares its code with Hi-Tech, and I-12279 is a different tread
                 in each company. Belts and kg per roll come from the twin.
    customers    every Manna Treads customer: code, name, group, price list
    special      every Manna Treads special price, as compact rows
    hitech       the twins as Hi-Tech holds them: Price List 01 price, stock
    serverCheck  this server's own check of SAP against the saved rules and the
                 margin (RupeeRules.ps1), which the screen compares with its own

  Reads from ERPNext first: SAP Dealer Rate Rule (the rules) and SAP Pricing
  Control.intercompany_margin - kept there, not in this code, because this
  repository is public.

  Run by Invoke-SapPricingPoller.ps1 when the MD presses Sync; by hand:
    .\Sync-SapPricingSnapshot.ps1 -ConfigPath C:\Users\eldhose\sap-pricing-sync\poller.config.json -DryRun

.PARAMETER ConfigPath      poller.config.json: erpnext_site, bot_api_key, bot_api_secret,
                           control_doctype, sap_config (a sync config.json holding the SAP block)
.PARAMETER DryRun          Read SAP and ERPNext, write the snapshot to a local file only.
.PARAMETER ResultJsonPath  Run summary for the poller.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ConfigPath,
    [switch] $DryRun,
    [string] $ResultJsonPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SapSession.ps1')
. (Join-Path $PSScriptRoot 'RupeeRules.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::Expect100Continue = $false

$TreadsDb = 'MANNA_TREADS_LIVE'
$HitechDb = 'HITECH_PRETREADS_LIVE'
$PriceList = 1        # both companies: Manna Treads' "selling price", Hi-Tech's "Price List 01"
$RuleDoctype = 'SAP Dealer Rate Rule'
$result = [ordered]@{ exitCode = 1; changed = 0; failures = 0; items = 0; twins = 0; specialPrices = 0; customers = 0; summary = $null; error = $null }
function Write-Result { if ($ResultJsonPath) { [IO.File]::WriteAllText($ResultJsonPath, ($result | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false))) } }
function Norm([string] $n) { return (($n -replace '\s+', ' ').Trim()).ToUpperInvariant() }
function Join-SapOr([string] $field, [string[]] $values) { return (($values | ForEach-Object { "$field eq '$($_ -replace "'", "''")'" }) -join ' or ') }
function Get-Date10($v) { $t = "$v"; return $t.Substring(0, [Math]::Min(10, $t.Length)) }

try {
    $cfg = [IO.File]::ReadAllText($ConfigPath).TrimStart([char]0xFEFF) | ConvertFrom-Json
    foreach ($k in 'erpnext_site', 'bot_api_key', 'bot_api_secret', 'control_doctype', 'sap_config') {
        if (-not "$($cfg.$k)".Trim()) { throw "config '$k' is missing in $ConfigPath" }
    }
    $site = "$($cfg.erpnext_site)".TrimEnd('/')
    $erpHeaders = @{ Authorization = "token $($cfg.bot_api_key):$($cfg.bot_api_secret)" }
    $ctl = [uri]::EscapeDataString("$($cfg.control_doctype)")

    # ---- ERPNext: the rules and the margin the check is made against ----
    $q = '?fields=' + [uri]::EscapeDataString('["card_code","property_no","rupees_off"]') + '&limit_page_length=0'
    $ruleRows = @((Invoke-RestMethod -Method Get -Uri "$site/api/resource/$([uri]::EscapeDataString($RuleDoctype))$q" -Headers $erpHeaders -TimeoutSec 60).data)
    $rules = @(foreach ($r in $ruleRows) { [pscustomobject]@{ CardCode = "$($r.card_code)"; Property = [int]$r.property_no; Rupees = [double]$r.rupees_off } })
    $margin = [double]((Invoke-RestMethod -Method Get -Uri "$site/api/resource/$ctl/$ctl" -Headers $erpHeaders -TimeoutSec 60).data.intercompany_margin)

    # ---- Hi-Tech, first: its property names, for any still unnamed in Manna Treads ----
    $h = New-SapSession -ConfigPath $cfg.sap_config -CompanyDb $HitechDb
    try {
        $hiNames = @{}
        foreach ($p in @(Get-SapAll $h 'ItemProperties?$select=Number,PropertyName')) {
            if ("$($p.PropertyName)" -notmatch '^Items Property \d+$') { $hiNames[[int]$p.Number] = "$($p.PropertyName)" }
        }
        $hiPlName = "$((Get-SapOne $h "PriceLists($PriceList)?`$select=PriceListNo,PriceListName").PriceListName)"
    }
    finally { Close-SapSession $h }

    # ---- Manna Treads: the master ----
    $t = New-SapSession -ConfigPath $cfg.sap_config -CompanyDb $TreadsDb
    try {
        $treadsProps = @(Get-SapAll $t 'ItemProperties?$select=Number,PropertyName' | Sort-Object { [int]$_.Number })
        $props = @(foreach ($p in $treadsProps) {
            $n = [int]$p.Number
            if ("$($p.PropertyName)" -notmatch '^Items Property \d+$') { [ordered]@{ no = $n; name = "$($p.PropertyName)" } }
            elseif ($hiNames.ContainsKey($n)) { [ordered]@{ no = $n; name = $hiNames[$n]; nameFrom = 'Hi-Tech' } }
        })
        $groups = @{}; foreach ($g in @(Get-SapAll $t 'ItemGroups?$select=Number,GroupName')) { $groups["$($g.Number)"] = "$($g.GroupName)" }
        $plName = "$((Get-SapOne $t "PriceLists($PriceList)?`$select=PriceListNo,PriceListName").PriceListName)"

        $raw = @()
        if ($props.Count) {
            $pSel = ($props | ForEach-Object { "Properties$($_.no)" }) -join ','
            $pFlt = ($props | ForEach-Object { "Properties$($_.no) eq 'tYES'" }) -join ' or '
            $sel = "ItemCode,ItemName,ItemsGroupCode,SalesItem,Frozen,InventoryUOM,SalesUnit,U_SubTypeA,UpdateDate,QuantityOnStock,ItemPrices,$pSel"
            $raw = @(Get-SapAll $t "Items?`$select=$sel&`$filter=($pFlt) and Valid eq 'tYES'")
        }

        $bpGroups = @{}; foreach ($g in @(Get-SapAll $t 'BusinessPartnerGroups?$select=Code,Name')) { $bpGroups["$($g.Code)"] = "$($g.Name)" }
        $customers = @(foreach ($b in @(Get-SapAll $t "BusinessPartners?`$select=CardCode,CardName,GroupCode,PriceListNum,Valid,Frozen&`$filter=CardType eq 'cCustomer'")) {
            [ordered]@{
                code = "$($b.CardCode)"; name = "$($b.CardName)"; group = $bpGroups["$($b.GroupCode)"]
                priceList = [int]$b.PriceListNum; active = ("$($b.Valid)" -eq 'tYES' -and "$($b.Frozen)" -ne 'tYES')
            }
        })
        # Compact rows, not objects: dealers x items grows fast (50 dealers on
        # 1,800 items is 90,000 prices, 11 MB as objects), and the rates screen
        # downloads the whole snapshot each time it opens. Columns in specialCols.
        $special = New-Object System.Collections.Generic.List[object]
        $specialBy = @{}
        foreach ($x in @(Get-SapAll $t 'SpecialPrices?$select=ItemCode,CardCode,Price,Currency,DiscountPercent,PriceListNum,AutoUpdate,Valid')) {
            $special.Add(@(
                "$($x.CardCode)", "$($x.ItemCode)", [double]$x.Price, [int]$x.PriceListNum,
                $(if ("$($x.AutoUpdate)" -eq 'tYES') { 1 } else { 0 }), [double]$x.DiscountPercent,
                $(if ("$($x.Valid)" -eq 'tNO') { 0 } else { 1 }), "$($x.Currency)"
            ))
            $specialBy["$($x.CardCode)|$($x.ItemCode)"] = [pscustomobject]@{ Price = [double]$x.Price; PriceListNum = [int]$x.PriceListNum }
        }
    }
    finally { Close-SapSession $t }

    # ---- Hi-Tech again: the twins ----
    $hiItems = @{}
    $codes = @($raw | ForEach-Object { "$($_.ItemCode)" } | Sort-Object -Unique)
    if ($codes.Count) {
        $h = New-SapSession -ConfigPath $cfg.sap_config -CompanyDb $HitechDb
        try {
            for ($i = 0; $i -lt $codes.Count; $i += 40) {
                $chunk = $codes[$i..([Math]::Min($i + 39, $codes.Count - 1))]
                foreach ($x in @(Get-SapAll $h ("Items?`$select=ItemCode,ItemName,Valid,Frozen,SalesItem,UpdateDate,QuantityOnStock,U_BeltsPerRoll,U_WeightPerRoll,ItemPrices&`$filter=" + (Join-SapOr 'ItemCode' $chunk)))) {
                    $hiItems["$($x.ItemCode)"] = $x
                }
            }
        }
        finally { Close-SapSession $h }
    }

    $hitech = New-Object System.Collections.Generic.List[object]
    $hitechPrice = @{}
    $items = @(foreach ($it in $raw) {
        $code = "$($it.ItemCode)"; $name = "$($it.ItemName)"
        $lp = @($it.ItemPrices | Where-Object { [int]$_.PriceList -eq $PriceList })[0]
        $twin = $null; $note = $null; $belts = $null; $kg = $null
        $hx = $hiItems[$code]
        if ($hx) {
            if ((Norm "$($hx.ItemName)") -ne (Norm $name)) { $note = "Hi-Tech's $code is a different item: $($hx.ItemName)" }
            elseif ("$($hx.Valid)" -ne 'tYES') { $note = "Hi-Tech's $code is inactive" }
            else {
                $twin = $code; $belts = $hx.U_BeltsPerRoll; $kg = $hx.U_WeightPerRoll
                $hp = @($hx.ItemPrices | Where-Object { [int]$_.PriceList -eq $PriceList })[0]
                $hprice = if ($hp -and [double]$hp.Price -gt 0) { [double]$hp.Price } else { $null }
                $hitechPrice[$code] = $hprice
                $hitech.Add([ordered]@{
                    code = $code; name = "$($hx.ItemName)"; listPrice = $hprice; currency = $(if ($hp) { "$($hp.Currency)" } else { '' })
                    stock = [double]$hx.QuantityOnStock; sales = ("$($hx.SalesItem)" -eq 'tYES'); frozen = ("$($hx.Frozen)" -eq 'tYES')
                    updated = (Get-Date10 $hx.UpdateDate)
                })
            }
        }
        $n = Norm $name
        [ordered]@{
            code = $code; name = $name
            group = [int]$it.ItemsGroupCode; groupName = $groups["$($it.ItemsGroupCode)"]
            type = $(switch (Get-ItemKind -Type '' -Name $n) { 'PCTR' { 'PRECURED' } 'HOT' { 'HOT' } 'BONDING GUM' { 'BONDING GUM' } default { '' } })
            quality = "$($it.U_SubTypeA)"
            uom = $(if ("$($it.SalesUnit)".Trim()) { "$($it.SalesUnit)" } else { "$($it.InventoryUOM)" })
            beltsPerRoll = $belts; weightPerRoll = $kg
            stock = [double]$it.QuantityOnStock
            sales = ("$($it.SalesItem)" -eq 'tYES'); frozen = ("$($it.Frozen)" -eq 'tYES')
            updated = (Get-Date10 $it.UpdateDate)
            props = @($props | Where-Object { $it."Properties$($_.no)" -eq 'tYES' } | ForEach-Object { $_.no })
            listPrice = $(if ($lp) { [double]$lp.Price } else { $null })
            currency = $(if ($lp) { "$($lp.Currency)" } else { '' })
            twin = $twin; twinNote = $note
        }
    })

    # ---- this server's own check, to set beside the screen's ----
    $checkItems = @(foreach ($i in $items) { [pscustomobject]@{ Code = $i.code; Props = @($i.props); ListPrice = $i.listPrice; Twin = $i.twin } })
    $check = Get-RatesCheck -Items $checkItems -Special $specialBy -Hitech $hitechPrice -Rules $rules -Margin $margin

    $snap = [ordered]@{
        version = 3; company = $TreadsDb; companyName = 'Manna Treads'
        priceList = [ordered]@{ no = $PriceList; name = $plName }
        syncedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        properties = @($props); items = @($items); customers = @($customers)
        specialCols = @('card', 'item', 'price', 'priceList', 'autoUpdate', 'discount', 'valid', 'currency')
        specialRows = $special.ToArray()
        hitech = [ordered]@{ company = $HitechDb; companyName = 'Hi-Tech Pretreads'; priceList = [ordered]@{ no = $PriceList; name = $hiPlName }; items = $hitech.ToArray() }
        serverCheck = $check
    }
    $json = $snap | ConvertTo-Json -Depth 8 -Compress
    $result.items = $items.Count; $result.twins = $hitech.Count; $result.specialPrices = $special.Count; $result.customers = $customers.Count
    $result.changed = $result.items + $result.specialPrices
    $bad = $check.dealer.DRIFT + $check.dealer.MISSING + $check.dealer.KIND + $check.hitech.DRIFT + $check.hitech.MISSING
    $result.summary = ("SAP prices read: {0} qualities, {1} Manna Treads items ({2} with a Hi-Tech twin), {3} customers, {4} special prices ({5:N0} KB). Check: {6} dealer price(s) and {7} Hi-Tech price(s) right, {8} not." -f `
        $props.Count, $result.items, $result.twins, $result.customers, $result.specialPrices, ($json.Length / 1KB), $check.dealer.OK, $check.hitech.OK, $bad)

    if ($DryRun) {
        $out = Join-Path $env:TEMP 'sap-pricing-snapshot.json'
        [IO.File]::WriteAllText($out, $json, (New-Object Text.UTF8Encoding($false)))
        Write-Host "DRY RUN - snapshot written to $out, not to ERPNext"
    } else {
        $body = @{ snapshot_json = $json; snapshot_items = $result.items; snapshot_special_prices = $result.specialPrices } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Method Put -Uri "$site/api/resource/$ctl/$ctl" -Headers $erpHeaders `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
    }
    $result.exitCode = 0
    Write-Host $result.summary
}
catch {
    $result.error = "$($_.Exception.Message)"
    $result.failures = 1
    Write-Host "FAILED: $($result.error)" -ForegroundColor Red
}
finally { Write-Result }
exit $result.exitCode
