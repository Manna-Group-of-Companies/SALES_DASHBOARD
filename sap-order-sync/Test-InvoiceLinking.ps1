<#
.SYNOPSIS
  Proves an A/R invoice line is tied back to the right sales order, the right
  invoice is named once an order is complete, and an invoiced line is never
  mistaken for a dropped one.

.DESCRIPTION
  Dot-sources the real Sync-SapOrders.ps1 and calls the SAME functions PASS B
  calls. Nothing is read or written; every document is built in memory, so
  this runs with SAP and ERPNext both down.

  From 24 September 2026 an invoice is the only thing that makes an order
  Dispatched (shared/fixtures/sap_order_state.json). An invoice line is based
  either on the sales order itself or on a delivery, and a pooled invoice can
  carry lines from several orders - so the join is made per line.

  The last section guards the failure that would cost real data: a SAP line
  closes both when it ships and when the factory drops it. A line invoiced
  straight from the order has no delivery, and if invoices were not counted as
  "finished" the reconcile would read it as dropped and delete it.

.EXAMPLE
  .\Test-InvoiceLinking.ps1
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

function InvLine { param($BaseType, $BaseEntry, $BaseLine = 0, $Item = 'I-1')
    [pscustomobject]@{ BaseType = $BaseType; BaseEntry = $BaseEntry; BaseLine = $BaseLine; ItemCode = $Item }
}
function Inv { param($DocNum, $DocDate, $DocEntry)
    [pscustomobject]@{ DocNum = $DocNum; DocDate = $DocDate; DocEntry = $DocEntry }
}

# delivery 110 line 0 came from sales order 2897; delivery 110 line 1 from 2896
$dnLineToSo = @{ '110|0' = '2897'; '110|1' = '2896' }

Write-Host "`nResolve-InvoiceLineSoEntry - which sales order an invoice line is for" -ForegroundColor Cyan

$r = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine 17 2897) -DnLineToSo $dnLineToSo
Check 'based on the sales order: its own BaseEntry' ($r -eq '2897') $r

$r = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine 15 110 0) -DnLineToSo $dnLineToSo
Check 'based on a delivery: followed back through the delivery line' ($r -eq '2897') $r

$r = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine 15 110 1) -DnLineToSo $dnLineToSo
Check 'the delivery LINE decides, not the delivery - one DN can carry two orders' ($r -eq '2896') $r

$r = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine 15 999 0) -DnLineToSo $dnLineToSo
Check 'a delivery older than the scan window resolves to nothing, not a guess' ($r -eq '') $r

$r = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine -1 '') -DnLineToSo $dnLineToSo
Check 'a standalone invoice with no base belongs to no order' ($r -eq '') $r

$r = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine 17 0) -DnLineToSo $dnLineToSo
Check 'a DocEntry of 0 is not a document' ($r -eq '') $r

$r = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine 13 500) -DnLineToSo $dnLineToSo
Check 'based on some other document type: not an order line' ($r -eq '') $r

$r = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine 15 110 0) -DnLineToSo $null
Check 'no delivery map at all does not throw' ($r -eq '') $r

$r = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine '17' '2897') -DnLineToSo $dnLineToSo
Check 'base type as text, as JSON can deliver it' ($r -eq '2897') $r

# A pooled invoice carrying two orders - resolved line by line.
$a = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine 17 2897 0 'I-14636') -DnLineToSo $dnLineToSo
$b = Resolve-InvoiceLineSoEntry -InvoiceLine (InvLine 17 2896 0 'I-14638') -DnLineToSo $dnLineToSo
Check 'a pooled invoice attaches each line to its own order' ($a -eq '2897' -and $b -eq '2896') "$a / $b"

Write-Host "`nSelect-CompletingInvoice - which invoice the finished order names" -ForegroundColor Cyan

$i = Select-CompletingInvoice @((Inv 'INV-1' '2026-09-20T00:00:00Z' 10))
Check 'one invoice: that one' ("$($i.DocNum)" -eq 'INV-1') "$($i.DocNum)"

$i = Select-CompletingInvoice @((Inv 'INV-1' '2026-09-20T00:00:00Z' 10), (Inv 'INV-2' '2026-09-24T00:00:00Z' 11))
Check 'invoiced in parts: the later one completed it' ("$($i.DocNum)" -eq 'INV-2') "$($i.DocNum)"

$i = Select-CompletingInvoice @((Inv 'INV-2' '2026-09-24T00:00:00Z' 11), (Inv 'INV-1' '2026-09-20T00:00:00Z' 10))
Check 'order does not matter' ("$($i.DocNum)" -eq 'INV-2') "$($i.DocNum)"

$i = Select-CompletingInvoice @((Inv 'INV-5' '2026-09-24T00:00:00Z' 15), (Inv 'INV-6' '2026-09-24T00:00:00Z' 16))
Check 'same day: the later document' ("$($i.DocNum)" -eq 'INV-6') "$($i.DocNum)"

# A line recorded as invoiced on an earlier run, whose invoice this run no
# longer sees, is carried as a stand-in with DocEntry 0.
$i = Select-CompletingInvoice @((Inv 'INV-1' '2026-09-01' 0), (Inv 'INV-2' '2026-09-24T00:00:00Z' 11))
Check 'a recorded-only stand-in does not outrank a live later invoice' ("$($i.DocNum)" -eq 'INV-2') "$($i.DocNum)"

$i = Select-CompletingInvoice @($null, (Inv 'INV-3' '2026-09-22T00:00:00Z' 13), $null)
Check 'gaps are ignored' ("$($i.DocNum)" -eq 'INV-3') "$($i.DocNum)"

$i = Select-CompletingInvoice @()
Check 'nothing invoiced: nothing named' ($null -eq $i) "$i"

Write-Host "`nAn invoiced line is finished, not dropped" -ForegroundColor Cyan

function SapLine { param($Code, $Qty, $Status = 'bost_Open') [pscustomobject]@{ ItemCode = $Code; Quantity = $Qty; LineStatus = $Status } }
function ErpLine {
    param($Code, $RowName, $Kg, $Qty, $Rolls)
    [pscustomobject]@{
        item_code = $Code; name = $RowName; custom_total_weight = $Kg; qty = $Qty
        custom_rolls = $Rolls; custom_loose_belts = 0; rate = 0; custom_product_category = 'PCTR'
    }
}
$sap = @((SapLine 'I-1' 168), (SapLine 'I-2' 60 'bost_Close'))
$erp = @((ErpLine 'I-1' 'r1' 168 7 7), (ErpLine 'I-2' 'r2' 60 2 2))

# PASS B builds this set from deliveries AND invoices. I-2 was invoiced
# straight from the order, so it is in the set only because invoices count.
$p = Get-ErpLineCorrections -SapLines $sap -ErpItems $erp -DeliveredItems @{ 'I-2' = $true }
$rm = @($p.Actions | Where-Object { $_.ItemCode -eq 'I-2' -and $_.Action -eq 'remove' })
Check 'closed in SAP and invoiced: the row is kept' ($rm.Count -eq 0) ("remove actions: $($rm.Count)")

$p = Get-ErpLineCorrections -SapLines $sap -ErpItems $erp -DeliveredItems @{}
$rm = @($p.Actions | Where-Object { $_.ItemCode -eq 'I-2' -and $_.Action -eq 'remove' })
Check 'closed with neither delivery nor invoice: read as dropped (the set is what saves it)' ($rm.Count -eq 1) ("remove actions: $($rm.Count)")

Write-Host ''
Write-Host ("{0} passed, {1} failed." -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
