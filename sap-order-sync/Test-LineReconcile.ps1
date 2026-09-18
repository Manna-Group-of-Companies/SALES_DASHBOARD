<#
.SYNOPSIS
  Proves Get-ErpLineCorrections plans the right corrections, and refuses the
  right ones.

.DESCRIPTION
  Dot-sources the real Sync-SapOrders.ps1 and calls the SAME function PASS B
  calls - not a copy. Nothing is written: no SAP call, no ERPNext call. The
  cases are built in memory, so this runs with SAP down.

  The four refusals are the point of the suite. A wrong correction here
  silently rewrites a customer's order, and every one of these was reachable:

    * SAP read returned nothing      -> looks identical to "somebody emptied it"
    * an item on two lines            -> matching is by item code, so ambiguous
    * every line gone                 -> would empty the order
    * a family whose note cannot be
      rebuilt                         -> corrected figures, stale note

.EXAMPLE
  .\Test-LineReconcile.ps1
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

$script:pass = 0
$script:fail = 0

function Check {
    param([string] $What, [bool] $Ok, [string] $Got = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  " + $What + $(if ($Got) { "  ->  $Got" } else { '' })) -ForegroundColor Red }
}

# --- builders -------------------------------------------------------------
function SapLine { param($Code, $Qty, $Status = 'bost_Open') [pscustomobject]@{ ItemCode = $Code; Quantity = $Qty; LineStatus = $Status } }
function ErpLine {
    param($Code, $RowName, $Kg, $Qty, $Rolls, $Belts = 0, $Rate = 0, $Cat = 'PCTR')
    [pscustomobject]@{
        item_code               = $Code
        name                    = $RowName
        custom_total_weight     = $Kg
        qty                     = $Qty
        custom_rolls            = $Rolls
        custom_loose_belts      = $Belts
        rate                    = $Rate
        custom_product_category = $Cat
    }
}
function ActionFor { param($Plan, $Code) $Plan.Actions | Where-Object { $_.ItemCode -eq $Code } | Select-Object -First 1 }

Write-Host ''
Write-Host 'A line SAP still agrees with' -ForegroundColor Cyan
$p = Get-ErpLineCorrections -SapLines @((SapLine 'I-1' 168)) -ErpItems @((ErpLine 'I-1' 'r1' 168 7 7 0 840))
Check 'is not touched at all' ($p.Actions.Count -eq 0) ("planned $($p.Actions.Count)")
Check 'and does not abort'   ($null -eq $p.Abort)

Write-Host ''
Write-Host 'A line the factory reduced' -ForegroundColor Cyan
# 7 rolls / 168 kg at 840 a roll, cut to 120 kg. 120/168 = 5/7, so 5 rolls.
$p = Get-ErpLineCorrections -SapLines @((SapLine 'I-1' 120)) -ErpItems @((ErpLine 'I-1' 'r1' 168 7 7 0 840))
$a = ActionFor $p 'I-1'
Check 'is planned as a correction'      ($a.Action -eq 'reduce') $a.Action
Check 'takes SAP kilos exactly'         ($a.Fields['custom_total_weight'] -eq 120) ("$($a.Fields['custom_total_weight'])")
Check 'scales the quantity to 5'        ($a.Fields['qty'] -eq 5) ("$($a.Fields['qty'])")
Check 'scales the rolls to 5'           ($a.Fields['custom_rolls'] -eq 5) ("$($a.Fields['custom_rolls'])")
Check 'keeps qty x rate as the amount'  ($a.Fields['amount'] -eq 4200) ("$($a.Fields['amount'])")
$dot = [string][char]0x00B7
Check 'rebuilds the packing note'       ($a.Fields['custom_packing_note'] -eq "5 rolls $dot 120.00 kg (avg)") $a.Fields['custom_packing_note']

Write-Host ''
Write-Host 'Singular and plural, because the note is read by a person' -ForegroundColor Cyan
$p = Get-ErpLineCorrections -SapLines @((SapLine 'I-1' 24)) -ErpItems @((ErpLine 'I-1' 'r1' 168 7 7 0 840))
$a = ActionFor $p 'I-1'
Check 'one roll, not "1 rolls"' ($a.Fields['custom_packing_note'] -eq "1 roll $dot 24.00 kg (avg)") $a.Fields['custom_packing_note']

$p = Get-ErpLineCorrections -SapLines @((SapLine 'I-1' 81.2)) -ErpItems @((ErpLine 'I-1' 'r1' 162.4 5.5 5 4 1000))
$a = ActionFor $p 'I-1'
Check 'belts are halved and named' ($a.Fields['custom_packing_note'] -match 'belt') $a.Fields['custom_packing_note']

Write-Host ''
Write-Host 'A line the factory dropped' -ForegroundColor Cyan
$p = Get-ErpLineCorrections -SapLines @((SapLine 'I-1' 168)) -ErpItems @((ErpLine 'I-1' 'r1' 168 7 7 0 840), (ErpLine 'I-2' 'r2' 88 2 2 0 1100))
$a = ActionFor $p 'I-2'
Check 'is planned for removal'      ($a.Action -eq 'remove') $a.Action
Check 'and names the row to delete' ($a.RowName -eq 'r2') $a.RowName
Check 'while its neighbour is left' ($null -eq (ActionFor $p 'I-1'))

Write-Host ''
Write-Host 'CLOSED IN SAP - delivered, or dropped?' -ForegroundColor Cyan
# The pair that would be indistinguishable without the delivery note. Both
# lines read LineStatus bost_Close; only one of them was actually sent.
$closed = @((SapLine 'I-1' 168 'bost_Close'), (SapLine 'I-2' 88 'bost_Close'))
$erp    = @((ErpLine 'I-1' 'r1' 168 7 7 0 840), (ErpLine 'I-2' 'r2' 88 2 2 0 1100))
$p = Get-ErpLineCorrections -SapLines $closed -ErpItems $erp -DeliveredItems @{ 'I-1' = $true }
Check 'the delivered line is left exactly alone' ($null -eq (ActionFor $p 'I-1'))
$a = ActionFor $p 'I-2'
Check 'the dropped line is removed'              ($a.Action -eq 'remove') $a.Action
Check '  and says why'                           ($a.Note -match 'no delivery') $a.Note

# The failure this guards: with no delivery information at all, a fully
# delivered order would have every line deleted. The all-gone guard catches it.
$p = Get-ErpLineCorrections -SapLines $closed -ErpItems $erp -DeliveredItems @{}
Check 'no delivery info at all aborts rather than deleting a shipped order' ($null -ne $p.Abort) 'no abort'
Check '  and plans nothing'                                                  ($p.Actions.Count -eq 0)

# A line closed and delivered, beside one still open and reduced.
$p = Get-ErpLineCorrections `
        -SapLines @((SapLine 'I-1' 168 'bost_Close'), (SapLine 'I-2' 44 'bost_Open')) `
        -ErpItems @((ErpLine 'I-1' 'r1' 168 7 7 0 840), (ErpLine 'I-2' 'r2' 88 2 2 0 1100)) `
        -DeliveredItems @{ 'I-1' = $true }
Check 'a shipped line and a reduced line can coexist' ($null -eq (ActionFor $p 'I-1'))
$a = ActionFor $p 'I-2'
Check '  the open one is still corrected'             ($a.Action -eq 'reduce') $a.Action
Check '  to SAP kilos'                                ($a.Fields['custom_total_weight'] -eq 44) ("$($a.Fields['custom_total_weight'])")

Write-Host ''
Write-Host 'REFUSALS - the cases that must plan nothing' -ForegroundColor Yellow

$p = Get-ErpLineCorrections -SapLines @() -ErpItems @((ErpLine 'I-1' 'r1' 168 7 7 0 840))
Check 'an empty SAP read aborts rather than emptying the order' ($null -ne $p.Abort) 'no abort'
Check '  and plans nothing'                                      ($p.Actions.Count -eq 0)

$p = Get-ErpLineCorrections -SapLines @((SapLine 'I-1' 60), (SapLine 'I-1' 60)) -ErpItems @((ErpLine 'I-1' 'r1' 168 7 7 0 840))
$a = ActionFor $p 'I-1'
Check 'the same item twice in SAP is skipped, not guessed at' ($a.Action -eq 'skip') $a.Action

$p = Get-ErpLineCorrections -SapLines @((SapLine 'I-1' 100)) -ErpItems @((ErpLine 'I-1' 'r1' 168 7 7 0 840), (ErpLine 'I-1' 'r2' 24 1 1 0 840))
Check 'the same item twice in ERPNext is skipped too' (@($p.Actions | Where-Object { $_.Action -eq 'skip' }).Count -eq 2)

$p = Get-ErpLineCorrections -SapLines @((SapLine 'I-9' 5)) -ErpItems @((ErpLine 'I-1' 'r1' 168 7 7 0 840), (ErpLine 'I-2' 'r2' 88 2 2 0 1100))
Check 'every line missing from SAP aborts instead of emptying it' ($null -ne $p.Abort) 'no abort'
Check '  and plans nothing'                                        ($p.Actions.Count -eq 0)

$p = Get-ErpLineCorrections -SapLines @((SapLine 'I-1' 40)) -ErpItems @((ErpLine 'I-1' 'r1' 80 80 0 0 30 'BG'))
$a = ActionFor $p 'I-1'
Check 'a family whose note cannot be rebuilt is left for a human' ($a.Action -eq 'skip') $a.Action
Check '  and says so'                                             ($a.Note -match 'packing note') $a.Note

$p = Get-ErpLineCorrections -SapLines @((SapLine 'I-1' 40)) -ErpItems @((ErpLine 'I-1' 'r1' 0 0 0 0 0))
$a = ActionFor $p 'I-1'
Check 'a line with no weight has nothing to scale from' ($a.Action -eq 'skip') $a.Action

Write-Host ''
Write-Host ("{0} passed, {1} failed." -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
