<#
.SYNOPSIS
  One-off: turn the ten SYNC TEST treads into one precured and one hot tread per
  quality, and add two test dealers, so the rupee-discount rule can be tried end
  to end in HITECH_PRETREADS_LIVE. Dry run unless -Apply.

.DESCRIPTION
  Written 24 Sep 2026, on the user's request: test treads named by quality,
  some hot as well as precured, each marked with its quality as an SAP item
  property, all kept in item group 122 (ZZ - Test) - the qualities are NOT split
  into item groups the way the real FG - TRP - <quality> groups are.

  The five qualities are Hi-Tech's precured quality groups: Black Pearl,
  Platinum, Polygold, Silver, Diamond. (Black Pearl B is a 25-item sub-grade of
  Black Pearl and is left out.) Each gets SAP item property 1-5.

  WHAT IT CHANGES, per tread (I-14636..I-14645, already in group 122):
    ItemName       in the factory's own shape, so both apps parse the quality:
                     TREAD RUBBER PRECURED BLACK PEARL 120 TEST - SYNC TEST - DO NOT USE
                     TREAD RUBBER HOT BLACK PEARL 32*12 TEST - SYNC TEST - DO NOT USE
                   The apps read PRECURED / HOT from the name, and the quality as
                   the words before the width (client/src/domain/itemNaming.ts).
    Properties1-5  its quality ticked, the other four cleared
    U_Quality, U_ProductType   the UDFs real items use for the same facts
    U_BeltsPerRoll 1 on the hot treads: a hot roll is sold whole, belts do not
                   apply, and 1 keeps the stock view showing whole rolls
    Price List 01  a list price per kg near the real median for that quality

  and it adds customers ZZ-TEST-A and ZZ-TEST-B (manual series 1, group 100
  Customers, Price List 01, a Kerala address) if they do not exist.

  NOT CHANGED: the item group (PATCHing it re-applies group defaults), stock,
  roll weights, anything on a real item. It refuses any item that is not in
  group 122 or whose name does not carry "SYNC TEST".

  NOT DONE HERE, because it is SAP configuration and yours to set: naming item
  properties 1-5. Administration > Setup > Inventory > Item Properties.

  Writes go through the Service Layer, as the staged test chain did on
  23 Sep 2026: ten small PATCHes and at most two POSTs. Special prices are NOT
  written here - that is the part under test, and it goes through DTW.

.EXAMPLE
  .\Setup-RateTestData.ps1           # show what would change
  .\Setup-RateTestData.ps1 -Apply    # do it
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $CompanyDb = 'HITECH_PRETREADS_LIVE',
    [string] $ConfigPath = 'C:\Users\eldhose\sap-treads-stock-sync\config.json'
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'SapSession.ps1')

$suffix = 'TEST - SYNC TEST - DO NOT USE'
$treads = @(
    @{ Code = 'I-14636'; Type = 'PRECURED'; Quality = 'BLACK PEARL'; Prop = 1; Size = '120';   List = 180 },
    @{ Code = 'I-14637'; Type = 'PRECURED'; Quality = 'PLATINUM';    Prop = 2; Size = '150';   List = 175 },
    @{ Code = 'I-14638'; Type = 'PRECURED'; Quality = 'POLYGOLD';    Prop = 3; Size = '170';   List = 155 },
    @{ Code = 'I-14639'; Type = 'PRECURED'; Quality = 'SILVER';      Prop = 4; Size = '205';   List = 140 },
    @{ Code = 'I-14640'; Type = 'PRECURED'; Quality = 'DIAMOND';     Prop = 5; Size = '215';   List = 160 },
    @{ Code = 'I-14641'; Type = 'HOT';      Quality = 'BLACK PEARL'; Prop = 1; Size = '32*12'; List = 170 },
    @{ Code = 'I-14642'; Type = 'HOT';      Quality = 'PLATINUM';    Prop = 2; Size = '34*14'; List = 155 },
    @{ Code = 'I-14643'; Type = 'HOT';      Quality = 'POLYGOLD';    Prop = 3; Size = '32*12'; List = 145 },
    @{ Code = 'I-14644'; Type = 'HOT';      Quality = 'SILVER';      Prop = 4; Size = '34*12'; List = 130 },
    @{ Code = 'I-14645'; Type = 'HOT';      Quality = 'DIAMOND';     Prop = 5; Size = '36*14'; List = 150 }
)
$dealers = @(
    @{ CardCode = 'ZZ-TEST-A'; CardName = 'ZZ TEST DEALER A - SYNC TEST - DO NOT USE' },
    @{ CardCode = 'ZZ-TEST-B'; CardName = 'ZZ TEST DEALER B - SYNC TEST - DO NOT USE' }
)
$testGroup = 122

function Say([string] $m, [string] $c = 'Gray') { Write-Host $m -ForegroundColor $c }
Say ("{0} - {1}" -f $(if ($Apply) { 'APPLY' } else { 'DRY RUN (nothing is written; -Apply to write)' }), $CompanyDb) $(if ($Apply) { 'Yellow' } else { 'Cyan' })

$s = New-SapSession -ConfigPath $ConfigPath -CompanyDb $CompanyDb
$failed = 0
try {
    # ---- read and guard ----
    $sel = 'ItemCode,ItemName,ItemsGroupCode,U_Quality,U_ProductType,U_BeltsPerRoll,U_WeightPerRoll,Properties1,Properties2,Properties3,Properties4,Properties5,ItemPrices'
    $plan = foreach ($t in $treads) {
        $it = Get-SapOne $s "Items('$($t.Code)')?`$select=$sel"
        if ([int]$it.ItemsGroupCode -ne $testGroup) { throw "$($t.Code) is in group $($it.ItemsGroupCode), not $testGroup (ZZ - Test) - refusing to touch a real item" }
        if ("$($it.ItemName)" -notmatch 'SYNC TEST') { throw "$($t.Code) '$($it.ItemName)' is not a SYNC TEST item - refusing" }
        $name = "TREAD RUBBER $($t.Type) $($t.Quality) $($t.Size) $suffix"
        $body = [ordered]@{
            ItemName      = $name
            U_Quality     = $t.Quality
            U_ProductType = $t.Type
            ItemPrices    = @(@{ PriceList = 1; Price = [double]$t.List; Currency = 'INR' })
        }
        foreach ($n in 1..5) { $body["Properties$n"] = $(if ($n -eq $t.Prop) { 'tYES' } else { 'tNO' }) }
        if ($t.Type -eq 'HOT') { $body['U_BeltsPerRoll'] = 1 }
        $old1 = @($it.ItemPrices | Where-Object { $_.PriceList -eq 1 })[0].Price
        [pscustomobject]@{ T = $t; Item = $it; Body = $body; OldList = $old1 }
    }

    Say "`n-- treads (group $testGroup, ZZ - Test) --" Cyan
    foreach ($p in $plan) {
        Say ("{0}  {1}" -f $p.T.Code, $p.Item.ItemName) DarkGray
        Say ("       -> {0}" -f $p.Body.ItemName)
        Say ("          property {0} ({1}), U_ProductType {2}, list 1: {3} -> {4}{5}" -f $p.T.Prop, $p.T.Quality, $p.T.Type, $p.OldList, $p.T.List,
            $(if ($p.T.Type -eq 'HOT') { ", belts/roll $($p.Item.U_BeltsPerRoll) -> 1 (roll $($p.Item.U_WeightPerRoll) kg kept)" } else { '' }))
    }

    Say "`n-- test dealers --" Cyan
    $toCreate = foreach ($d in $dealers) {
        $existing = @(Get-SapAll $s "BusinessPartners?`$select=CardCode,CardName&`$filter=CardCode eq '$($d.CardCode)'")
        if ($existing.Count) { Say ("{0}  exists already - left as it is" -f $d.CardCode) DarkGray; continue }
        Say ("{0}  {1}  (new: customer, group 100, Price List 01, Kerala)" -f $d.CardCode, $d.CardName)
        $d
    }

    if (-not $Apply) { Say "`nDry run only. Re-run with -Apply to write these." Cyan; return }

    # ---- write ----
    Say "`n-- writing --" Yellow
    foreach ($p in $plan) {
        $r = Invoke-SapWrite -Session $s -Method PATCH -Path "Items('$($p.T.Code)')" -Body $p.Body
        if ($r.Http -eq '204') { Say ("  PATCH {0} ok" -f $p.T.Code) Green }
        else { $failed++; Say ("  PATCH {0} -> HTTP {1}: {2}" -f $p.T.Code, $r.Http, (Get-SapShort $r.Body)) Red }
    }
    foreach ($d in @($toCreate)) {
        $addr = @{ Country = 'IN'; State = 'KL'; City = 'Kochi'; AddressName = 'Main' }
        $body = [ordered]@{
            CardCode = $d.CardCode; CardName = $d.CardName; CardType = 'cCustomer'
            Series = 1; GroupCode = 100; Currency = 'INR'; PriceListNum = 1
            BPAddresses = @(($addr + @{ AddressType = 'bo_BillTo' }), ($addr + @{ AddressType = 'bo_ShipTo' }))
        }
        $r = Invoke-SapWrite -Session $s -Method POST -Path 'BusinessPartners' -Body $body
        if ($r.Http -eq '201') { Say ("  POST {0} ok" -f $d.CardCode) Green }
        else { $failed++; Say ("  POST {0} -> HTTP {1}: {2}" -f $d.CardCode, $r.Http, (Get-SapShort $r.Body)) Red }
    }

    # ---- read back ----
    Say "`n-- as SAP now holds it --" Cyan
    foreach ($t in $treads) {
        $it = Get-SapOne $s "Items('$($t.Code)')?`$select=$sel"
        $l1 = @($it.ItemPrices | Where-Object { $_.PriceList -eq 1 })[0].Price
        $props = (1..5 | Where-Object { $it."Properties$_" -eq 'tYES' }) -join ','
        $ok = ($it.ItemName -eq "TREAD RUBBER $($t.Type) $($t.Quality) $($t.Size) $suffix") -and ($props -eq "$($t.Prop)") -and ([double]$l1 -eq [double]$t.List)
        if (-not $ok) { $failed++ }
        Say ("  {0} {1}  prop={2} list1={3} belts={4}  {5}" -f $(if ($ok) { 'OK ' } else { 'BAD' }), $t.Code, $props, $l1, $it.U_BeltsPerRoll, $it.ItemName) $(if ($ok) { 'Green' } else { 'Red' })
    }
    foreach ($d in $dealers) {
        $b = @(Get-SapAll $s "BusinessPartners?`$select=CardCode,CardName,PriceListNum,GroupCode&`$filter=CardCode eq '$($d.CardCode)'")
        if ($b.Count) { Say ("  OK  {0} {1} list={2} group={3}" -f $b[0].CardCode, $b[0].CardName, $b[0].PriceListNum, $b[0].GroupCode) Green }
        else { $failed++; Say ("  BAD {0} not found" -f $d.CardCode) Red }
    }
}
finally {
    Close-SapSession $s
}
if ($failed) { Say "`n$failed step(s) failed - see above." Red; exit 1 }
if ($Apply) { Say "`nDone. Next: name item properties 1-5 in SAP, then build the special prices (README.md)." Green }
