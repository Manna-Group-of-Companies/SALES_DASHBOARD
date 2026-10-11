<#
.SYNOPSIS
  The rates test set-up in MANNA_TREADS_LIVE: the ten SYNC TEST treads copied
  from HITECH_PRETREADS_LIVE with the same item codes, and the two test dealers.
  Dry run unless -Apply. Safe to re-run: anything already there is left alone.

.DESCRIPTION
  Asked for on 25 Sep 2026. The dealers are customers of MANNA TREADS, not of
  Hi-Tech, so dealer prices belong in Manna Treads' SAP. Hi-Tech bills Manna
  Treads a fixed number of rupees per kg below Manna Treads' own price list
  (Manna Treads' margin; -TreadsMargin, deliberately not written down here -
  this repository is public). Every price and discount is GST-inclusive as it
  stands; nothing here adds or removes GST.

  Per tread (I-14636..I-14645), read LIVE from Hi-Tech:
    ItemCode, ItemName          the same
    item property 1-5           the same quality (Black Pearl, Platinum, Polygold,
                                Silver, Diamond) - name the properties in Manna
                                Treads' SAP too (Administration > Setup > Inventory >
                                Item Properties); that is configuration, not done here
    U_SubTypeA                  the quality in capitals - where Manna Treads' own
                                treads record it (Manna Treads has no U_Quality)
    Price List 01 ("selling price")  Hi-Tech's Price List 01 price + the margin
  and, from a real Manna Treads tread of the same kind (I-1001 for precured,
  the first HOT-group tread for hot): UoM, tax (VatLiable, TaxType, GST, HSN
  chapter, tax category, U_TaxRate), material type, G/L method, costing method.

  Item group "ZZ - Test" is created in Manna Treads if it is missing, so the
  test treads are kept out of PRECURED / HOT exactly as in Hi-Tech. Manna
  Treads posts G/L by warehouse (glm_WH), so the group carries no accounts.

  Test dealers ZZ-TEST-A and ZZ-TEST-B: customers, group 100 "Customers",
  Price List 01, a Kerala address - set up as Hi-Tech's were (Setup-RateTestData.ps1)
  and as Manna Treads' own dealers are (manual series 1, list 1). ERPNext never
  sees them: the credit sync matches customers on custom_bp_code only and
  creates none.

  Nothing is posted to any ledger; stock stays 0.

  Run 25 Sep 2026: item group 116, all ten treads created and read back OK;
  then the two dealers.

.EXAMPLE
  .\Setup-TreadsTestData.ps1 -TreadsMargin <rupees per kg>           # show what would be created
  .\Setup-TreadsTestData.ps1 -TreadsMargin <rupees per kg> -Apply    # create it
  .\Setup-TreadsTestData.ps1 -Apply     # when the treads exist already, the margin is not needed
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $ConfigPath = 'C:\Users\eldhose\sap-treads-stock-sync\config.json',
    [double] $TreadsMargin = [double]::NaN
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'SapSession.ps1')
function Say([string] $m, [string] $c = 'Gray') { Write-Host $m -ForegroundColor $c }

$codes = 14636..14645 | ForEach-Object { "I-$_" }
$groupName = 'ZZ - Test'
$dealers = @(
    @{ CardCode = 'ZZ-TEST-A'; CardName = 'ZZ TEST DEALER A - SYNC TEST - DO NOT USE' },
    @{ CardCode = 'ZZ-TEST-B'; CardName = 'ZZ TEST DEALER B - SYNC TEST - DO NOT USE' }
)
Say ("{0} - the rates test set-up in Manna Treads" -f $(if ($Apply) { 'APPLY' } else { 'DRY RUN (nothing is written; -Apply to write)' })) $(if ($Apply) { 'Yellow' } else { 'Cyan' })

# ---- 1. the test treads as Hi-Tech holds them ----
$h = New-SapSession -ConfigPath $ConfigPath -CompanyDb 'HITECH_PRETREADS_LIVE'
try {
    $flt = ($codes | ForEach-Object { "ItemCode eq '$_'" }) -join ' or '
    $src = @(Get-SapAll $h "Items?`$select=ItemCode,ItemName,ItemsGroupCode,U_Quality,U_ProductType,Properties1,Properties2,Properties3,Properties4,Properties5,ItemPrices&`$filter=$flt")
}
finally { Close-SapSession $h }
if ($src.Count -ne $codes.Count) { throw "expected $($codes.Count) test treads in Hi-Tech, found $($src.Count)" }
foreach ($i in $src) {
    if ([int]$i.ItemsGroupCode -ne 122 -or "$($i.ItemName)" -notmatch 'SYNC TEST') { throw "$($i.ItemCode) in Hi-Tech is not a ZZ - Test / SYNC TEST item - refusing" }
}

# ---- 2. Manna Treads: what exists, the templates, the group ----
$t = New-SapSession -ConfigPath $ConfigPath -CompanyDb 'MANNA_TREADS_LIVE'
$failed = 0
try {
    $exists = @{}
    foreach ($x in @(Get-SapAll $t "Items?`$select=ItemCode,ItemName&`$filter=$flt")) { $exists["$($x.ItemCode)"] = "$($x.ItemName)" }
    $bpExists = @{}
    foreach ($d in $dealers) {
        $b = @(Get-SapAll $t "BusinessPartners?`$select=CardCode,CardName&`$filter=CardCode eq '$($d.CardCode)'")
        if ($b.Count) { $bpExists[$d.CardCode] = "$($b[0].CardName)" }
    }

    $tplSel = 'ItemCode,ItemName,InventoryUOM,VatLiable,TaxType,GLMethod,CostAccountingMethod,ManageStockByWarehouse,WTLiable,MaterialType,ChapterID,GSTRelevnt,GSTTaxCategory,U_TaxRate'
    $tplPre = Get-SapOne $t "Items('I-1001')?`$select=$tplSel"
    $tplHot = @(Get-SapAll $t "Items?`$select=$tplSel&`$filter=ItemsGroupCode eq 102 and Valid eq 'tYES'&`$top=1")[0]
    if (-not $tplHot) { throw 'no HOT-group tread in Manna Treads to copy tax settings from' }
    Say ("templates: precured {0} '{1}' (HSN entry {2}, {3}); hot {4} '{5}' (HSN entry {6}, {7})" -f `
        $tplPre.ItemCode, $tplPre.ItemName, $tplPre.ChapterID, $tplPre.MaterialType, $tplHot.ItemCode, $tplHot.ItemName, $tplHot.ChapterID, $tplHot.MaterialType) DarkGray

    $grp = @(Get-SapAll $t "ItemGroups?`$select=Number,GroupName&`$filter=GroupName eq '$groupName'")
    $groupNo = if ($grp.Count) { [int]$grp[0].Number } else { $null }
    Say ("item group '{0}': {1}" -f $groupName, $(if ($groupNo) { "exists (#$groupNo)" } else { 'missing - will be created' }))

    $plan = foreach ($i in ($src | Sort-Object ItemCode)) {
        $code = "$($i.ItemCode)"
        $prop = @(1..5 | Where-Object { $i."Properties$_" -eq 'tYES' })
        $hi = [double](@($i.ItemPrices | Where-Object { $_.PriceList -eq 1 })[0].Price)
        $hot = ("$($i.U_ProductType)" -eq 'HOT')
        $tpl = if ($hot) { $tplHot } else { $tplPre }
        [pscustomobject]@{
            Code = $code; Name = "$($i.ItemName)"; Quality = "$($i.U_Quality)"; Type = "$($i.U_ProductType)"
            Props = $prop; HiTech = $hi; Treads = $(if ([double]::IsNaN($TreadsMargin)) { $null } else { [math]::Round($hi + $TreadsMargin, 2) }); Tpl = $tpl; Exists = $exists.ContainsKey($code)
        }
    }
    $newItems = @($plan | Where-Object { -not $_.Exists })
    if ($newItems.Count -and [double]::IsNaN($TreadsMargin)) { throw "$($newItems.Count) tread(s) still to create: give -TreadsMargin (rupees per kg) so their Manna Treads price can be set" }

    Say "`n-- test treads --" Cyan
    foreach ($p in $plan) {
        if ($p.Exists) { Say ("{0}  exists already as '{1}' - left alone" -f $p.Code, $exists[$p.Code]) DarkGray; continue }
        Say ("{0}  {1}" -f $p.Code, $p.Name)
        Say ("       property {0} ({1}), {2}; Price List 01 {3} = Hi-Tech {4} + {5}" -f ($p.Props -join ','), $p.Quality, $p.Type, $p.Treads, $p.HiTech, $TreadsMargin)
    }
    Say "`n-- test dealers --" Cyan
    foreach ($d in $dealers) {
        if ($bpExists.ContainsKey($d.CardCode)) { Say ("{0}  exists already as '{1}' - left alone" -f $d.CardCode, $bpExists[$d.CardCode]) DarkGray; continue }
        Say ("{0}  {1}  (new: customer, group 100, Price List 01, Kerala)" -f $d.CardCode, $d.CardName)
    }
    if (-not $Apply) { Say "`nDry run only. Re-run with -Apply to create these." Cyan; return }

    # ---- 3. write ----
    Say "`n-- writing --" Yellow
    if ($newItems.Count -and -not $groupNo) {
        $g = Invoke-SapWrite -Session $t -Method POST -Path 'ItemGroups' -Body ([ordered]@{ GroupName = $groupName })
        if ($g.Http -ne '201') { throw "creating item group '$groupName' -> HTTP $($g.Http): $(Get-SapShort $g.Body)" }
        $groupNo = [int](($g.Body | ConvertFrom-Json).Number)
        Say ("  item group '{0}' created (#{1})" -f $groupName, $groupNo) Green
    }
    foreach ($p in $newItems) {
        $tp = $p.Tpl
        $body = [ordered]@{
            ItemCode = $p.Code; ItemName = $p.Name; ItemsGroupCode = $groupNo; Series = 3
            InventoryItem = 'tYES'; SalesItem = 'tYES'; PurchaseItem = 'tYES'
            InventoryUOM = "$($tp.InventoryUOM)"
            VatLiable = "$($tp.VatLiable)"; TaxType = "$($tp.TaxType)"; GLMethod = "$($tp.GLMethod)"
            CostAccountingMethod = "$($tp.CostAccountingMethod)"; ManageStockByWarehouse = "$($tp.ManageStockByWarehouse)"
            WTLiable = "$($tp.WTLiable)"; MaterialType = "$($tp.MaterialType)"; ChapterID = [int]$tp.ChapterID
            GSTRelevnt = "$($tp.GSTRelevnt)"; GSTTaxCategory = "$($tp.GSTTaxCategory)"
            PlanningSystem = 'bop_None'; ProcurementMethod = 'bom_Buy'
            U_TaxRate = "$($tp.U_TaxRate)"; U_SubTypeA = $p.Quality
            ItemPrices = @(@{ PriceList = 1; Price = [double]$p.Treads; Currency = 'INR' })
        }
        foreach ($n in 1..5) { $body["Properties$n"] = $(if ($p.Props -contains $n) { 'tYES' } else { 'tNO' }) }
        $r = Invoke-SapWrite -Session $t -Method POST -Path 'Items' -Body $body
        if ($r.Http -eq '201') { Say ("  created {0}" -f $p.Code) Green }
        else { $failed++; Say ("  {0} -> HTTP {1}: {2}" -f $p.Code, $r.Http, (Get-SapShort $r.Body)) Red }
    }
    foreach ($d in $dealers | Where-Object { -not $bpExists.ContainsKey($_.CardCode) }) {
        $addr = @{ Country = 'IN'; State = 'KL'; City = 'Kochi'; AddressName = 'Main' }
        $body = [ordered]@{
            CardCode = $d.CardCode; CardName = $d.CardName; CardType = 'cCustomer'
            Series = 1; GroupCode = 100; Currency = 'INR'; PriceListNum = 1
            BPAddresses = @(($addr + @{ AddressType = 'bo_BillTo' }), ($addr + @{ AddressType = 'bo_ShipTo' }))
        }
        $r = Invoke-SapWrite -Session $t -Method POST -Path 'BusinessPartners' -Body $body
        if ($r.Http -eq '201') { Say ("  created dealer {0}" -f $d.CardCode) Green }
        else { $failed++; Say ("  dealer {0} -> HTTP {1}: {2}" -f $d.CardCode, $r.Http, (Get-SapShort $r.Body)) Red }
    }

    # ---- 4. read back ----
    Say "`n-- as Manna Treads now holds them --" Cyan
    foreach ($p in $plan) {
        $x = @(Get-SapAll $t "Items?`$select=ItemCode,ItemName,ItemsGroupCode,U_SubTypeA,Properties1,Properties2,Properties3,Properties4,Properties5,ItemPrices&`$filter=ItemCode eq '$($p.Code)'")[0]
        if (-not $x) { $failed++; Say ("  MISSING {0}" -f $p.Code) Red; continue }
        $pl = [double](@($x.ItemPrices | Where-Object { $_.PriceList -eq 1 })[0].Price)
        $props = (1..5 | Where-Object { $x."Properties$_" -eq 'tYES' }) -join ','
        $ok = ($x.ItemName -eq $p.Name) -and ($null -eq $groupNo -or [int]$x.ItemsGroupCode -eq $groupNo) -and ($props -eq ($p.Props -join ',')) -and ($p.Exists -or $pl -eq $p.Treads)
        if (-not $ok) { $failed++ }
        Say ("  {0} {1}  group={2} prop={3} SubTypeA={4} list1={5} (Hi-Tech {6})  {7}" -f $(if ($ok) { 'OK ' } else { 'BAD' }), $x.ItemCode, $x.ItemsGroupCode, $props, $x.U_SubTypeA, $pl, $p.HiTech, $x.ItemName) $(if ($ok) { 'Green' } else { 'Red' })
    }
    foreach ($d in $dealers) {
        $b = @(Get-SapAll $t "BusinessPartners?`$select=CardCode,CardName,CardType,PriceListNum,GroupCode&`$filter=CardCode eq '$($d.CardCode)'")
        if ($b.Count -and $b[0].CardType -eq 'cCustomer') { Say ("  OK  {0} {1} list={2} group={3}" -f $b[0].CardCode, $b[0].CardName, $b[0].PriceListNum, $b[0].GroupCode) Green }
        else { $failed++; Say ("  BAD {0} not found as a customer" -f $d.CardCode) Red }
    }
}
finally { Close-SapSession $t }
if ($failed) { Say "`n$failed step(s) failed - see above." Red; exit 1 }
if ($Apply) { Say "`nDone. Next: name item properties 1-5 in Manna Treads' SAP (Black Pearl, Platinum, Polygold, Silver, Diamond)." Green }
