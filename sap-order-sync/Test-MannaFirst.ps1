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
Write-Host "`nPASS P - the purchase order to Hi-Tech" -ForegroundColor Cyan

Check 'the supplier is S-1010 Hitech Pretreads-GST by default' ($flow.HitechVendor -eq 'S-1010') $flow.HitechVendor
Check 'the PO series is 199 by default, as the hand POs' ($flow.PoSeries -eq 199) "$($flow.PoSeries)"

# SO 554's line again: 116.7 kg at 253. PO 233 bought it by hand at 232.46 gross.
$sp = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $line 'PMB00101002' 116.7 29525.1) })
$pp = Get-MfPurchasePlan -SalesPlan $sp -Margin 20
Check 'the same item and kilos as the sales order - Manna Treads holds no stock' ($pp.Lines.Count -eq 1 -and $pp.Lines[0].Item -eq 'PMB00101002' -and (Near $pp.Lines[0].Kg 116.7))
Check 'the rate less the margin: 253 - 20 = 233 gross (PO 233 by hand: 232.46)' (Near $pp.Lines[0].Rate 233) "$($pp.Lines[0].Rate)"
Check 'net of 18% GST: 197.457627 (PO 233 by hand: 197)' (Near $pp.Lines[0].UnitPriceNet 197.457627) "$($pp.Lines[0].UnitPriceNet)"
Check 'total incl. GST 27,191.10' (Near $pp.Total 27191.1) "$($pp.Total)"
Check 'paise in the margin stay paise' (Near (Get-MfPurchasePlan -SalesPlan $sp -Margin 20.5).Lines[0].Rate 232.5)
Check 'no margin set refuses it - never bought at the customer''s price' ((Get-MfPurchasePlan -SalesPlan $sp -Margin $null).Problems[0] -match 'No inter-company margin')
Check 'a margin of 0 is no margin' ((Get-MfPurchasePlan -SalesPlan $sp -Margin 0).Problems.Count -eq 1)
$cheap = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $line 'PMB00101002' 10 150) })
Check 'a line selling at no more than the margin is refused' ((Get-MfPurchasePlan -SalesPlan $cheap -Margin 20).Problems[0] -match 'not more than the margin') ((Get-MfPurchasePlan -SalesPlan $cheap -Margin 20).Problems -join '; ')
$bad = Get-MfOrderPlan -Doc ([pscustomobject]@{ items = @(& $line 'PMB00101002' 0 100) })
Check 'the sales order''s own problems carry over' ((Get-MfPurchasePlan -SalesPlan $bad -Margin 20).Problems[0] -match 'weight')

$pb = New-MfPurchaseOrderBody -Plan $pp -CardCode 'S-1010' -OrderName 'SAL-ORD-2026-00321' -MtSalesOrder '555' -TaxCode 'CG+SG@18' -DocDate '2026-11-03' -DueDate '2026-11-06' -Series 199 -Settings $mt
Check 'to Hi-Tech, series 199, branch 1' ($pb.CardCode -eq 'S-1010' -and $pb.Series -eq 199 -and $pb.BPL_IDAssignedToInvoice -eq 1)
Check 'NumAtCard is the ERPNext name' ($pb.NumAtCard -eq 'SAL-ORD-2026-00321')
Check 'the comment names the Manna Treads SO, not the customer' ($pb.Comments -eq 'From ERPNext SAL-ORD-2026-00321 - for Manna Treads SO 555') $pb.Comments
Check 'line: kilos, net price, discount 0, the supplier''s tax code, warehouse 01' ((Near $pb.DocumentLines[0].Quantity 116.7) -and (Near $pb.DocumentLines[0].UnitPrice 197.457627) -and $pb.DocumentLines[0].DiscountPercent -eq 0 -and $pb.DocumentLines[0].TaxCode -eq 'CG+SG@18' -and $pb.DocumentLines[0].WarehouseCode -eq '01')
Check 'header discount 0' ($pb.DiscountPercent -eq 0)

$it = { param($code, $valid = 'tYES', $frozen = 'tNO', $buy = 'tYES') [pscustomobject]@{ ItemCode = $code; Valid = $valid; Frozen = $frozen; PurchaseItem = $buy } }
Check 'a live purchase item can be bought' ((Test-MfPurchaseItems -Codes @('PMB00101002') -Rows @(& $it 'PMB00101002')) -eq '')
Check 'not a purchase item: refused' ((Test-MfPurchaseItems -Codes @('PMB00101002') -Rows @(& $it 'PMB00101002' 'tYES' 'tNO' 'tNO')) -match 'PMB00101002')
Check 'missing: refused' ((Test-MfPurchaseItems -Codes @('PMB00101002', 'PMB00101502') -Rows @(& $it 'PMB00101002')) -match 'PMB00101502')
$vend = { param($type = 'cSupplier', $valid = 'tYES') @([pscustomobject]@{ CardCode = 'S-1010'; CardType = $type; Valid = $valid; Frozen = 'tNO'; BillToState = 'KL' }) }
Check 'S-1010 as a live supplier is fine' ((Test-MfVendor -Rows (& $vend) -CardCode 'S-1010') -eq '')
Check 'a customer under that code is refused' ((Test-MfVendor -Rows (& $vend 'cCustomer') -CardCode 'S-1010') -match 'not a supplier')
Check 'an inactive supplier is refused' ((Test-MfVendor -Rows (& $vend 'cSupplier' 'tNO') -CardCode 'S-1010') -match 'inactive')
Check 'a missing supplier is refused' ((Test-MfVendor -Rows @() -CardCode 'S-1010') -match 'not in Manna Treads')

# ------------------------------------------------------------------------------
Write-Host "`nPASS H - Hi-Tech's sales order, from the purchase order" -ForegroundColor Cyan

# PO 235 as TEST_MANNA_TREADS returned it, 3 Nov 2026.
$po = { param([hashtable] $f)
    $d = [ordered]@{ DocEntry = 2017; DocNum = 235; CardCode = 'S-1010'; Cancelled = 'tNO'; DocumentStatus = 'bost_Open'; DocDueDate = '2026-11-06T00:00:00Z'
                     DocumentLines = @(
                        [pscustomobject]@{ ItemCode = 'PMB00101002'; Quantity = 75; UnitPrice = 197.46; TaxCode = 'CG+SG@18' },
                        [pscustomobject]@{ ItemCode = 'PMB00101502'; Quantity = 60.5; UnitPrice = 193.22; TaxCode = 'CG+SG@18' }) }
    foreach ($k in $f.Keys) { $d[$k] = $f[$k] }
    [pscustomobject]$d }
Check 'a live PO to Hi-Tech can be made into its order' ((Get-HtPoProblem -Po (& $po @{}) -Vendor 'S-1010' -PoNum '235') -eq '')
Check 'a PO not in SAP is refused' ((Get-HtPoProblem -Po $null -Vendor 'S-1010' -PoNum '235') -match 'not in SAP')
Check 'a cancelled PO is refused - nothing to make' ((Get-HtPoProblem -Po (& $po @{ Cancelled = 'tYES' }) -Vendor 'S-1010' -PoNum '235') -match 'cancelled')
Check 'a PO to another supplier is refused' ((Get-HtPoProblem -Po (& $po @{ CardCode = 'S-1011' }) -Vendor 'S-1010' -PoNum '235') -match 'S-1011')
Check 'a PO line with no price is refused' ((Get-HtPoProblem -Po (& $po @{ DocumentLines = @([pscustomobject]@{ ItemCode = 'PMB00101002'; Quantity = 75; UnitPrice = 0 }) }) -Vendor 'S-1010' -PoNum '235') -match 'PMB00101002')

$hb = New-HtSalesOrderBody -Po (& $po @{}) -CardCode '10118' -OrderName 'SAL-ORD-2026-00161' -PoNum '235' -TaxCode 'CG+SG@18' -DocDate '2026-11-03' -Warehouse '07' -Series $null -SalesPersonCode 4
Check 'to 10118, Manna Treads - SHOP' ($hb.CardCode -eq '10118')
Check 'NumAtCard is the ERPNext name - what PASS B and the next run find it by' ($hb.NumAtCard -eq 'SAL-ORD-2026-00161')
Check 'the comment names only Manna Treads'' PO' ($hb.Comments -eq 'Manna Treads PO 235') $hb.Comments
Check 'due when the PO is due' ($hb.DocDueDate -eq '2026-11-06') "$($hb.DocDueDate)"
Check 'the PO''s lines: item, kilos, the price Manna Treads pays, net' (@($hb.DocumentLines).Count -eq 2 -and $hb.DocumentLines[1].ItemCode -eq 'PMB00101502' -and (Near $hb.DocumentLines[1].Quantity 60.5) -and (Near $hb.DocumentLines[1].UnitPrice 193.22))
Check 'every line: discount 0, the tax code, warehouse 07 as PASS A' (@($hb.DocumentLines | Where-Object { $_.DiscountPercent -ne 0 -or $_.TaxCode -ne 'CG+SG@18' -or $_.WarehouseCode -ne '07' }).Count -eq 0)
Check 'the rep as a Hi-Tech sales employee; no series given, none sent' ($hb.SalesPersonCode -eq 4 -and -not $hb.Contains('Series'))
$json = $hb | ConvertTo-Json -Depth 8
Check 'nothing about the end customer anywhere in it' ($json -notmatch 'Alavisons|C-1687|Kannan|C-1183')

$hc = { param($type = 'cCustomer', $valid = 'tYES') @([pscustomobject]@{ CardCode = '10118'; CardType = $type; Valid = $valid; Frozen = 'tNO'; BillToState = 'KL' }) }
Check '10118 as a live customer is fine' ((Test-HtCustomer -Rows (& $hc) -CardCode '10118') -eq '')
Check 'missing, not a customer, or inactive: refused' ((Test-HtCustomer -Rows @() -CardCode '10118') -and (Test-HtCustomer -Rows (& $hc 'cSupplier') -CardCode '10118') -and (Test-HtCustomer -Rows (& $hc 'cCustomer' 'tNO') -CardCode '10118'))
$hi = Test-MtItems -Codes @('I-14335') -Rows @() -Names @{} -Company 'Hi-Tech'
Check 'the item check names Hi-Tech when asked to' ($hi -eq 'Item I-14335 is not in Hi-Tech SAP - no item mapping yet') $hi

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
