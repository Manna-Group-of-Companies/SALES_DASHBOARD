<#
.SYNOPSIS
  Proves PASS M - the Manna Treads Sales Order made as soon as an ERPNext
  order exists (order_flow.mode = manna_first, 3 Nov 2026).

.DESCRIPTION
  OFFLINE. Extracts the real functions from Sync-SapOrders.ps1 by AST (its
  main body never runs) and calls the SAME functions PASS M calls. Nothing is
  read or written: no SAP, no ERPNext.

  The parts:
    * order_flow's settings: hitech_direct when absent, since required for
      manna_first, the defaults (Manna Treads, Rejected skipped, KL CG+SG@18,
      anything else IGST@18);
    * which orders are PASS M's - and so not PASS A's: unit and creation date;
    * what makes PASS M leave an order alone;
    * the tax code by bill-to state;
    * the plan: kilos, the rate as amount / kilos, net of GST, and the
      problems that refuse the whole order;
    * the POST body: net price, DiscountPercent 0, tax code, NumAtCard;
    * the pairing guard: a TEST_ company only with the local ERPNext.

.EXAMPLE
  .\Test-MannaFirst.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$syncPath = Join-Path $PSScriptRoot 'Sync-SapOrders.ps1'
if (-not (Test-Path $syncPath)) { throw "Cannot find $syncPath" }
$ast = [System.Management.Automation.Language.Parser]::ParseFile($syncPath, [ref]$null, [ref]$null)
$fnText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
           ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($fnText))

$script:pass = 0
$script:fail = 0
function Check {
    param([string] $What, [bool] $Ok, [string] $Got = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  " + $What + $(if ($Got) { "  ->  $Got" } else { '' })) -ForegroundColor Red }
}
function Near { param($A, $B, [double] $Tol = 1e-9) return ([math]::Abs([double]$A - [double]$B) -le $Tol) }
function Throws { param([scriptblock] $Block) try { & $Block; return $false } catch { return $true } }
function Cfg { param([string] $Json) return ($Json | ConvertFrom-Json) }

$flow = Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"2026-11-03"}}')

# ------------------------------------------------------------------------------
Write-Host "`norder_flow settings" -ForegroundColor Cyan

$none = Get-FlowSettings -Config (Cfg '{}')
Check 'no order_flow block is the old flow, hitech_direct' ($none.Mode -eq 'hitech_direct') $none.Mode
Check 'manna_first without since is refused - it would send every old order' (Throws { Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first"}}') })
Check 'since that is not yyyy-MM-dd is refused' (Throws { Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"03/11/2026"}}') })
Check 'an unknown mode is refused' (Throws { Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"hitech_first","since":"2026-11-03"}}') })
Check 'the unit is Manna Treads by default' ((@($flow.Units) -join '|') -eq 'Manna Treads') ($flow.Units -join '|')
Check 'a Rejected order is skipped by default' (@($flow.SkipStatuses) -contains 'Rejected')
Check 'KL is CG+SG@18 by default' ($flow.TaxByState['KL'] -eq 'CG+SG@18') "$($flow.TaxByState['KL'])"
Check 'any other state is IGST@18 by default' ($flow.TaxByState['*'] -eq 'IGST@18') "$($flow.TaxByState['*'])"
Check 'no item allowlist by default - any shared code' ($null -eq $flow.ItemAllowlist)
$al = Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"2026-11-03","item_allowlist":["PMB00101002"]}}')
Check 'an item allowlist is read when given' ((@($al.ItemAllowlist) -join '|') -eq 'PMB00101002') ($al.ItemAllowlist -join '|')
$empty = Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"2026-11-03","item_allowlist":[]}}')
Check 'an empty item allowlist allows nothing (not everything)' ($null -ne $empty.ItemAllowlist -and @($empty.ItemAllowlist).Count -eq 0)

# ------------------------------------------------------------------------------
Write-Host "`nWhich orders are PASS M's, and so not PASS A's" -ForegroundColor Cyan

$row = { param($unit, $created) [pscustomobject]@{ name = 'SAL-ORD-X'; custom_company = $unit; creation = $created } }
Check 'a Manna Treads order created on since is PASS M''s' (Test-MfOwns -Row (& $row 'Manna Treads' '2026-11-03 09:15:02.123456') -Flow $flow)
Check 'one created the day before stays on the old route' (-not (Test-MfOwns -Row (& $row 'Manna Treads' '2026-11-02 23:59:59.999999') -Flow $flow))
Check 'another unit''s order is never PASS M''s' (-not (Test-MfOwns -Row (& $row 'Manna Tyre Retreads' '2026-11-04 10:00:00') -Flow $flow))
Check 'an order with no creation stamp is not taken' (-not (Test-MfOwns -Row (& $row 'Manna Treads' '') -Flow $flow))
Check 'under hitech_direct nothing is PASS M''s' (-not (Test-MfOwns -Row (& $row 'Manna Treads' '2026-11-04 10:00:00') -Flow $none))

$doc = { param([hashtable] $f)
    $d = [ordered]@{ name = 'SAL-ORD-X'; custom_company = 'Manna Treads'; creation = '2026-11-03 10:00:00'; docstatus = 0
                     custom_po_status = 'Pending Approval'; custom_mt_sales_order = $null; custom_mt_sync_error = $null }
    foreach ($k in $f.Keys) { $d[$k] = $f[$k] }
    [pscustomobject]$d }
Check 'a new, unapproved order is taken - as soon as it is created' ((Get-MfSkipReason -Doc (& $doc @{}) -Flow $flow) -eq '') (Get-MfSkipReason -Doc (& $doc @{}) -Flow $flow)
Check 'one that already has its Manna Treads order is skipped' ((Get-MfSkipReason -Doc (& $doc @{ custom_mt_sales_order = '561' }) -Flow $flow) -match '561')
Check 'one with an error on it waits for somebody to clear it' ((Get-MfSkipReason -Doc (& $doc @{ custom_mt_sync_error = 'no code' }) -Flow $flow) -match 'custom_mt_sync_error')
Check 'a cancelled order is skipped' ((Get-MfSkipReason -Doc (& $doc @{ docstatus = 2 }) -Flow $flow) -match 'cancelled')
Check 'a Rejected order is skipped' ((Get-MfSkipReason -Doc (& $doc @{ custom_po_status = 'Rejected' }) -Flow $flow) -match 'Rejected')
Check 'an order from before since is skipped on the re-read too' ((Get-MfSkipReason -Doc (& $doc @{ creation = '2026-10-30 10:00:00' }) -Flow $flow) -match 'since|on or after')

# ------------------------------------------------------------------------------
Write-Host "`nThe tax code by bill-to state" -ForegroundColor Cyan

Check 'KL -> CG+SG@18' ((Get-MfTaxCode -State 'KL' -TaxByState $flow.TaxByState) -eq 'CG+SG@18')
Check 'kl is KL' ((Get-MfTaxCode -State ' kl ' -TaxByState $flow.TaxByState) -eq 'CG+SG@18')
Check 'KA (Gonikkoppal, MT SO 554) -> IGST@18' ((Get-MfTaxCode -State 'KA' -TaxByState $flow.TaxByState) -eq 'IGST@18')
Check 'no bill-to state -> no code, so the order is refused, not sent as IGST' ((Get-MfTaxCode -State '' -TaxByState $flow.TaxByState) -eq '')
Check 'a map with no * gives no code for an unlisted state' ((Get-MfTaxCode -State 'TN' -TaxByState @{ KL = 'CG+SG@18' }) -eq '')

# ------------------------------------------------------------------------------
Write-Host "`nThe plan" -ForegroundColor Cyan

$line = { param($code, $kg, $amount, $perKg = 0, $name = 'PCTR MANNA BLUE VIKING 205 129') [pscustomobject]@{ item_code = $code; item_name = $name; custom_total_weight = $kg; amount = $amount; custom_rate_per_kg = $perKg; qty = 3 } }

# MT SO 554 as Manna Treads raised it by hand: 116.7 kg at 253/kg incl. GST, keyed 214.41.
$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $line 'PMB00101002' 116.7 29525.1) })
Check 'one line, no problems' ($p.Lines.Count -eq 1 -and $p.Problems.Count -eq 0) ("lines {0}, problems {1}" -f $p.Lines.Count, ($p.Problems -join '; '))
Check 'kilos are custom_total_weight, never qty (rolls)' (Near $p.Lines[0].Kg 116.7) "$($p.Lines[0].Kg)"
Check 'the rate is amount / kilos: 253.00' (Near $p.Lines[0].Rate 253) "$($p.Lines[0].Rate)"
Check 'net of 18% GST: 214.406780 (SAP shows 214.41, as on MT SO 554)' (Near $p.Lines[0].UnitPriceNet 214.40678) "$($p.Lines[0].UnitPriceNet)"
Check 'total incl. GST 29,525.10' (Near $p.Total 29525.1) "$($p.Total)"

$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $line 'PMB00101002' 50 0 224) })
Check 'no amount: the per-kilo rate is used' (Near $p.Lines[0].Rate 224 -and $p.Problems.Count -eq 0) "$($p.Lines[0].Rate)"

$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @((& $line 'PMB00101002' 50 11200), (& $line 'PMB00101502' 0 5000)) })
Check 'a line with no weight refuses the whole order - never posted short' ($p.Problems.Count -eq 1 -and $p.Problems[0] -match 'PMB00101502.*weight') ($p.Problems -join '; ')
$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $line 'PMB00101002' 50 0 0) })
Check 'a line with no price refuses it - SAP never prices it from its list' ($p.Problems.Count -eq 1 -and $p.Problems[0] -match 'no price') ($p.Problems -join '; ')
$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @((& $line 'PMB00101002' 50 11200), (& $line 'pmb00101002' 20 4480)) })
Check 'an item on two lines refuses it - later stages follow lines by item code' ($p.Problems.Count -eq 1 -and $p.Problems[0] -match 'more than one line') ($p.Problems -join '; ')
$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @() })
Check 'an order with no lines is refused' ($p.Problems.Count -eq 1 -and $p.Problems[0] -match 'no lines') ($p.Problems -join '; ')

# ------------------------------------------------------------------------------
Write-Host "`nRolls to kilos, from Hi-Tech SAP's weight per roll" -ForegroundColor Cyan

# SAL-ORD-2026-00170 as the app wrote it: 25 rolls of a hot tread at 300/kg,
# with a roll weight of 1 typed on the phone, so 25 kg and 7,500.
$roll = { param($code, $rolls, $amount, $perKg, $cat = 'CTR', $kg = $rolls, $row = 'row1', $belts = 0)
    [pscustomobject]@{ name = $row; item_code = $code; item_name = 'HOT MANNA DOUBLE BLUE 50 16'; custom_product_category = $cat
        qty = $rolls; rate = $(if ($rolls) { $amount / $rolls } else { 0 }); amount = $amount; custom_rate_per_kg = $perKg
        custom_total_weight = $kg; custom_rolls = [math]::Floor($rolls); custom_loose_belts = $belts } }

$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $roll 'HMD001240' 25 7500 300) }) -WeightPerRoll @{ 'HMD001240' = 20.0 }
Check 'a weight in SAP: 25 rolls x 20 kg = 500 kg' (Near $p.Lines[0].Kg 500) "$($p.Lines[0].Kg)"
Check 'a weight in SAP: priced at the rep''s rate per kg, 300' (Near $p.Lines[0].Rate 300) "$($p.Lines[0].Rate)"
Check 'a weight in SAP: line total 500 x 300 = 150,000' (Near $p.Lines[0].Amount 150000) "$($p.Lines[0].Amount)"
Check 'a weight in SAP: the app''s own roll weight plays no part' (Near $p.Lines[0].PerUnit 20) "$($p.Lines[0].PerUnit)"

$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $roll 'HMD001240' 25 7500 300 'CTR' 500) }) -WeightPerRoll @{}
Check 'no weight in SAP: 25 rolls go as 25, whatever the app weighed them at' ((Near $p.Lines[0].Kg 25) -and $p.Problems.Count -eq 0) "$($p.Lines[0].Kg) / $($p.Problems -join '; ')"
Check 'no weight in SAP: the app''s per-roll price, 7500 / 25 = 300' (Near $p.Lines[0].Rate 300) "$($p.Lines[0].Rate)"
Check 'no weight in SAP: SAP''s total is the order''s own 7,500' ((Near $p.Lines[0].Amount 7500) -and (Near $p.Total 7500)) "$($p.Lines[0].Amount)"
Check 'no weight in SAP: PerUnit 1, a 1:1 line' (Near $p.Lines[0].PerUnit 1) "$($p.Lines[0].PerUnit)"

$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $roll 'HMD001240' 4 30360 253 'CTR' 120) }) -WeightPerRoll @{ 'HMD001240' = 0.0 }
Check 'a weight of 0 in SAP is no weight: 4 rolls at 30360 / 4' ((Near $p.Lines[0].Kg 4) -and (Near $p.Lines[0].Rate 7590)) ("{0} @ {1}" -f $p.Lines[0].Kg, $p.Lines[0].Rate)

$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $roll 'hmd001240' 2 600 300) }) -WeightPerRoll (Get-MfWeightPerRoll -Rows @([pscustomobject]@{ ItemCode = 'HMD001240'; U_WeightPerRoll = 22.5 }))
Check 'the weight is matched whatever the code''s case' (Near $p.Lines[0].Kg 45) "$($p.Lines[0].Kg)"

$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $roll 'PMB00101002' 2.5 0 255 'PCTR' 60.5 'row1' 2) }) -WeightPerRoll @{ 'PMB00101002' = 24.2 }
Check 'PCTR with loose belts: qty (rolls + belts as a fraction) x weight, 2.5 x 24.2 = 60.5' (Near $p.Lines[0].Kg 60.5) "$($p.Lines[0].Kg)"

$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $roll 'BG0001' 3 0 200 'Bonding Gum' 30) }) -WeightPerRoll @{ 'BG0001' = 99.0 }
Check 'a line that is not PCTR or CTR is as before - its own kilos' ((Near $p.Lines[0].Kg 30) -and (Near $p.Lines[0].PerUnit 0)) "$($p.Lines[0].Kg)"

$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $roll 'HMD001240' 25 7500 300 'CTR' 500) })
Check 'no weights given at all: as before, custom_total_weight' (Near $p.Lines[0].Kg 500) "$($p.Lines[0].Kg)"

$p = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $roll 'HMD001240' 0 0 300) }) -WeightPerRoll @{}
Check 'a roll line with no rolls refuses the order' ($p.Problems.Count -eq 1 -and $p.Problems[0] -match 'no rolls') ($p.Problems -join '; ')

$wp = Get-MfWeightPerRoll -Rows @([pscustomobject]@{ ItemCode = 'a1'; U_WeightPerRoll = 10 }, [pscustomobject]@{ ItemCode = 'B2'; U_WeightPerRoll = 0 }, [pscustomobject]@{ ItemCode = 'C3'; U_WeightPerRoll = $null })
Check 'SAP weights: upper-cased, and blank or 0 left out (so 1:1)' ($wp.Count -eq 1 -and (Near $wp['A1'] 10)) ("{0} key(s)" -f $wp.Count)

# What PASS M writes back so PASS B and the pick list count in SAP's unit.
$doc = [pscustomobject]@{ items = @((& $roll 'HMD001240' 25 7500 300 'CTR' 500 'r1'), (& $roll 'HV0001020' 10 3000 300 'CTR' 200 'r2'), (& $roll 'HMD001300' 5 1500 300 'CTR' 5 'r3'), (& $roll 'BG0001' 3 0 200 'Bonding Gum' 30 'r4')) }
$p = Get-MfOrderPlan -Doc $doc -WeightPerRoll @{ 'HV0001020' = 18.0 }
$lw = @(Get-MfLineWeightWrites -Plan $p -Doc $doc)
$byRow = @{}; foreach ($x in $lw) { $byRow[$x.RowName] = $x }
$lwSaid = ($lw | ForEach-Object { "$($_.RowName) $($_.Note)" }) -join '; '
Check 'write-back: a 1:1 line gets custom_total_weight = its rolls, 25' ($byRow.ContainsKey('r1') -and (Near $byRow['r1'].Fields.custom_total_weight 25)) $lwSaid
Check 'write-back: a 1:1 line''s packing note is left as the rep saw it' ($byRow.ContainsKey('r1') -and -not $byRow['r1'].Fields.ContainsKey('custom_packing_note'))
Check 'write-back: a weighed line gets SAP''s kilos, 180, and its note rebuilt' ($byRow.ContainsKey('r2') -and (Near $byRow['r2'].Fields.custom_total_weight 180) -and ("$($byRow['r2'].Fields.custom_packing_note)" -match '^10 rolls .* 180\.00 kg$')) "$($byRow['r2'].Fields.custom_packing_note)"
Check 'write-back: a line that already agrees is not written' (-not $byRow.ContainsKey('r3'))
Check 'write-back: never rate or amount' (@($lw | Where-Object { $_.Fields.ContainsKey('rate') -or $_.Fields.ContainsKey('amount') }).Count -eq 0)
Check 'write-back: a line that is not PCTR or CTR is not written' (-not $byRow.ContainsKey('r4'))

$ap = Get-MfAdoptedPlan -Plan $p -SapLines @([pscustomobject]@{ ItemCode = 'HMD001240'; Quantity = 25 }, [pscustomobject]@{ ItemCode = 'hv0001020'; Quantity = 200 })
$alw = @(Get-MfLineWeightWrites -Plan $ap -Doc $doc)
Check 'adopted: the quantity SAP holds is written, not today''s weight (200 already, so r2 untouched)' (@($alw | Where-Object { $_.RowName -eq 'r2' }).Count -eq 0 -and @($alw | Where-Object { $_.RowName -eq 'r1' }).Count -eq 1) (($alw | ForEach-Object { "$($_.RowName) $($_.Note)" }) -join '; ')
$ap2 = Get-MfAdoptedPlan -Plan $p -SapLines @([pscustomobject]@{ ItemCode = 'HMD001240'; Quantity = 25 })
Check 'adopted: a line SAP lacks is not written' (@(Get-MfLineWeightWrites -Plan $ap2 -Doc $doc | Where-Object { $_.RowName -eq 'r2' }).Count -eq 0)

$b2 = New-MfSalesOrderBody -Plan (Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $roll 'HMD001240' 25 7500 300) }) -WeightPerRoll @{}) -CardCode 'C-1709' -OrderName 'SAL-ORD-2026-00170' -TaxCode 'CG+SG@18' -DocDate '2026-11-06' -DueDate '2026-11-06' -Settings (Get-MtSettings -Config (Cfg '{"manna_treads":{"company_db":"TEST_MANNA_TREADS"}}'))
Check 'the POST carries the 1:1 quantity, 25, at 300 net of GST' ((Near $b2.DocumentLines[0].Quantity 25) -and (Near $b2.DocumentLines[0].UnitPrice (300 / 1.18) 1e-5)) ("{0} @ {1}" -f $b2.DocumentLines[0].Quantity, $b2.DocumentLines[0].UnitPrice)

# ------------------------------------------------------------------------------
Write-Host "`nThe due date" -ForegroundColor Cyan

Check 'the delivery date when it is ahead' ((Get-MfDueDate -DeliveryDate '2026-11-10' -Today '2026-11-03') -eq '2026-11-10')
Check 'today when the delivery date has passed - SAP refuses a due date before the document' ((Get-MfDueDate -DeliveryDate '2026-11-01' -Today '2026-11-03') -eq '2026-11-03')
Check 'today when there is none' ((Get-MfDueDate -DeliveryDate $null -Today '2026-11-03') -eq '2026-11-03')

# ------------------------------------------------------------------------------
Write-Host "`nThe POST body" -ForegroundColor Cyan

$mt = Get-MtSettings -Config (Cfg '{"manna_treads":{"company_db":"TEST_MANNA_TREADS"}}')
$plan = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @((& $line 'PMB00101002' 116.7 29525.1), (& $line 'PMB00101502' 60 13440 0 'PCTR MANNA BLUE VIKING 197 129')) })
$b = New-MfSalesOrderBody -Plan $plan -CardCode 'C-1183' -OrderName 'SAL-ORD-2026-00321' -TaxCode 'IGST@18' -DocDate '2026-11-03' -DueDate '2026-11-05' -Rep 'Anil' -Settings $mt
Check 'to the end customer' ($b.CardCode -eq 'C-1183')
Check 'NumAtCard is the ERPNext name - what the next run adopts by' ($b.NumAtCard -eq 'SAL-ORD-2026-00321')
Check 'Series 189, branch 1 - as Manna Treads'' own orders' ($b.Series -eq 189 -and $b.BPL_IDAssignedToInvoice -eq 1) ("{0} / {1}" -f $b.Series, $b.BPL_IDAssignedToInvoice)
Check 'document dated today, due on the delivery date' ($b.DocDate -eq '2026-11-03' -and $b.DocDueDate -eq '2026-11-05')
Check 'header discount 0' ($b.DiscountPercent -eq 0)
Check 'two lines' (@($b.DocumentLines).Count -eq 2)
$l0 = $b.DocumentLines[0]
Check 'line: the shared code, the kilos, the net price' ($l0.ItemCode -eq 'PMB00101002' -and (Near $l0.Quantity 116.7) -and (Near $l0.UnitPrice 214.40678)) ("{0} {1} {2}" -f $l0.ItemCode, $l0.Quantity, $l0.UnitPrice)
Check 'every line: discount 0, the tax code chosen, warehouse 01, location 2' (@($b.DocumentLines | Where-Object { $_.DiscountPercent -ne 0 -or $_.TaxCode -ne 'IGST@18' -or $_.WarehouseCode -ne '01' -or $_.LocationCode -ne 2 }).Count -eq 0)
Check 'the comment names the ERPNext order and the rep' ($b.Comments -eq 'From ERPNext SAL-ORD-2026-00321 - rep Anil') $b.Comments
Check 'nothing about Hi-Tech on the customer''s order' ($b.Comments -notmatch 'Hi-Tech')

# ------------------------------------------------------------------------------
Write-Host "`nThe customer, with the state left to the tax code" -ForegroundColor Cyan

$bp = { param($state) @([pscustomobject]@{ CardCode = 'C-1183'; CardName = 'Kannan Tyres Gonikkoppal (GST)'; CardType = 'cCustomer'; Valid = 'tYES'; Frozen = 'tNO'; BillToState = $state }) }
Check 'PASS M (*): a Karnataka customer is fine' ((Test-MtCustomer -Rows (& $bp 'KA') -CardCode 'C-1183' -AllowedStates @('*') -CustomerName 'Kannan Tyres Gonikkoppal (GST)') -eq '')
Check 'PASS C (KL): still refused' ((Test-MtCustomer -Rows (& $bp 'KA') -CardCode 'C-1183' -AllowedStates @('KL')) -match 'IGST')
Check 'PASS M: a different customer under that code is still refused' ((Test-MtCustomer -Rows (& $bp 'KA') -CardCode 'C-1183' -AllowedStates @('*') -CustomerName 'Excel Tyres') -match 'not the same customer')

# ------------------------------------------------------------------------------
Write-Host "`nThe item check, for Hi-Tech" -ForegroundColor Cyan

$hi = Test-MtItems -Codes @('I-14335') -Rows @() -Names @{} -Company 'Hi-Tech'
Check 'the item check names Hi-Tech when asked to' ($hi -eq 'Item I-14335 is not in Hi-Tech SAP - no item mapping yet') $hi

# ------------------------------------------------------------------------------
Write-Host "`nB1if makes the purchase order and Hi-Tech's order; PASS P and H only link them" -ForegroundColor Cyan

Check 'B1if is the maker when nothing is said' (-not (Throws { $null = Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"2026-11-03"}}') }))
Check 'intercompany b1if is accepted' (-not (Throws { $null = Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"2026-11-03","intercompany":"b1if"}}') }))
Check 'intercompany script is refused - the script no longer makes them, and a config saying so would be believed' (Throws { Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"2026-11-03","intercompany":"script"}}') })
Check 'B1if gets 30 minutes by default' ($flow.B1ifWait -eq 30) "$($flow.B1ifWait)"
Check 'the old PO settings are gone from what the script reads' (-not $flow.ContainsKey('HitechVendor') -and -not $flow.ContainsKey('PoSeries'))
Check 'a wait of 0 minutes is refused - every order would be refused at once' (Throws { Get-FlowSettings -Config (Cfg '{"order_flow":{"mode":"manna_first","since":"2026-11-03","intercompany":"b1if","b1if_wait_minutes":0}}') })
$now = [datetime]'2026-11-04 12:00:00'
Check 'ten minutes after the last write B1if is still being waited for' (-not (Test-B1ifLate -Since '2026-11-04 11:50:00' -Now $now -Minutes 30))
Check 'thirty minutes after it, B1if is late' (Test-B1ifLate -Since '2026-11-04 11:30:00' -Now $now -Minutes 30)
Check 'ERPNext microseconds on the time are ignored' (-not (Test-B1ifLate -Since '2026-11-04 11:50:00.123456' -Now $now -Minutes 30))
Check 'a time that cannot be read is late, so somebody is told' (Test-B1ifLate -Since '' -Now $now -Minutes 30)

# ------------------------------------------------------------------------------
Write-Host "`nTest companies with the local ERPNext only" -ForegroundColor Cyan

Check 'TEST_ companies with the local copy: allowed' (-not (Throws { Assert-SapErpPairing -ErpSite 'http://127.0.0.1:8000' -CompanyDbs @('TEST_HITECH_PRETREADS', 'TEST_MANNA_TREADS') }))
Check 'live companies with the live site: allowed' (-not (Throws { Assert-SapErpPairing -ErpSite 'https://mannarubber.m.frappe.cloud' -CompanyDbs @('HITECH_PRETREADS_LIVE', 'MANNA_TREADS_LIVE') }))
Check 'a TEST_ company with the live site: refused' (Throws { Assert-SapErpPairing -ErpSite 'https://mannarubber.m.frappe.cloud' -CompanyDbs @('HITECH_PRETREADS_LIVE', 'TEST_MANNA_TREADS') })
Check 'a live company with the local copy: refused' (Throws { Assert-SapErpPairing -ErpSite 'http://manna.localhost:8000' -CompanyDbs @('TEST_HITECH_PRETREADS', 'MANNA_TREADS_LIVE') })
Check 'TEST_..._LIVE is not a test company' (Throws { Assert-SapErpPairing -ErpSite 'http://127.0.0.1:8000' -CompanyDbs @('TEST_MANNA_TREADS_LIVE') })
Check 'Manna Treads orders go to TEST_MANNA_TREADS' (-not (Throws { Assert-MtCompanyDb -CompanyDb 'TEST_MANNA_TREADS' -HitechCompanyDb 'TEST_HITECH_PRETREADS' }))
Check '...or MANNA_TREADS_LIVE, and nowhere else' (Throws { Assert-MtCompanyDb -CompanyDb 'TEST_HITECH_PRETREADS' -HitechCompanyDb 'HITECH_PRETREADS_LIVE' })

Write-Host ("`n{0} passed, {1} failed." -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
