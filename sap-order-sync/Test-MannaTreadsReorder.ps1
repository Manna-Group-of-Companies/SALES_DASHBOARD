<#
.SYNOPSIS
  Proves the stage-two rule - what the Manna Treads Sales Order bills - and
  the Hi-Tech delivered and invoiced kilos it is built from.

.DESCRIPTION
  OFFLINE. Extracts the real functions from Sync-SapOrders.ps1 by AST (its
  main body never runs) and calls the SAME functions PASS B and PASS C call.
  Nothing is read or written: no SAP, no ERPNext. Runs with both down.

  The parts:
    * every case in shared/fixtures/manna_treads_reorder.json, through
      Get-MtReorderPlan, and GST in code equal to the fixture's. The
      dashboard's TypeScript is tested against the same file, so the two
      implementations cannot drift apart unnoticed;
    * rounding: Get-RoundedHalfUp against values the dashboard's roundTo
      gives (half-paisa midpoints up, on the decimal value);
    * the kilos PASS B captures: live deliveries only, a reversal ignored, two
      deliveries on one line summed, one delivery across two orders split, and
      an invoice drawn from a delivery never counted as a direct invoice;
    * the settings' defaults: Series 189, branch 1, warehouse 01, CG+SG@18,
      location 2, the ten SYNC TEST items allowed; the GST knobs refused;
    * the body PASS C posts: net price, DiscountPercent 0 on the header and
      every line, tax code, warehouse, location, NumAtCard, and nothing for a
      line with nothing;
    * the refusals PASS C makes: the plan's, an item on two lines, an item not
      on the allowlist, an item named differently in Manna Treads SAP, the
      customer's;
    * the lifecycle: only error-free requested orders are taken, adoption is
      decided before any refusal, SAP refusing a POST is the order's problem
      while a transient failure is the run's;
    * the PASS C lock, held by another process.

.EXAMPLE
  .\Test-MannaTreadsReorder.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Load only the function definitions; the script's own body must not run.
$syncPath = Join-Path $PSScriptRoot 'Sync-SapOrders.ps1'
if (-not (Test-Path $syncPath)) { throw "Cannot find $syncPath" }
$ast = [System.Management.Automation.Language.Parser]::ParseFile($syncPath, [ref]$null, [ref]$null)
$fnText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
           ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($fnText))

$fixturePath = Join-Path $PSScriptRoot '..\shared\fixtures\manna_treads_reorder.json'
if (-not (Test-Path $fixturePath)) { throw "Cannot find $fixturePath" }
$fixture = Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8 | ConvertFrom-Json

$script:pass = 0
$script:fail = 0
function Check {
    param([string] $What, [bool] $Ok, [string] $Got = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  " + $What + $(if ($Got) { "  ->  $Got" } else { '' })) -ForegroundColor Red }
}
# PS 5.1 reads a JSON fraction as [decimal]; compare as doubles.
function Near { param($A, $B, [double] $Tol = 1e-9) return ([math]::Abs([double]$A - [double]$B) -le $Tol) }

# ------------------------------------------------------------------------------
Write-Host "`nThe shared fixture, through Get-MtReorderPlan" -ForegroundColor Cyan

$cases = @($fixture.cases)
Check ("the fixture has its cases ({0})" -f $cases.Count) ($cases.Count -ge 15) "$($cases.Count)"
Check ("GST in code ({0}%) is the fixture's gst_percent ({1}%)" -f (Get-MtGstPercent), $fixture.gst_percent) ((Get-MtGstPercent) -eq [double]$fixture.gst_percent) "$(Get-MtGstPercent)"
$planParams = (Get-Command Get-MtReorderPlan).Parameters
Check '  and it is not a parameter of the plan - no knob can bill a different figure' (-not $planParams.ContainsKey('GstPercent') -and -not $planParams.ContainsKey('RateIncludesGst'))
foreach ($c in $cases) {
    $p = Get-MtReorderPlan -Order $c.order
    $e = $c.expect
    Check ("{0} -> {1}" -f $c.why, $e.state) ($p.State -eq $e.state) $p.State
    if ($e.PSObject.Properties['basis']) {
        Check ("  billed on what was {0}" -f $e.basis) ($p.Basis -eq $e.basis) $p.Basis
    }
    if ($e.PSObject.Properties['lines']) {
        $want = @($e.lines)
        Check ("  {0} line(s) on the Manna Treads order" -f $want.Count) ($p.Lines.Count -eq $want.Count) "$($p.Lines.Count)"
        for ($i = 0; $i -lt [math]::Min($want.Count, $p.Lines.Count); $i++) {
            $w = $want[$i]; $g = $p.Lines[$i]
            $ok = ($g.Item -eq $w.item) -and (Near $g.Kg $w.kg) -and (Near $g.Rate $w.rate) -and
                  (Near $g.Amount $w.amount) -and (Near $g.UnitPriceNet $w.unit_price_net)
            Check ("  {0}: {1} kg at {2} = {3}, sent to SAP at {4} net of GST" -f $w.item, $w.kg, $w.rate, $w.amount, $w.unit_price_net) $ok `
                  ("{0}: {1} kg at {2} = {3}, {4}" -f $g.Item, $g.Kg, $g.Rate, $g.Amount, $g.UnitPriceNet)
        }
    }
    if ($e.PSObject.Properties['total']) {
        Check ("  total {0}" -f $e.total) (Near $p.Total $e.total) "$($p.Total)"
    }
}

# ------------------------------------------------------------------------------
Write-Host "`nThe rule beyond the fixture's cases" -ForegroundColor Cyan

function OrderOf { param($Lines, $Status = 'bost_Close', $Requested = $false, $Err = '')
    [pscustomobject]@{ sap_sales_order = '425'; sap_status = $Status; customer_mt_code = 'ZZ-TEST-A'
                       mt_sales_order = ''; mt_requested = $Requested; mt_error = $Err; lines = @($Lines) }
}
function LineOf { param($Item, $Ordered, $Amount, $Rpk, $Dlv, $Inv = 0, $Refs = '')
    [pscustomobject]@{ item = $Item; ordered_kg = $Ordered; amount = $Amount; rate_per_kg = $Rpk; delivered_kg = $Dlv; invoiced_kg = $Inv; refs = $Refs }
}

$r = Get-RoundedHalfUp 10272.625 2
Check 'a midpoint rounds half UP, as the dashboard does (10,272.625 -> 10,272.63)' (Near $r 10272.63) "$r"
Check '  where [math]::Round would round it to EVEN (10,272.62) - why it is not used' (Near ([math]::Round(10272.625, 2)) 10272.62)

# The review finding: the raw double of 6029.7 / 60 is 100.49499999999999.
$raw = 6029.7 / 60
Check 'the double of 6029.7 / 60 sits just under the midpoint (why the raw double cannot be rounded)' ($raw -lt 100.495) ('{0:R}' -f $raw)
$r = Get-RoundedHalfUp $raw 2
Check '  and it still rounds to 100.50, as the decimal 100.495 does'  ("$r" -eq '100.5') ('{0:R}' -f $r)

# What the dashboard's roundTo returns for these, bit for bit (26 Sep 2026,
# checked against the TypeScript on 140,120 values - see the report of that day).
$roundTo = @(
    @(10272.625, 2, 10272.63), @(3721.275, 2, 3721.28), @(1.005, 2, 1.01), @(2.675, 2, 2.68),
    @((55.555 * 199), 2, 11055.45), @(0.125, 2, 0.13), @(-2.5, 0, -3), @(-100.495, 2, -100.5),
    @((20.1 + 30.2), 3, 50.3), @((199 / 1.18), 6, 168.644068), @((100.5 / 1.18), 6, 85.169492),
    @(0.0000005, 6, 0.000001), @(0, 2, 0), @(123456789.125, 2, 123456789.13), @(1234.5675, 3, 1234.568)
)
foreach ($t in $roundTo) {
    $g = Get-RoundedHalfUp $t[0] $t[1]
    Check ("roundTo({0:R}, {1}) is {2}" -f ([double]$t[0]), $t[1], $t[2]) ([double]$g -eq [double]$t[2]) ('{0:R}' -f $g)
}
Check 'a value that is not a number rounds to 0, as roundTo does' ((Get-RoundedHalfUp ([double]::NaN) 2) -eq 0 -and (Get-RoundedHalfUp ([double]::PositiveInfinity) 2) -eq 0)

$p = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 100 17050 170.5 60.25)))
Check 'the midpoint rule reaches the line amount (60.25 kg at 170.50)' (Near $p.Lines[0].Amount 10272.63) "$($p.Lines[0].Amount)"

$p = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 6029.7 100.5 60)))
Check 'the midpoint rule reaches the rate (6029.70 over 60 kg is 100.50, never 100.49)' (Near $p.Lines[0].Rate 100.5) "$($p.Lines[0].Rate)"

$p = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 20.0004)))
Check 'billed kilos are taken to 3 decimals, as the dashboard takes them' (Near $p.Lines[0].Kg 20) "$($p.Lines[0].Kg)"
$p = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 0.0004 5)))
Check '  and a delivery that rounds to nothing is no delivery: the invoice basis' ($p.Basis -eq 'invoiced' -and (Near $p.Lines[0].Kg 5)) "$($p.Basis) / $($p.Lines[0].Kg)"

$p = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 0 0 200 10)))
Check 'no ordered kilos to divide by: the line rate_per_kg is the price' (Near $p.Lines[0].Rate 200) "$($p.Lines[0].Rate)"

$p = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 20.1), (LineOf 'I-14640' 36 6120 170 30.2)))
Check 'the total carries no floating-point tail' ("$($p.Total)" -eq '9133.9') "$($p.Total)"

$p = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 60)) -Requested $true -Err '')
Check 'the lines are worked out for a queued order too - PASS C needs them' ($p.State -eq 'queued' -and $p.Lines.Count -eq 1) "$($p.State) / $($p.Lines.Count)"

$p = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 60)) -Status 'bost_Open' -Requested $true)
Check 'asked for but reopened at Hi-Tech: at_hitech outranks queued' ($p.State -eq 'at_hitech') $p.State

# An ERPNext order as PASS C reads it.
$erpDoc = [pscustomobject]@{
    custom_sap_sales_order = '425'; custom_sap_sales_order_status = 'bost_Close'
    custom_mt_sales_order = $null; custom_mt_so_requested = 1; custom_mt_sync_error = $null
    items = @(
        [pscustomobject]@{ name = 'r1'; item_code = 'I-14636'; qty = 2; custom_total_weight = 60; amount = 11940; custom_rate_per_kg = 199
                           custom_hitech_delivered_kg = 55.5; custom_hitech_invoiced_kg = 0; custom_hitech_delivery_refs = 'DN 4 (18-09-2026)' }
    )
}
$in = ConvertTo-MtReorderInput -Doc $erpDoc -BpCode 'ZZ-TEST-A'
$p  = Get-MtReorderPlan -Order $in
Check 'an ERPNext order reads into the rule: Check field 1 is asked for' ($p.State -eq 'queued') $p.State
Check '  ordered kilos are custom_total_weight, never qty (which is rolls)' (Near $in.lines[0].ordered_kg 60) "$($in.lines[0].ordered_kg)"
Check '  billed on custom_hitech_delivered_kg' (Near $p.Lines[0].Kg 55.5) "$($p.Lines[0].Kg)"
Check '  the delivery refs travel with the line' ($p.Lines[0].Refs -eq 'DN 4 (18-09-2026)') $p.Lines[0].Refs
$in = ConvertTo-MtReorderInput -Doc $erpDoc -BpCode 'null'
Check "  a code read back as 'null' is no code" ($in.customer_mt_code -eq '') $in.customer_mt_code

# ------------------------------------------------------------------------------
Write-Host "`nWhich SAP documents count" -ForegroundColor Cyan

function Doc { param($CancelStatus, $Cancelled)
    $o = [pscustomobject]@{ DocEntry = 1 }
    if ($null -ne $CancelStatus) { $o | Add-Member -NotePropertyName CancelStatus -NotePropertyValue $CancelStatus }
    $o | Add-Member -NotePropertyName Cancelled -NotePropertyValue $Cancelled
    $o
}
Check 'a live delivery (csNo) counts'                       (Test-SapDocumentCounts (Doc 'csNo' 'tNO'))
Check 'a cancelled delivery (csYes) does not'               (-not (Test-SapDocumentCounts (Doc 'csYes' 'tYES')))
Check 'its reversal (csCancellation, Cancelled null) does not' (-not (Test-SapDocumentCounts (Doc 'csCancellation' $null)))
Check 'read without CancelStatus: a live invoice counts'    (Test-SapDocumentCounts (Doc $null 'tNO'))
Check 'read without CancelStatus: a cancelled one does not' (-not (Test-SapDocumentCounts (Doc $null 'tYES')))

# ------------------------------------------------------------------------------
Write-Host "`nDelivered kilos, per sales-order line" -ForegroundColor Cyan

function DocLine { param($BaseType, $BaseEntry, $BaseLine, $Qty, $Item = 'I-14636')
    [pscustomobject]@{ BaseType = $BaseType; BaseEntry = $BaseEntry; BaseLine = $BaseLine; Quantity = $Qty; ItemCode = $Item }
}
function Dn { param($DocEntry, $DocNum, $DocDate, $CancelStatus, $Cancelled, $Lines)
    [pscustomobject]@{ DocEntry = $DocEntry; DocNum = $DocNum; DocDate = $DocDate; CancelStatus = $CancelStatus; Cancelled = $Cancelled; DocumentLines = @($Lines) }
}

$dnKg = @{}; $dnRefs = @{}
# DN 4 carries two sales orders (2900 line 0 and 2901 line 0); DN 5 is a second
# delivery on 2900 line 0; DN 6 was cancelled and DN 7 is its reversal.
$dns = @(
    (Dn 104 4 '2026-09-18T00:00:00Z' 'csNo' 'tNO' @((DocLine 17 2900 0 20), (DocLine 17 2901 0 30 'I-14640'))),
    (Dn 105 5 '2026-09-20' 'csNo' 'tNO' @((DocLine 17 2900 0 15.5))),
    (Dn 106 6 '2026-09-21' 'csYes' 'tYES' @((DocLine 17 2900 1 40 'I-14638'))),
    (Dn 107 7 '2026-09-21' 'csCancellation' $null @((DocLine 15 106 0 40 'I-14638'))),
    (Dn 108 8 '2026-09-22' 'csNo' 'tNO' @((DocLine 15 999 0 12)))
)
$counted = @($dns | ForEach-Object { Add-HitechDeliveredKg -DeliveryNote $_ -KgByLine $dnKg -RefsByLine $dnRefs })
Check 'the cancelled delivery and its reversal are refused, the rest taken' (($counted -join ',') -eq 'True,True,False,False,True') ($counted -join ',')
Check 'two deliveries on one line are summed (20 + 15.5)'        (Near $dnKg['2900|0'] 35.5) "$($dnKg['2900|0'])"
Check 'one delivery across two orders is split by its lines'      (Near $dnKg['2901|0'] 30) "$($dnKg['2901|0'])"
Check 'the cancelled delivery adds nothing to its line'           (-not $dnKg.ContainsKey('2900|1'))
Check 'nothing based on a delivery (BaseType 15) is a delivered line' ($dnKg.Count -eq 2) ("keys: " + (($dnKg.Keys | Sort-Object) -join ' '))
Check 'the refs name both deliveries, in order, dated dd-mm-yyyy' ((($dnRefs['2900|0']) -join ', ') -eq 'DN 4 (18-09-2026), DN 5 (20-09-2026)') (($dnRefs['2900|0']) -join ', ')
Check '  and the other order names only the delivery it was on'      ((($dnRefs['2901|0']) -join ', ') -eq 'DN 4 (18-09-2026)') (($dnRefs['2901|0']) -join ', ')

# ------------------------------------------------------------------------------
Write-Host "`nInvoiced kilos - straight from the order only" -ForegroundColor Cyan

function Inv { param($Cancelled, $Lines) [pscustomobject]@{ DocEntry = 1; DocNum = 1; Cancelled = $Cancelled; DocumentLines = @($Lines) } }
$invKg = @{}
$a = Add-HitechInvoicedKg -Invoice (Inv 'tNO'  @((DocLine 17 2902 0 34.2 'I-14640'), (DocLine 15 104 0 20))) -KgByLine $invKg
$b = Add-HitechInvoicedKg -Invoice (Inv 'tNO'  @((DocLine 17 2902 0 1.8 'I-14640'))) -KgByLine $invKg
$x = Add-HitechInvoicedKg -Invoice (Inv 'tYES' @((DocLine 17 2902 1 99 'I-14641'))) -KgByLine $invKg
Check 'two invoices on one line are summed (34.2 + 1.8)'                    (Near $invKg['2902|0'] 36) "$($invKg['2902|0'])"
Check 'a line invoiced from a delivery (BaseType 15) is not a direct invoice' (-not $invKg.ContainsKey('104|0') -and -not $invKg.ContainsKey('2900|0'))
Check 'a cancelled invoice is refused and adds nothing'                     ($a -and $b -and -not $x -and -not $invKg.ContainsKey('2902|1'))

# ------------------------------------------------------------------------------
Write-Host "`nGet-HitechKgUpdates - SAP line to ERPNext row, written only when it moves" -ForegroundColor Cyan

function SoLine { param($LineNum, $Item) [pscustomobject]@{ LineNum = $LineNum; ItemCode = $Item } }
function Row { param($Name, $Item, $Dlv = $null, $Inv = $null, $Refs = $null)
    [pscustomobject]@{ name = $Name; item_code = $Item; custom_hitech_delivered_kg = $Dlv; custom_hitech_invoiced_kg = $Inv; custom_hitech_delivery_refs = $Refs }
}
function UpdFor { param($Plan, $Item) $Plan.Updates | Where-Object { $_.ItemCode -eq $Item } | Select-Object -First 1 }

# SAP line numbers listed out of item order: the match is LineNum -> ItemCode, not position.
$so2900 = @((SoLine 1 'I-14638'), (SoLine 0 'I-14636'))
$u = Get-HitechKgUpdates -SapLines $so2900 -ErpItems @((Row 'r1' 'I-14636'), (Row 'r2' 'I-14638')) -SoEntry '2900' `
        -DeliveredKg $dnKg -InvoicedKg $invKg -DeliveryRefs $dnRefs
$a = UpdFor $u 'I-14636'
Check 'a delivered line gets its kilos, through BaseLine -> LineNum -> item' ($a -and (Near $a.Fields['custom_hitech_delivered_kg'] 35.5)) "$($a.Fields['custom_hitech_delivered_kg'])"
Check '  and its delivery refs'                                  ($a -and $a.Fields['custom_hitech_delivery_refs'] -eq 'DN 4 (18-09-2026), DN 5 (20-09-2026)') "$($a.Fields['custom_hitech_delivery_refs'])"
Check '  and no invoiced figure, since 0 is what an empty field reads' ($a -and -not $a.Fields.ContainsKey('custom_hitech_invoiced_kg'))
Check '  and it names the ERPNext row'                             ($a -and $a.RowName -eq 'r1') "$($a.RowName)"
Check 'a line only a cancelled delivery touched is not written at all' ($null -eq (UpdFor $u 'I-14638'))

$u = Get-HitechKgUpdates -SapLines $so2900 -ErpItems @((Row 'r1' 'I-14636' 35.5004 0 'DN 4 (18-09-2026), DN 5 (20-09-2026)')) -SoEntry '2900' `
        -DeliveredKg $dnKg -InvoicedKg $invKg -DeliveryRefs $dnRefs
Check 'within 0.0005 kg and the same refs: nothing written' ($u.Updates.Count -eq 0) "$($u.Updates.Count) update(s)"

$u = Get-HitechKgUpdates -SapLines @((SoLine 0 'I-14640')) -ErpItems @((Row 'r3' 'I-14640')) -SoEntry '2901' `
        -DeliveredKg $dnKg -InvoicedKg $invKg -DeliveryRefs $dnRefs
$a = UpdFor $u 'I-14640'
Check 'the other order on the same delivery gets its own 30 kg' ($a -and (Near $a.Fields['custom_hitech_delivered_kg'] 30)) "$($a.Fields['custom_hitech_delivered_kg'])"

$u = Get-HitechKgUpdates -SapLines @((SoLine 0 'I-14640')) -ErpItems @((Row 'r4' 'I-14640')) -SoEntry '2902' `
        -DeliveredKg $dnKg -InvoicedKg $invKg -DeliveryRefs $dnRefs
$a = UpdFor $u 'I-14640'
Check 'an order invoiced straight from the sales order gets its invoiced kilos' ($a -and (Near $a.Fields['custom_hitech_invoiced_kg'] 36)) "$($a.Fields['custom_hitech_invoiced_kg'])"
Check '  and no delivered figure'                                                ($a -and -not $a.Fields.ContainsKey('custom_hitech_delivered_kg'))

# The live bug this fixes: 75.5 recorded while the cancelled DN 6 still counted.
$u = Get-HitechKgUpdates -SapLines $so2900 -ErpItems @((Row 'r1' 'I-14636' 75.5 0 'DN 4 (18-09-2026), DN 5 (20-09-2026), DN 6 (21-09-2026)')) -SoEntry '2900' `
        -DeliveredKg $dnKg -InvoicedKg $invKg -DeliveryRefs $dnRefs
$a = UpdFor $u 'I-14636'
Check 'a delivery cancelled since is taken back off the line' ($a -and (Near $a.Fields['custom_hitech_delivered_kg'] 35.5)) "$($a.Fields['custom_hitech_delivered_kg'])"

$u = Get-HitechKgUpdates -SapLines $so2900 -ErpItems @((Row 'r1' 'I-14636' 75.5 0 'DN 1 (01-04-2026)')) -SoEntry '2900' `
        -DeliveredKg $dnKg -InvoicedKg $invKg -DeliveryRefs $dnRefs -DeliveryScanComplete $false
Check 'an order older than the delivery scan keeps what was recorded' ($u.Updates.Count -eq 0) "$($u.Updates.Count) update(s)"
Check '  and says so'                                                  (@($u.Skips | Where-Object { $_.Note -match 'older than the delivery scan' }).Count -eq 1)

$dust = @{ '2903|0' = (20.1 + 30.2) }
$u = Get-HitechKgUpdates -SapLines @((SoLine 0 'I-14636')) -ErpItems @((Row 'r5' 'I-14636')) -SoEntry '2903' -DeliveredKg $dust
$a = UpdFor $u 'I-14636'
Check 'kilos are written to 3 decimals, without a floating-point tail' ($a -and "$($a.Fields['custom_hitech_delivered_kg'])" -eq '50.3') "$($a.Fields['custom_hitech_delivered_kg'])"

$u = Get-HitechKgUpdates -SapLines @((SoLine 0 'I-14636'), (SoLine 1 'I-14636')) -ErpItems @((Row 'r1' 'I-14636')) -SoEntry '2900' -DeliveredKg $dnKg
Check 'an item on two SAP lines is skipped, not guessed at' ($u.Updates.Count -eq 0 -and $u.Skips.Count -eq 1) "$($u.Updates.Count) / $($u.Skips.Count)"
$u = Get-HitechKgUpdates -SapLines $so2900 -ErpItems @((Row 'r1' 'I-14636'), (Row 'r9' 'I-14636')) -SoEntry '2900' -DeliveredKg $dnKg
Check 'an item on two ERPNext rows is skipped too'          ($u.Updates.Count -eq 0 -and $u.Skips.Count -eq 2) "$($u.Updates.Count) / $($u.Skips.Count)"
$u = Get-HitechKgUpdates -SapLines $so2900 -ErpItems @((Row 'r7' 'I-99999' 5)) -SoEntry '2900' -DeliveredKg $dnKg
Check 'a row whose item is not on the SAP order is left to the reconcile' ($u.Updates.Count -eq 0 -and $u.Skips.Count -eq 0)

# ------------------------------------------------------------------------------
Write-Host "`nSettings - every default in code" -ForegroundColor Cyan

$s = Get-MtSettings -Config ([pscustomobject]@{})
Check 'no manna_treads block: enabled, MANNA_TREADS_LIVE' ($s.Enabled -and $s.CompanyDb -eq 'MANNA_TREADS_LIVE')
Check '  Series 189 - what every Manna Treads Sales Order carries (DocNum 437-439, read 26 Sep 2026)' ($s.Series -eq 189) "$($s.Series)"
Check '  branch 1, warehouse 01, tax CG+SG@18, location 2' ($s.BplId -eq 1 -and $s.Warehouse -eq '01' -and $s.TaxCode -eq 'CG+SG@18' -and $s.LocationCode -eq 2)
Check '  Kerala only'                                      (($s.AllowedBillToStates -join ',') -eq 'KL')
Check '  only the ten SYNC TEST items, I-14636..I-14645'   (($s.ItemAllowlist -join ',') -eq 'I-14636,I-14637,I-14638,I-14639,I-14640,I-14641,I-14642,I-14643,I-14644,I-14645') ($s.ItemAllowlist -join ',')
Check '  no GST settings at all - GST is fixed in code'    (-not $s.ContainsKey('GstPercent') -and -not $s.ContainsKey('RateIncludesGst'))
Check '  the sap login'                                    ($s.Username -eq '' -and $s.Password -eq '')
Check '  only the accountant approves (jineesh@mannarubber.com, the one custom_is_accountant user)' (($s.Approvers -join ',') -eq 'jineesh@mannarubber.com') ($s.Approvers -join ',')
$sa = Get-MtSettings -Config ('{ "manna_treads": { "approvers": [" Jineesh@MannaRubber.com ", "it@mannarubber.com", "IT@mannarubber.com"] } }' | ConvertFrom-Json)
Check 'approvers replace the default, lower-cased, trimmed, once each' (($sa.Approvers -join ',') -eq 'jineesh@mannarubber.com,it@mannarubber.com') ($sa.Approvers -join ',')
$sa = Get-MtSettings -Config ('{ "manna_treads": { "approvers": [] } }' | ConvertFrom-Json)
Check '  an empty approvers list accepts nobody'          (@($sa.Approvers).Count -eq 0) ($sa.Approvers -join ',')

$cfg = '{ "manna_treads": { "series": null, "location_code": null, "allowed_bill_to_states": ["kl", " tn "], "enabled": false, "item_allowlist": [" I-14636 ", "I-20001", "I-20001"] } }' | ConvertFrom-Json
$s2 = Get-MtSettings -Config $cfg
Check 'a series set to null is left off (SAP picks the branch default)' ($null -eq $s2.Series) "$($s2.Series)"
Check 'a key present as null is left off the order'  ($null -eq $s2.LocationCode) "$($s2.LocationCode)"
Check 'states are compared upper-case and trimmed'   (($s2.AllowedBillToStates -join ',') -eq 'KL,TN') ($s2.AllowedBillToStates -join ',')
Check 'enabled: false switches PASS C off'           (-not $s2.Enabled)
Check 'item_allowlist replaces the default, trimmed and once each' (($s2.ItemAllowlist -join ',') -eq 'I-14636,I-20001') ($s2.ItemAllowlist -join ',')
$s3 = Get-MtSettings -Config ('{ "manna_treads": { "item_allowlist": [], "series": 190 } }' | ConvertFrom-Json)
Check 'an empty item_allowlist allows nothing'       (@($s3.ItemAllowlist).Count -eq 0) ($s3.ItemAllowlist -join ',')
Check 'another series may be configured'             ($s3.Series -eq 190) "$($s3.Series)"

$threw = $false; try { $null = Get-MtSettings -Config ('{ "manna_treads": { "username": "PUT_SAP_USER", "password": "x" } }' | ConvertFrom-Json) } catch { $threw = $true }
Check 'a placeholder login is refused'               $threw
$threw = $false; try { $null = Get-MtSettings -Config ('{ "manna_treads": { "username": "someone" } }' | ConvertFrom-Json) } catch { $threw = $true }
Check 'a username without its password is refused'   $threw
$threw = $false; try { $null = Get-MtSettings -Config ('{ "manna_treads": { "gst_percent": 12 } }' | ConvertFrom-Json) } catch { $threw = $true }
Check 'a gst_percent other than 18 is refused, not obeyed' $threw
$threw = $false; try { $null = Get-MtSettings -Config ('{ "manna_treads": { "rate_includes_gst": false } }' | ConvertFrom-Json) } catch { $threw = $true }
Check 'rate_includes_gst false is refused, not obeyed'     $threw
$threw = $false; try { $null = Get-MtSettings -Config ('{ "manna_treads": { "gst_percent": 18, "rate_includes_gst": true } }' | ConvertFrom-Json) } catch { $threw = $true }
Check '  the two keys left over from the old example, agreeing, are harmless' (-not $threw)

# ------------------------------------------------------------------------------
Write-Host "`nNew-MtSalesOrderBody - what is posted to Manna Treads" -ForegroundColor Cyan

$full = Get-MtReorderPlan -Order (OrderOf @(
            (LineOf 'I-14636' 60 11940 199 60 0 'DN 4 (18-09-2026), DN 5 (20-09-2026)'),
            (LineOf 'I-14640' 36 6120 170 36 0 'DN 5 (20-09-2026)')))
$body = New-MtSalesOrderBody -Plan $full -CardCode 'ZZ-TEST-A' -OrderName 'SAL-ORD-2026-00150' -HitechSalesOrder '425' -DocDate '2026-09-26' -Settings $s
$l0 = $body.DocumentLines[0]
Check 'to the end customer'                                ($body.CardCode -eq 'ZZ-TEST-A') $body.CardCode
Check 'the ERPNext order name in NumAtCard'                ($body.NumAtCard -eq 'SAL-ORD-2026-00150') $body.NumAtCard
Check 'dated today, both dates (never back-dated)'         ($body.DocDate -eq '2026-09-26' -and $body.DocDueDate -eq '2026-09-26')
Check 'the Kerala branch'                                  ($body.BPL_IDAssignedToInvoice -eq 1) "$($body.BPL_IDAssignedToInvoice)"
Check 'Series 189, by default'                             ($body.Series -eq 189) "$($body.Series)"
Check 'no SalesPersonCode - SAP takes the customer default' (-not $body.Contains('SalesPersonCode'))
Check 'DiscountPercent 0 on the header - SAP may not fill one from the customer' ($body.Contains('DiscountPercent') -and $body.DiscountPercent -eq 0) "$($body.DiscountPercent)"
$lineDisc = @($body.DocumentLines | ForEach-Object { if ($_.Contains('DiscountPercent')) { [double]$_.DiscountPercent } else { 'absent' } })
Check '  and on EVERY line - nor from special prices or discount groups' ($lineDisc.Count -eq 2 -and (($lineDisc -join ',') -eq '0,0')) ($lineDisc -join ',')
$json = $body | ConvertTo-Json -Depth 8 -Compress
Check '  and all three reach the JSON posted'                (([regex]::Matches($json, '"DiscountPercent":0[,}]')).Count -eq 3) $json
Check 'UnitPrice is the rate NET of GST (199 -> 168.644068)' (Near $l0.UnitPrice 168.644068) "$($l0.UnitPrice)"
Check '  never the gross rate'                             (-not (Near $l0.UnitPrice 199))
Check '  with the tax code that adds it back'              ($l0.TaxCode -eq 'CG+SG@18') $l0.TaxCode
Check '  from warehouse 01, location 2'                    ($l0.WarehouseCode -eq '01' -and $l0.LocationCode -eq 2)
Check '  in kilos'                                         (Near $l0.Quantity 60) "$($l0.Quantity)"
Check 'the comment names the ERPNext order, the Hi-Tech SO and each delivery once' `
      ($body.Comments -eq 'From ERPNext SAL-ORD-2026-00150 - Hi-Tech SO 425 - DN 4 (18-09-2026), DN 5 (20-09-2026)') $body.Comments

$short = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 60), (LineOf 'I-14638' 100.8 20160 200 0)))
$b2 = New-MtSalesOrderBody -Plan $short -CardCode 'ZZ-TEST-B' -OrderName 'SAL-ORD-2026-00151' -HitechSalesOrder '431' -DocDate '2026-09-26' -Settings $s
Check 'a line Hi-Tech never delivered is not on the order' (@($b2.DocumentLines).Count -eq 1 -and $b2.DocumentLines[0].ItemCode -eq 'I-14636') ("$(@($b2.DocumentLines).Count) line(s)")
Check '  and one line still posts as a JSON array'         (($b2 | ConvertTo-Json -Depth 8 -Compress) -match '"DocumentLines":\[')
Check '  with no refs, the comment stops at the Hi-Tech SO' ($b2.Comments -eq 'From ERPNext SAL-ORD-2026-00151 - Hi-Tech SO 431') $b2.Comments

$manyRefs = (1..40 | ForEach-Object { "DN $_ (18-09-2026)" }) -join ', '
$long = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 60 0 $manyRefs)))
$b3 = New-MtSalesOrderBody -Plan $long -CardCode 'ZZ-TEST-A' -OrderName 'SAL-ORD-2026-00152' -HitechSalesOrder '425' -DocDate '2026-09-26' -Settings $s2
Check 'a long comment is cut to the 254 characters SAP holds' ($b3.Comments.Length -eq 254 -and $b3.Comments.EndsWith('...')) "$($b3.Comments.Length)"
Check 'a Series configured as null is left off'              (-not $b3.Contains('Series'))
Check 'a location set to null is left off the line'          (-not $b3.DocumentLines[0].Contains('LocationCode'))
Check '  and the line still carries DiscountPercent 0'       ($b3.DocumentLines[0].Contains('DiscountPercent') -and $b3.DocumentLines[0].DiscountPercent -eq 0)

# ------------------------------------------------------------------------------
Write-Host "`nREFUSALS - what PASS C will not create" -ForegroundColor Yellow

function PlanIn { param($State, $Lines = @(@{ Item = 'I-14636'; Rate = 199 })) @{ State = $State; Lines = $Lines } }
$v = Get-MtPlanRefusal -Plan (PlanIn 'queued') -CustomerCode 'ZZ-TEST-A' -Unit 'Manna Treads'
Check 'queued, with a customer code: created'              ($v.Action -eq 'create') $v.Action
$v = Get-MtPlanRefusal -Plan (PlanIn 'failed') -CustomerCode 'ZZ-TEST-A'
Check 'failed last time: NOT retried by the sync - it waits for Try again' ($v.Action -eq 'skip') $v.Action
$v = Get-MtPlanRefusal -Plan (PlanIn 'queued') -CustomerCode ''
Check 'no Manna Treads customer code: refused, naming the field' ($v.Action -eq 'refuse' -and $v.Message -match 'custom_bp_code') $v.Message
$v = Get-MtPlanRefusal -Plan (PlanIn 'queued') -CustomerCode 'ZZ-TEST-A' -Unit 'Manna Tyre Retreads'
Check "another unit's order is not Manna Treads' to invoice" ($v.Action -eq 'refuse') $v.Message
$v = Get-MtPlanRefusal -Plan (PlanIn 'queued' @(@{ Item = 'I-14636'; Rate = 0 })) -CustomerCode 'ZZ-TEST-A'
Check 'a line with no approved price is refused, not priced by SAP' ($v.Action -eq 'refuse' -and $v.Message -match 'I-14636') $v.Message
$v = Get-MtPlanRefusal -Plan (PlanIn 'at_hitech') -CustomerCode 'ZZ-TEST-A' -HitechStatus 'bost_Open'
Check 'reopened at Hi-Tech: refused, saying the status'    ($v.Action -eq 'refuse' -and $v.Message -match 'bost_Open') $v.Message
$v = Get-MtPlanRefusal -Plan (PlanIn 'nothing_delivered') -CustomerCode 'ZZ-TEST-A'
Check 'nothing delivered: refused'                         ($v.Action -eq 'refuse') $v.Message
$v = Get-MtPlanRefusal -Plan (PlanIn 'cancelled') -CustomerCode 'ZZ-TEST-A'
Check 'cancelled at Hi-Tech: refused'                      ($v.Action -eq 'refuse') $v.Message
$v = Get-MtPlanRefusal -Plan (PlanIn 'created') -CustomerCode 'ZZ-TEST-A'
Check 'already created: skipped with nothing written'      ($v.Action -eq 'skip') $v.Action
$v = Get-MtPlanRefusal -Plan (PlanIn 'ready') -CustomerCode 'ZZ-TEST-A'
Check 'not asked for: skipped'                             ($v.Action -eq 'skip') $v.Action
Check 'no refusal is marked hard any more - none fails the run' (-not $v.ContainsKey('Hard'))

# ---- an item on two lines (S4) ----
function ErpItem { param($Code, $Name = '') [pscustomobject]@{ item_code = $Code; item_name = $Name } }
$m = Test-MtDuplicateLines -Items @((ErpItem 'I-14636'), (ErpItem 'I-14640'))
Check 'every item on one line: nothing to say'             ($m -eq '') $m
$m = Test-MtDuplicateLines -Items @((ErpItem 'I-14636'), (ErpItem 'I-14640'), (ErpItem 'I-14636'))
Check 'an item on two lines is refused, in the words agreed' ($m -eq "I-14636 is on two lines of this order; Hi-Tech's kilos cannot be split between them - raise it in SAP by hand.") $m
$m = Test-MtDuplicateLines -Items @((ErpItem 'I-14636'), (ErpItem 'i-14636 '), (ErpItem 'I-14636'))
Check '  three lines, case and spaces aside, say three'      ($m -match '^I-14636 is on 3 lines') $m

# Why it must refuse: PASS B writes no kilos for the doubled item, so the plan
# drops both rows as "nothing delivered" and the order would post short.
$dupDoc = [pscustomobject]@{
    custom_sap_sales_order = '425'; custom_sap_sales_order_status = 'bost_Close'
    custom_mt_sales_order = ''; custom_mt_so_requested = 1; custom_mt_sync_error = ''
    items = @(
        [pscustomobject]@{ name = 'r1'; item_code = 'I-14636'; item_name = 'A'; custom_total_weight = 60; amount = 11940; custom_rate_per_kg = 199; custom_hitech_delivered_kg = 0 },
        [pscustomobject]@{ name = 'r2'; item_code = 'I-14640'; item_name = 'B'; custom_total_weight = 36; amount = 6120;  custom_rate_per_kg = 170; custom_hitech_delivered_kg = 36 },
        [pscustomobject]@{ name = 'r3'; item_code = 'I-14636'; item_name = 'A'; custom_total_weight = 30; amount = 5970;  custom_rate_per_kg = 199; custom_hitech_delivered_kg = 0 }
    )
}
$dupPlan = Get-MtReorderPlan -Order (ConvertTo-MtReorderInput -Doc $dupDoc -BpCode 'ZZ-TEST-A')
Check '  (the plan alone would bill one line and look fine)'  ($dupPlan.State -eq 'queued' -and $dupPlan.Lines.Count -eq 1) "$($dupPlan.State) / $($dupPlan.Lines.Count)"
$pre = Get-MtPreSapRefusal -Plan $dupPlan -Items $dupDoc.items -CustomerCode 'ZZ-TEST-A' -Unit 'Manna Treads' -Allowlist $s.ItemAllowlist
Check '  so the whole order is refused - never posted with the lines dropped' ($pre.Action -eq 'refuse' -and $pre.Message -match 'I-14636 is on two lines') $pre.Message

# ---- the allowlist (S3a) ----
$m = Test-MtAllowedItems -Codes @('I-14636', 'I-14645') -Allowlist $s.ItemAllowlist
Check 'the SYNC TEST items are allowed'                    ($m -eq '') $m
$m = Test-MtAllowedItems -Codes @('I-14636', 'I-11688') -Allowlist $s.ItemAllowlist
Check 'any other item is refused, in the words agreed'     ($m -eq 'I-11688 is not set up for Manna Treads sales orders yet.') $m
$m = Test-MtAllowedItems -Codes @('I-11688', 'I-11690') -Allowlist $s.ItemAllowlist
Check '  two of them, in one message'                      ($m -eq 'I-11688, I-11690 are not set up for Manna Treads sales orders yet.') $m
$m = Test-MtAllowedItems -Codes @('I-14636') -Allowlist @()
Check '  an empty allowlist allows nothing'                ($m -match 'I-14636 is not set up') $m
$m = Test-MtAllowedItems -Codes @('i-20001') -Allowlist $s2.ItemAllowlist
Check '  a configured list is used, case aside'            ($m -eq '') $m
$okPlan = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-11688' 60 11940 199 60)) -Requested $true)
$pre = Get-MtPreSapRefusal -Plan $okPlan -Items @((ErpItem 'I-11688')) -CustomerCode 'ZZ-TEST-A' -Unit 'Manna Treads' -Allowlist $s.ItemAllowlist
Check '  and the ERPNext-side verdict carries it'          ($pre.Action -eq 'refuse' -and $pre.Message -match 'I-11688 is not set up') $pre.Message
$okPlan = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 60), (LineOf 'I-11688' 60 11940 199 0)) -Requested $true)
$pre = Get-MtPreSapRefusal -Plan $okPlan -Items @((ErpItem 'I-14636'), (ErpItem 'I-11688')) -CustomerCode 'ZZ-TEST-A' -Unit 'Manna Treads' -Allowlist $s.ItemAllowlist
Check '  an item not billed (nothing delivered) is not asked about' ($pre.Action -eq 'create') "$($pre.Action) $($pre.Message)"
$pre = Get-MtPreSapRefusal -Plan (PlanIn 'at_hitech') -Items @((ErpItem 'I-11688')) -CustomerCode 'ZZ-TEST-A' -HitechStatus 'bost_Open' -Allowlist $s.ItemAllowlist
Check "  Hi-Tech's state is told first"                    ($pre.Action -eq 'refuse' -and $pre.Message -match 'not closed') $pre.Message

# ---- Manna Treads SAP's own item: live, and the same product (S3b) ----
function Itm { param($Code, $Valid = 'tYES', $Frozen = 'tNO', $Sales = 'tYES', $Name = 'TREAD RUBBER TEST')
    [pscustomobject]@{ ItemCode = $Code; ItemName = $Name; Valid = $Valid; Frozen = $Frozen; SalesItem = $Sales }
}
$nm = @{ 'I-14636' = 'TREAD RUBBER TEST'; 'I-14640' = 'TREAD RUBBER TEST' }
$m = Test-MtItems -Codes @('I-14636', 'I-14640') -Rows @((Itm 'I-14636'), (Itm 'I-14640')) -Names $nm
Check 'every item a live sales item of the same name in Manna Treads: nothing to say' ($m -eq '') $m
$m = Test-MtItems -Codes @('I-14636', 'I-11688') -Rows @((Itm 'I-14636')) -Names $nm
Check 'an item Manna Treads SAP does not have is named'       ($m -eq 'Item I-11688 is not in Manna Treads SAP - no item mapping yet') $m
$m = Test-MtItems -Codes @('I-11688', 'I-11690') -Rows @() -Names $nm
Check '  all of them, in one message'                          ($m -eq 'Items I-11688, I-11690 are not in Manna Treads SAP - no item mapping yet') $m
$m = Test-MtItems -Codes @('I-14636') -Rows @((Itm 'I-14636' 'tYES' 'tYES')) -Names $nm
Check 'a frozen item is refused'                               ($m -match 'I-14636' -and $m -match 'frozen') $m
$m = Test-MtItems -Codes @('I-14636') -Rows @((Itm 'I-14636' 'tYES' 'tNO' 'tNO')) -Names $nm
Check 'an item that is not a sales item is refused'            ($m -match 'not a sales item') $m
$m = Test-MtItems -Codes @('I-14636') -Rows @((Itm 'I-14636' -Name 'TREAD RUBBER PRECURED DIAMOND 215')) -Names @{ 'I-14636' = 'TREAD RUBBER PRECURED BLACK PEARL 120' }
Check 'the same code as a DIFFERENT product in Manna Treads is refused, naming both' `
      ($m -eq "I-14636 is 'TREAD RUBBER PRECURED BLACK PEARL 120' in ERPNext but 'TREAD RUBBER PRECURED DIAMOND 215' in Manna Treads SAP - not the same product") $m
$m = Test-MtItems -Codes @('I-14636') -Rows @((Itm 'I-14636' -Name 'TREAD RUBBER  PRECURED black pearl 120 ')) -Names @{ 'I-14636' = ' Tread Rubber Precured Black Pearl 120' }
Check '  spacing and case are not a difference'                ($m -eq '') $m
$m = Test-MtItems -Codes @('I-14636') -Rows @((Itm 'I-14636')) -Names @{}
Check '  an item with no ERPNext name to compare is refused'   ($m -match "is '' in ERPNext") $m

# ---- the customer ----

function Bp { param($Code, $Type = 'cCustomer', $Valid = 'tYES', $Frozen = 'tNO', $State = 'KL', $Name = 'ZZ TEST DEALER A')
    [pscustomobject]@{ CardCode = $Code; CardName = $Name; CardType = $Type; Valid = $Valid; Frozen = $Frozen; BillToState = $State }
}
$m = Test-MtCustomer -Rows @((Bp 'ZZ-TEST-A')) -CardCode 'ZZ-TEST-A' -AllowedStates @('KL')
Check 'a live Kerala customer: nothing to say'                 ($m -eq '') $m
$m = Test-MtCustomer -Rows @() -CardCode 'C-1615' -AllowedStates @('KL')
Check 'a code Manna Treads SAP does not have is refused'       ($m -match 'not in Manna Treads SAP') $m
$m = Test-MtCustomer -Rows @((Bp 'V-1' 'cSupplier')) -CardCode 'V-1' -AllowedStates @('KL')
Check 'a supplier code is refused'                             ($m -match 'not a customer') $m
$m = Test-MtCustomer -Rows @((Bp 'ZZ-TEST-A' 'cCustomer' 'tYES' 'tYES')) -CardCode 'ZZ-TEST-A' -AllowedStates @('KL')
Check 'a frozen customer is refused'                           ($m -match 'inactive or frozen') $m
$m = Test-MtCustomer -Rows @((Bp 'ZZ-TEST-A' 'cCustomer' 'tYES' 'tNO' 'MH')) -CardCode 'ZZ-TEST-A' -AllowedStates @('KL')
Check 'billed outside Kerala: refused - IGST, not guessed'     ($m -match 'MH' -and $m -match 'IGST') $m
$m = Test-MtCustomer -Rows @((Bp 'ZZ-TEST-A' 'cCustomer' 'tYES' 'tNO' '')) -CardCode 'ZZ-TEST-A' -AllowedStates @('KL')
Check 'no bill-to state at all: refused too'                   ($m -match 'no bill-to state') $m
# The code is typed by hand: a mistyped one that is another real customer must not be billed.
$m = Test-MtCustomer -Rows @((Bp 'C-1615' -Name 'SREE MURUGAN TYRES')) -CardCode 'C-1615' -AllowedStates @('KL') -CustomerName 'Kerala Retreads Kottayam'
Check "the code is another customer in Manna Treads SAP: refused, naming both" `
      ($m -eq "Customer code C-1615 is 'SREE MURUGAN TYRES' in Manna Treads SAP but the customer here is 'Kerala Retreads Kottayam' - not the same customer; check Customer.custom_bp_code.") $m
$m = Test-MtCustomer -Rows @((Bp 'ZZ-TEST-A' -Name 'ZZ  Test Dealer A ')) -CardCode 'ZZ-TEST-A' -AllowedStates @('KL') -CustomerName 'zz test dealer a'
Check '  spacing and case are not a difference'                ($m -eq '') $m
$m = Test-MtCustomer -Rows @((Bp 'ZZ-TEST-A' -Name 'ZZ TEST DEALER A')) -CardCode 'ZZ-TEST-A' -AllowedStates @('KL') -CustomerName 'ZZ TEST DEALER A'
Check '  the same name, live, in Kerala: nothing to say'       ($m -eq '') $m

function Hit { param($DocNum, $Cancelled = 'tNO') [pscustomobject]@{ DocEntry = 900 + [int]$DocNum; DocNum = $DocNum; Cancelled = $Cancelled } }
$ad = Select-MtAdoptable -Hits @()
Check 'no order carries the name: create one'                  ($null -eq $ad.Adopt -and $ad.Error -eq '')
$ad = Select-MtAdoptable -Hits @((Hit 41))
Check 'one live order carries it: adopt it, do not create'     ($ad.Adopt -and "$($ad.Adopt.DocNum)" -eq '41' -and $ad.Error -eq '')
$ad = Select-MtAdoptable -Hits @((Hit 41 'tYES'))
Check 'only a cancelled one carries it: create a new one'      ($null -eq $ad.Adopt -and $ad.Error -eq '')
$ad = Select-MtAdoptable -Hits @((Hit 41), (Hit 42))
Check 'two live ones: refused, naming both'                    ($null -eq $ad.Adopt -and $ad.Error -match '41, 42') $ad.Error
$ad = Select-MtAdoptable -Hits @([pscustomobject]@{ DocEntry = $null; DocNum = ''; Cancelled = $null })
Check 'a row with no DocNum is not an order'                   ($null -eq $ad.Adopt -and $ad.Error -eq '')

$threw = $false; try { Assert-MtCompanyDb -CompanyDb 'MANNA_TREADS_LIVE' -HitechCompanyDb 'HITECH_PRETREADS_LIVE' } catch { $threw = $true }
Check 'the Manna Treads database is accepted'                  (-not $threw)
$threw = $false; try { Assert-MtCompanyDb -CompanyDb 'HITECH_PRETREADS_LIVE' -HitechCompanyDb 'HITECH_PRETREADS_LIVE' } catch { $threw = $true }
Check "Hi-Tech's database is refused - it must never see a customer" $threw
$threw = $false; try { Assert-MtCompanyDb -CompanyDb 'MANNA_RUBBER_LIVE' -HitechCompanyDb 'HITECH_PRETREADS_LIVE' } catch { $threw = $true }
Check 'any other database is refused'                          $threw

# ------------------------------------------------------------------------------
Write-Host "`nTHE LIFECYCLE - which orders PASS C takes, and what a refusal costs" -ForegroundColor Yellow

function ListRow { param($Req = 1, $Mt = $null, $Err = $null) [pscustomobject]@{ name = 'SAL-ORD-X'; custom_mt_so_requested = $Req; custom_mt_sales_order = $Mt; custom_mt_sync_error = $Err } }
Check 'asked for, no Manna Treads order, no error: queued - taken'      (Test-MtQueued (ListRow))
Check '  an error read back as null is no error'                        (Test-MtQueued (ListRow 1 $null 'null'))
Check 'asked for with an error recorded: failed - NOT taken, waits for Try again' (-not (Test-MtQueued (ListRow 1 $null 'Item I-11688 is not set up for Manna Treads sales orders yet.')))
Check 'not asked for: not taken'                                        (-not (Test-MtQueued (ListRow 0)))
Check 'already has its Manna Treads order: not taken'                   (-not (Test-MtQueued (ListRow 1 '440')))
$rows = @((ListRow 1 $null ''), (ListRow 1 $null 'Hi-Tech has not closed this order yet'), (ListRow 1 $null $null))
Check '  so of three asked for, one failed, two are taken'              (@($rows | Where-Object { Test-MtQueued $_ }).Count -eq 2)

# Adoption is decided BEFORE any refusal (S6).
$refused = @{ Action = 'refuse'; Message = 'Hi-Tech has not closed this order yet (SAP status bost_Open) - it may still be delivered further.' }
$fine    = @{ Action = 'create'; Message = '' }
$d = Get-MtOrderDecision -Adoptable (Select-MtAdoptable -Hits @((Hit 41))) -PreSap $refused
Check 'one live Manna Treads order carries the name: ADOPTED, even though ERPNext would refuse' ($d.Action -eq 'adopt' -and "$($d.Adopt.DocNum)" -eq '41') $d.Action
$d = Get-MtOrderDecision -Adoptable (Select-MtAdoptable -Hits @((Hit 41))) -PreSap $fine
Check '  and adopted, not posted again, when nothing is wrong'          ($d.Action -eq 'adopt') $d.Action
$d = Get-MtOrderDecision -Adoptable (Select-MtAdoptable -Hits @((Hit 41), (Hit 42))) -PreSap $fine
Check 'two live ones: refused, naming both'                             ($d.Action -eq 'refuse' -and $d.Message -match '41, 42') $d.Message
$d = Get-MtOrderDecision -Adoptable (Select-MtAdoptable -Hits @()) -PreSap $refused
Check 'none: the ERPNext-side refusal stands'                           ($d.Action -eq 'refuse' -and $d.Message -match 'not closed') $d.Message
$d = Get-MtOrderDecision -Adoptable (Select-MtAdoptable -Hits @((Hit 41 'tYES'))) -PreSap $fine
Check 'none live (a cancelled one only), nothing refused: on to the checks and the POST' ($d.Action -eq 'validate') $d.Action

# SAP refusing the POST is the order's problem; anything else is the run's (S5).
$sapErr = '{"error":{"code":-10,"message":{"lang":"en-us","value":"Item code I-14636: tax code missing"}}}'
$f = Get-MtPostFailure -Status 400 -Body $sapErr
Check 'HTTP 400 with an SAP error body: a refusal, in SAP''s words'      ($f.Kind -eq 'refusal' -and $f.Message -eq 'Manna Treads SAP refused the order: Item code I-14636: tax code missing (SAP code -10)') $f.Message
Check '  a 404 or 409 with an SAP body too'                             ((Get-MtPostFailure -Status 404 -Body $sapErr).Kind -eq 'refusal' -and (Get-MtPostFailure -Status 409 -Body $sapErr).Kind -eq 'refusal')
Check 'HTTP 500 with an SAP body: transient'                            ((Get-MtPostFailure -Status 500 -Body $sapErr).Kind -eq 'transient')
Check 'the empty-body 500: transient'                                   ((Get-MtPostFailure -Status 500 -Body '').Kind -eq 'transient')
Check 'HTTP 502 / 503 / 504: transient'                                 (@(502, 503, 504 | Where-Object { (Get-MtPostFailure -Status $_ -Body $sapErr).Kind -ne 'transient' }).Count -eq 0)
Check 'no response at all (network, timeout): transient'                ((Get-MtPostFailure -Status $null -Body '').Kind -eq 'transient')
Check 'an expired session (401, SAP body): transient, not the order''s'  ((Get-MtPostFailure -Status 401 -Body '{"error":{"code":301,"message":{"value":"Invalid session."}}}').Kind -eq 'transient')
Check '403 / 408 / 429: transient'                                      (@(403, 408, 429 | Where-Object { (Get-MtPostFailure -Status $_ -Body $sapErr).Kind -ne 'transient' }).Count -eq 0)
Check 'a 400 with no SAP error in the body (a proxy page): transient'   ((Get-MtPostFailure -Status 400 -Body '<html>Bad Request</html>').Kind -eq 'transient' -and (Get-MtPostFailure -Status 400 -Body '').Kind -eq 'transient')

$long = Limit-MtMessage ("x" * 300)
Check 'the reason written on the order is at most 250 characters'       ($long.Length -eq 250 -and $long.EndsWith('...')) "$($long.Length)"
Check '  on one line'                                                   ((Limit-MtMessage "a`r`n  b") -eq 'a b') (Limit-MtMessage "a`r`n  b")
$both = Test-MtItems -Codes @('I-14636') -Rows @((Itm 'I-14636' -Name ('N' * 120))) -Names @{ 'I-14636' = ('M' * 120) }
Check '  even when both names are long'                                 ((Limit-MtMessage $both).Length -le 250) "$((Limit-MtMessage $both).Length)"

# ------------------------------------------------------------------------------
Write-Host "`nNEVER SHORT, NEVER TWICE - Hi-Tech's own order, read this run" -ForegroundColor Yellow

function HtOrder { param($Lines, $NumAtCard = 'SAL-ORD-2026-00150', $Status = 'bost_Close', $DocDate = '2026-09-10T00:00:00Z', $DocNum = 425, $DocEntry = 9001, $Cancelled = 'tNO')
    [pscustomobject]@{ DocEntry = $DocEntry; DocNum = $DocNum; DocDate = $DocDate; DocumentStatus = $Status; Cancelled = $Cancelled; NumAtCard = $NumAtCard; DocumentLines = @($Lines) }
}
function KgRow { param($Name, $Item, $Dlv = 0, $Inv = 0, $Refs = '')
    [pscustomobject]@{ name = $Name; item_code = $Item; item_name = 'TREAD RUBBER TEST'; custom_total_weight = 60; amount = 12000; custom_rate_per_kg = 200
                       custom_hitech_delivered_kg = $Dlv; custom_hitech_invoiced_kg = $Inv; custom_hitech_delivery_refs = $Refs }
}
$cut = '2026-05-29'
function HtCheck { param($Order, $Rows, $Dlv = @{}, $Inv = @{}, $DCut = $cut, $ICut = $cut)
    Get-MtHitechCheck -HitechOrder $Order -ErpItems $Rows -DeliveredKg $Dlv -InvoicedKg $Inv -DeliveryCutoff $DCut -InvoiceCutoff $ICut
}

$ok = HtCheck (HtOrder @((SoLine 0 'I-14636'), (SoLine 1 'I-14637'))) @((KgRow 'r1' 'I-14636' 60), (KgRow 'r2' 'I-14637' 50)) @{ '9001|0' = 60; '9001|1' = 50 }
Check 'Hi-Tech closed it and every kilo it sent is on the one row it belongs to: nothing to say' ($ok.Message -eq '' -and -not $ok.Stale) $ok.Message

# The verifier's case, reproduced with the real functions: ONE ERPNext row, the
# item on TWO Hi-Tech lines (the factory split it). PASS B writes it no kilos...
$split = HtOrder @((SoLine 0 'I-14636'), (SoLine 1 'I-14636'), (SoLine 2 'I-14637'))
$splitKg = @{ '9001|0' = 60; '9001|1' = 40; '9001|2' = 50 }
$u = Get-HitechKgUpdates -SapLines $split.DocumentLines -ErpItems @((KgRow 'r1' 'I-14636'), (KgRow 'r2' 'I-14637')) -SoEntry '9001' -DeliveredKg $splitKg
Check '  (PASS B skips the split item and writes only the other)' ((@($u.Updates | ForEach-Object { $_.ItemCode }) -join ',') -eq 'I-14637' -and $u.Skips.Count -eq 1) ((@($u.Updates | ForEach-Object { $_.ItemCode }) -join ',') + " / $($u.Skips.Count) skip(s)")
$splitRows = @((KgRow 'r1' 'I-14636' 0), (KgRow 'r2' 'I-14637' 50))
$splitPlan = Get-MtReorderPlan -Order (ConvertTo-MtReorderInput -Doc ([pscustomobject]@{ custom_sap_sales_order = '425'; custom_sap_sales_order_status = 'bost_Close'; custom_mt_so_requested = 1; items = $splitRows }) -BpCode 'ZZ-TEST-A')
$pre = Get-MtPreSapRefusal -Plan $splitPlan -Items $splitRows -CustomerCode 'ZZ-TEST-A' -Unit 'Manna Treads' -Allowlist $s.ItemAllowlist
Check '  (so the plan bills I-14637 alone and, from ERPNext alone, looks fine - 100 kg short)' ($splitPlan.Lines.Count -eq 1 -and $pre.Action -eq 'create') "$($splitPlan.Lines.Count) line(s), $($pre.Action)"
$hc = HtCheck $split $splitRows $splitKg
Check "...and Hi-Tech's own order refuses it, never posted short" `
      ($hc.Message -eq "Hi-Tech has I-14636 on two lines of its order (100 kg sent) and its kilos cannot be matched to this order's line - raise it in SAP by hand." -and -not $hc.Stale) $hc.Message
$pre = Get-MtPreSapRefusal -Plan $splitPlan -Items $splitRows -CustomerCode 'ZZ-TEST-A' -Unit 'Manna Treads' -Allowlist $s.ItemAllowlist -Hitech $hc.Message
Check '  and that verdict carries it'                          ($pre.Action -eq 'refuse' -and $pre.Check -eq 'hitech' -and $pre.Message -match 'I-14636 on two lines') "$($pre.Check): $($pre.Message)"

# The other case: an item on two Hi-Tech lines around another item.
$hc = HtCheck (HtOrder @((SoLine 0 'I-14636'), (SoLine 1 'I-14640'), (SoLine 2 'I-14636'))) @((KgRow 'r1' 'I-14636' 0), (KgRow 'r2' 'I-14640' 36)) @{ '9001|0' = 40; '9001|1' = 36; '9001|2' = 20 }
Check '  the same, when the second Hi-Tech line is further down'  ($hc.Message -match '^Hi-Tech has I-14636 on two lines of its order \(60 kg sent\)') $hc.Message
$hc = HtCheck (HtOrder @((SoLine 0 'I-14636'), (SoLine 1 'I-14636'))) @((KgRow 'r1' 'I-14636' 0))
Check '  an item on two Hi-Tech lines with nothing sent on either: nothing is lost, nothing to say' ($hc.Message -eq '') $hc.Message

# A line Hi-Tech added at the factory, with no ERPNext row: its kilos had vanished silently.
$extra = HtOrder @((SoLine 0 'I-14636'), (SoLine 1 'I-14641'))
$hc = HtCheck $extra @((KgRow 'r1' 'I-14636' 60)) @{ '9001|0' = 60; '9001|1' = 25 }
Check 'Hi-Tech delivered an item this order has no line for: refused, in the words agreed' `
      ($hc.Message -eq 'Hi-Tech delivered I-14641 (25 kg) on a line this order cannot be matched to - raise it in SAP by hand.') $hc.Message
$hc = HtCheck $extra @((KgRow 'r1' 'I-14636' 60)) @{ '9001|0' = 60 } @{ '9001|1' = 12.5 }
Check '  invoiced straight from the order counts as sent too'    ($hc.Message -match 'I-14641 \(12.5 kg\)') $hc.Message
$hc = HtCheck $extra @((KgRow 'r1' 'I-14636' 60)) @{ '9001|0' = 60 }
Check '  a Hi-Tech line with nothing sent is no loss'            ($hc.Message -eq '') $hc.Message
$hc = HtCheck (HtOrder @((SoLine 0 'I-14636'))) @((KgRow 'r1' 'I-14636' 60), (KgRow 'r2' 'I-14699' 10)) @{ '9001|0' = 60 }
Check 'a row carrying Hi-Tech kilos for an item not on its order is refused' ($hc.Message -match "I-14699 carries 10 kg from Hi-Tech here but is not on Hi-Tech's SO 425") $hc.Message

# Stale: what is recorded here is not what Hi-Tech shows now (a failed kilo write, a delivery cancelled after).
$hc = HtCheck (HtOrder @((SoLine 0 'I-14636'))) @((KgRow 'r1' 'I-14636' 60)) @{ '9001|0' = 40 }
Check 'recorded kilos Hi-Tech no longer shows: refused as STALE, naming the figures' ($hc.Stale -and $hc.Message -match 'I-14636 delivered 60 -> 40 kg') $hc.Message
$hc = HtCheck (HtOrder @((SoLine 0 'I-14640'))) @((KgRow 'r1' 'I-14640' 0 30)) @{} @{ '9001|0' = 36 }
Check '  the invoiced figure too'                                 ($hc.Stale -and $hc.Message -match 'invoiced direct 30 -> 36 kg') $hc.Message
$hc = HtCheck (HtOrder @((SoLine 0 'I-14636'))) @((KgRow 'r1' 'I-14636' 60.0004 0 'DN 1 (01-09-2026)')) @{ '9001|0' = 60 }
Check '  within 0.0005 kg, and a refs-only difference, is not stale' ($hc.Message -eq '' -and -not $hc.Stale) $hc.Message
$hc = HtCheck (HtOrder @((SoLine 0 'I-14636'), (SoLine 1 'I-14641'))) @((KgRow 'r1' 'I-14636' 60)) @{ '9001|0' = 40; '9001|1' = 25 }
Check '  a lost line outranks stale kilos - it is never "just stale"' (-not $hc.Stale -and $hc.Message -match 'I-14641') $hc.Message

# Hi-Tech's state and dates, as read this run.
$hc = HtCheck (HtOrder @((SoLine 0 'I-14636')) -Status 'bost_Open') @((KgRow 'r1' 'I-14636' 60)) @{ '9001|0' = 60 }
Check 'Hi-Tech shows it open now: refused'                        ($hc.Message -match 'SO 425 as bost_Open now, not closed') $hc.Message
$hc = HtCheck (HtOrder @((SoLine 0 'I-14636')) -Cancelled 'tYES') @((KgRow 'r1' 'I-14636' 60)) @{ '9001|0' = 60 }
Check '  cancelled there: refused'                                ($hc.Message -match 'bost_Cancelled') $hc.Message
$hc = HtCheck (HtOrder @((SoLine 0 'I-14636')) -DocDate '2026-04-01') @((KgRow 'r1' 'I-14636' 60)) @{ '9001|0' = 60 }
Check 'dated before the delivery scan: refused - its kilos may be incomplete' ($hc.Message -match 'dated 2026-04-01, before the sync' -and $hc.Message -match 'incomplete') $hc.Message
$hc = HtCheck (HtOrder @((SoLine 0 'I-14636')) -DocDate '2026-06-15') @((KgRow 'r1' 'I-14636' 60)) @{ '9001|0' = 60 } @{} '2026-05-29' '2026-07-01'
Check '  the later of the two scans is the one that counts'       ($hc.Message -match 'from 2026-07-01') $hc.Message

# Whose Hi-Tech order it is.
$orig = HtOrder @((SoLine 0 'I-14636')) -NumAtCard 'SAL-ORD-2026-00150'
Check 'Hi-Tech SO names this order in NumAtCard: it is this one'  ((Get-HitechOwnerNote -SapOrder $orig -OrderName 'SAL-ORD-2026-00150') -eq '')
Check '  an empty NumAtCard is no evidence either way'            ((Get-HitechOwnerNote -SapOrder (HtOrder @() -NumAtCard '') -OrderName 'SAL-ORD-2026-00199') -eq '')
$note = Get-HitechOwnerNote -SapOrder $orig -OrderName 'SAL-ORD-2026-00199'
Check '  naming ANOTHER order: not this one (PASS B writes it no kilos)' ($note -eq "Hi-Tech SO 425 carries NumAtCard 'SAL-ORD-2026-00150', not this order") $note
$res = Resolve-HitechOrderFor -Candidates (New-Object System.Collections.ArrayList (, @($orig))) -HitechSo '425' -OrderName 'SAL-ORD-2026-00150'
Check 'one Hi-Tech order with the number, this order''s: resolved' ($res.Problem -eq '' -and $res.Order.DocEntry -eq 9001) $res.Problem
$res = Resolve-HitechOrderFor -Candidates (New-Object System.Collections.ArrayList (, @($orig))) -HitechSo '425' -OrderName 'SAL-ORD-2026-00199'
Check "  a Desk copy pointing at the original's SO: refused, never billed twice" ($null -eq $res.Order -and $res.Problem -match "NumAtCard 'SAL-ORD-2026-00150', not this order - one Hi-Tech order can be billed once") $res.Problem
$res = Resolve-HitechOrderFor -Candidates $null -HitechSo '425' -OrderName 'SAL-ORD-2026-00150'
Check '  not found in Hi-Tech SAP: refused'                       ($res.Problem -match 'SO 425 was not found') $res.Problem
$older = HtOrder @((SoLine 0 'I-14636')) -NumAtCard '' -DocEntry 2041
$res = Resolve-HitechOrderFor -Candidates (New-Object System.Collections.ArrayList (, @($older, $orig))) -HitechSo '425' -OrderName 'SAL-ORD-2026-00150'
Check '  two orders numbered 425 (DocNum is not unique): the one carrying this name' ($res.Problem -eq '' -and $res.Order.DocEntry -eq 9001) "$($res.Problem)"
$res = Resolve-HitechOrderFor -Candidates (New-Object System.Collections.ArrayList (, @($older, $orig))) -HitechSo '425' -OrderName 'SAL-ORD-2026-00199'
Check '  and neither carrying it: refused, not guessed'           ($null -eq $res.Order -and $res.Problem -match '2 orders numbered 425') $res.Problem

# Two ERPNext orders on one Hi-Tech SO.
$m = Test-MtSharedHitechOrder -HitechSo '425' -Others @()
Check 'no other ERPNext order on the Hi-Tech SO: nothing to say'  ($m -eq '') $m
$m = Test-MtSharedHitechOrder -HitechSo '425' -Others @([pscustomobject]@{ name = 'SAL-ORD-2026-00199' })
Check '  another one: refused, naming it'                         ($m -eq 'Hi-Tech SO 425 is also on SAL-ORD-2026-00199 - one Hi-Tech order can be billed once; raise it by hand.') $m
$m = Test-MtSharedHitechOrder -HitechSo '425' -Others @([pscustomobject]@{ name = 'A' }, [pscustomobject]@{ name = 'B' }, [pscustomobject]@{ name = 'A' })
Check '  several, each named once'                                ($m -match 'also on A, B -') $m

# Who asked for it.
$m = Test-MtApprover -RequestedBy 'Jineesh@MannaRubber.com' -Approvers $s.Approvers
Check 'asked for by the accountant (case aside): accepted'        ($m -eq '') $m
$m = Test-MtApprover -RequestedBy 'rep1@mannarubber.com' -Approvers $s.Approvers
Check '  the flag set by anyone else (REST, a console): refused'  ($m -match '^Not approved by the accountant: it was asked for by rep1@mannarubber.com') $m
$m = Test-MtApprover -RequestedBy '' -Approvers $s.Approvers
Check '  nobody recorded as asking: refused'                      ($m -match 'custom_mt_so_requested_by is empty') $m
$m = Test-MtApprover -RequestedBy 'null' -Approvers $s.Approvers
Check "  _by read back as 'null' is nobody"                       ($m -match 'is empty') $m

# Delivered, and part invoiced straight from the order: delivery_wins would drop the invoiced kilos.
$case4 = @($fixture.cases | Where-Object { $_.why -match '^delivered AND invoiced' })[0]
$p4 = Get-MtReorderPlan -Order $case4.order
$rows4 = @($case4.order.lines | ForEach-Object { [pscustomobject]@{ item_code = $_.item; custom_hitech_delivered_kg = $_.delivered_kg; custom_hitech_invoiced_kg = $_.invoiced_kg } })
$m = Test-MtMixedBasis -Plan $p4 -Items $rows4
Check "the fixture's delivered-AND-invoiced order: the rule bills the deliveries only, so the sync refuses it" `
      ($p4.Basis -eq 'delivered' -and $m -match 'I-14640 \(36 kg\)' -and $m -match 'Raise it by hand') $m
$rowsB = @([pscustomobject]@{ item_code = 'I-14636'; custom_hitech_delivered_kg = 40; custom_hitech_invoiced_kg = 20 })
$pB = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 40 20)) -Requested $true)
$m = Test-MtMixedBasis -Plan $pB -Items $rowsB
Check '  40 kg on a delivery, the other 20 invoiced from the order: refused, not billed at 40' ($pB.Lines[0].Kg -eq 40 -and $m -match 'I-14636 \(20 kg\)') $m
$m = Test-MtMixedBasis -Plan (Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14640' 36 6120 170 0 34.2)))) -Items @([pscustomobject]@{ item_code = 'I-14640'; custom_hitech_delivered_kg = 0; custom_hitech_invoiced_kg = 34.2 })
Check '  an order invoiced direct with no delivery at all is not mixed' ($m -eq '') $m
$m = Test-MtMixedBasis -Plan $full -Items @([pscustomobject]@{ item_code = 'I-14636'; custom_hitech_delivered_kg = 60; custom_hitech_invoiced_kg = 0 })
Check '  nor one only delivered'                                  ($m -eq '') $m

# The order of the verdict.
$fineItems = @((ErpItem 'I-14636'))
$qPlan = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 60)) -Requested $true)
function Pre { param($Plan = $qPlan, $Items = $fineItems, $Approval = '', $Shared = '', $Hitech = '', $Stale = $false, $Code = 'ZZ-TEST-A')
    Get-MtPreSapRefusal -Plan $Plan -Items $Items -CustomerCode $Code -Unit 'Manna Treads' -Allowlist $s.ItemAllowlist `
        -Approval $Approval -Shared $Shared -Hitech $Hitech -HitechStale $Stale
}
Check 'nothing wrong: create'                                     ((Pre).Action -eq 'create')
Check '  not approved outranks everything else'                   ((Pre -Approval 'NA' -Shared 'S' -Hitech 'H' -Code '').Check -eq 'approval')
Check '  then another order on the Hi-Tech SO'                    ((Pre -Shared 'S' -Hitech 'H').Check -eq 'shared')
Check '  then an item on two ERPNext lines'                       ((Pre -Items @((ErpItem 'I-14636'), (ErpItem 'I-14636')) -Hitech 'H').Check -eq 'duplicate')
$nd = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 0)) -Requested $true)
$v = Pre -Plan $nd -Hitech 'Hi-Tech has I-14636 on two lines'
Check "  then Hi-Tech's order - before the plan, which would call the lost kilos 'nothing delivered'" ($nd.State -eq 'nothing_delivered' -and $v.Check -eq 'hitech') "$($nd.State) / $($v.Check)"
Check '  then the plan'                                           ((Pre -Code '').Check -eq 'plan')
Check '  then part invoiced direct, then the allowlist'           ((Pre -Plan $pB -Items $rowsB).Check -eq 'mixed')
Check '  a stale-only Hi-Tech check is marked so'                 ((Pre -Hitech 'H' -Stale $true).Check -eq 'hitech-stale')
$skipPlan = Get-MtReorderPlan -Order (OrderOf @((LineOf 'I-14636' 60 11940 199 60)) -Requested $true -Err 'earlier')
Check '  and a plan that says skip is never overridden'           ((Pre -Plan $skipPlan -Approval 'NA').Action -eq 'skip')

# Stale kilos: the run's problem when PASS B was due to refresh them, the order's when nothing will.
$st = Pre -Hitech 'H' -Stale $true
$v = Get-MtStaleVerdict -PreSap $st -InPassB $true
Check 'stale kilos on an order PASS B was due to refresh this run: transient - nothing written, run fails' ($v.Action -eq 'transient') $v.Action
$v = Get-MtStaleVerdict -PreSap $st -InPassB $false
Check '  on a retired, closed order nothing will refresh: a refusal, for a human' ($v.Action -eq 'refuse') $v.Action
$v = Get-MtStaleVerdict -PreSap (Pre -Hitech 'H') -InPassB $true
Check '  any other Hi-Tech refusal stays a refusal'               ($v.Action -eq 'refuse') $v.Action
$d = Get-MtOrderDecision -Adoptable (Select-MtAdoptable -Hits @((Hit 41))) -PreSap (Get-MtStaleVerdict -PreSap $st -InPassB $true)
Check '  and adoption still comes first'                          ($d.Action -eq 'adopt') $d.Action
$d = Get-MtOrderDecision -Adoptable (Select-MtAdoptable -Hits @()) -PreSap (Get-MtStaleVerdict -PreSap $st -InPassB $true)
Check '  otherwise the decision is transient'                     ($d.Action -eq 'transient') $d.Action

# The Desk copy end to end: original SAL-ORD-2026-00150 was billed; its copy carries DocNum 425.
$copyRows = @((KgRow 'c1' 'I-14636' 0))   # the kilo fields are no_copy
Check 'a Desk copy: PASS B gives it none of the original''s kilos'  ((Get-HitechOwnerNote -SapOrder $orig -OrderName 'SAL-ORD-2026-00201') -ne '')
$res = Resolve-HitechOrderFor -Candidates (New-Object System.Collections.ArrayList (, @($orig))) -HitechSo '425' -OrderName 'SAL-ORD-2026-00201'
$shared = Test-MtSharedHitechOrder -HitechSo '425' -Others @([pscustomobject]@{ name = 'SAL-ORD-2026-00150' })
$v = Get-MtPreSapRefusal -Plan (Get-MtReorderPlan -Order (ConvertTo-MtReorderInput -Doc ([pscustomobject]@{ custom_sap_sales_order = '425'; custom_sap_sales_order_status = 'bost_Close'; custom_mt_so_requested = 1; items = $copyRows }) -BpCode 'ZZ-TEST-A')) `
        -Items $copyRows -CustomerCode 'ZZ-TEST-A' -Unit 'Manna Treads' -Allowlist $s.ItemAllowlist -Shared $shared -Hitech $res.Problem
Check '  and PASS C refuses it, naming the original'              ($v.Action -eq 'refuse' -and $v.Message -match 'also on SAL-ORD-2026-00150') $v.Message

# PASS B: kilos first, and what a failed kilo write holds back.
$f = @{ custom_sap_synced_at = 'now'; custom_sap_sync_error = ''; custom_sap_sales_order_status = 'bost_Close' }
$held = Limit-PassBHeaderOnKgFailure -Fields $f -KgFailed 0
Check 'every kilo written: the header goes as it is'              ($held.Count -eq 0 -and $f.ContainsKey('custom_sap_sales_order_status'))
$held = Limit-PassBHeaderOnKgFailure -Fields $f -KgFailed 1
Check '  one failed: the SAP status is held back - no "ready" on stale kilos' (($held -join ',') -eq 'custom_sap_sales_order_status' -and -not $f.ContainsKey('custom_sap_sales_order_status') -and $f.ContainsKey('custom_sap_synced_at') -and $f.ContainsKey('custom_sap_sync_error')) ($held -join ',')
$f = @{ custom_sap_synced_at = 'now'; custom_sap_sales_order_status = 'bost_Close'; custom_sap_invoice = '77'; custom_sap_invoice_date = '2026-09-20' }
$held = Limit-PassBHeaderOnKgFailure -Fields $f -KgFailed 2
Check '  on the pass that would retire it: the status AND the invoice, so it is not retired' ((($held | Sort-Object) -join ',') -eq 'custom_sap_invoice,custom_sap_invoice_date,custom_sap_sales_order_status' -and $f.Count -eq 1) ($held -join ',')

# ------------------------------------------------------------------------------
Write-Host "`nThe PASS C lock (S10)" -ForegroundColor Cyan

$lockName = 'Local\MannaSapOrderSyncPassC-Test-' + [guid]::NewGuid().ToString('N')
$held = Enter-MtPassLock -Name $lockName
Check 'a free lock is taken'                                            ($null -ne $held)
Exit-MtPassLock $held
# Another process holds it: this one must be told no, not wait.
$ready = Join-Path ([IO.Path]::GetTempPath()) ("mtlock-" + [guid]::NewGuid().ToString('N') + '.txt')
$holder = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-Command',
    "`$m = New-Object System.Threading.Mutex(`$true, '$lockName'); Set-Content -LiteralPath '$ready' -Value ok; Start-Sleep -Seconds 20; `$m.ReleaseMutex()")
$waited = 0
while (-not (Test-Path -LiteralPath $ready) -and $waited -lt 150) { Start-Sleep -Milliseconds 100; $waited++ }
$t0 = Get-Date
$second = Enter-MtPassLock -Name $lockName
$took = ((Get-Date) - $t0).TotalMilliseconds
Check 'held by another run: refused at once, so PASS C is skipped'      ((Test-Path -LiteralPath $ready) -and $null -eq $second -and $took -lt 2000) ("got {0}, {1:n0} ms" -f $(if ($second) { 'the lock' } else { 'nothing' }), $took)
Exit-MtPassLock $second
try { Stop-Process -Id $holder.Id -Force -ErrorAction Stop } catch { }
Remove-Item -LiteralPath $ready -Force -ErrorAction SilentlyContinue
$waited = 0
while (-not $holder.HasExited -and $waited -lt 50) { Start-Sleep -Milliseconds 100; $waited++ }
$after = Enter-MtPassLock -Name $lockName
Check 'a holder that died without releasing it does not block the next run' ($null -ne $after)
Exit-MtPassLock $after

Write-Host ''
Write-Host ("{0} passed, {1} failed." -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
