<#
.SYNOPSIS
  Proves Resolve-SoEntryByDocNumAndItem attaches a hand-linked production order
  to the right sales order, and refuses when it cannot tell.

.DESCRIPTION
  Dot-sources the real Sync-SapOrders.ps1 and calls the SAME function the
  prefetch calls. Nothing is read or written; the candidates are built in
  memory, so this runs with SAP down.

  The bug this suite exists for, found 18 September 2026: a production order
  raised by hand with the sales order NUMBER typed into the Sales Order field
  carries ProductionOrderOriginNumber and leaves ProductionOrderOriginEntry
  null. The sync joined on the entry only, so SAP order 406 showed Not Started
  in the PWA while a RELEASED production order sat against its line.

  DocNum is not unique in this database - 406 is four different sales orders -
  so the number cannot be trusted alone. The item is the tie-breaker, and
  anything ambiguous must be refused rather than guessed.

.EXAMPLE
  .\Test-PoLinking.ps1
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

function SapOrder {
    param([int] $Entry, [string[]] $Items)
    [pscustomobject]@{
        DocEntry      = $Entry
        DocNum        = 406
        DocumentLines = @($Items | ForEach-Object { [pscustomobject]@{ ItemCode = $_ } })
    }
}

Write-Host "`nResolve-SoEntryByDocNumAndItem" -ForegroundColor Cyan

# The live shape: DocNum 406 is four sales orders, and only 2891 carries the
# test item. This is the exact case that was reading Not Started.
$live = @(
    (SapOrder 406  @('I-9001', 'I-9002')),
    (SapOrder 1013 @('I-9003')),
    (SapOrder 2041 @('I-9004')),
    (SapOrder 2891 @('I-14636', 'I-14637'))
)

$r = Resolve-SoEntryByDocNumAndItem -Candidates $live -ItemCode 'I-14637'
Check 'the released order for I-14637 lands on DocEntry 2891' ($r.Entry -eq '2891') "$($r.Entry)"
Check '  with nothing to refuse'                              ($r.Reason -eq '')      $r.Reason

$r = Resolve-SoEntryByDocNumAndItem -Candidates $live -ItemCode 'I-14636'
Check 'so does the other line of the same order' ($r.Entry -eq '2891') "$($r.Entry)"

$r = Resolve-SoEntryByDocNumAndItem -Candidates $live -ItemCode 'I-9003'
Check 'an item on an OLD order with the same DocNum goes there, not to 2891' ($r.Entry -eq '1013') "$($r.Entry)"

# --- the refusals ---------------------------------------------------------
# Attaching a production order to the wrong sales order would report someone
# else's order as being made. Refusing leaves the line Not Started, which is
# merely wrong-and-visible rather than wrong-and-convincing.
$r = Resolve-SoEntryByDocNumAndItem -Candidates $live -ItemCode 'I-0000'
Check 'an item on none of them is refused'   ($r.Entry -eq '') $r.Entry
Check '  and says why'                       ($r.Reason -match 'no sales order') $r.Reason

$both = @((SapOrder 2891 @('I-14637')), (SapOrder 2041 @('I-14637')))
$r = Resolve-SoEntryByDocNumAndItem -Candidates $both -ItemCode 'I-14637'
Check 'an item on TWO orders sharing a DocNum is refused, never guessed' ($r.Entry -eq '') $r.Entry
Check '  and counts them'                                               ($r.Reason -match '2 sales orders') $r.Reason

$r = Resolve-SoEntryByDocNumAndItem -Candidates $live -ItemCode ''
Check 'a production order naming no item is refused' ($r.Entry -eq '') $r.Entry
Check '  and says so'                                ($r.Reason -match 'no item') $r.Reason

$r = Resolve-SoEntryByDocNumAndItem -Candidates @() -ItemCode 'I-14637'
Check 'no candidates at all is refused, not crashed' ($r.Entry -eq '') $r.Entry

# --- shape robustness -----------------------------------------------------
# A DocEntry of 0 is not a document; Add-PoToMap would drop it anyway, but the
# resolver must not offer it as a match in the first place.
$zero = @([pscustomobject]@{ DocEntry = 0; DocNum = 406; DocumentLines = @([pscustomobject]@{ ItemCode = 'I-14637' }) })
$r = Resolve-SoEntryByDocNumAndItem -Candidates $zero -ItemCode 'I-14637'
Check 'DocEntry 0 is not a match' ($r.Entry -eq '') $r.Entry

$noLines = @([pscustomobject]@{ DocEntry = 2891; DocNum = 406 })
$r = Resolve-SoEntryByDocNumAndItem -Candidates $noLines -ItemCode 'I-14637'
Check 'an order whose lines were not fetched matches nothing' ($r.Entry -eq '') $r.Entry

# Same item twice on one order is still ONE order - it must not read as ambiguous.
$dupLine = @((SapOrder 2891 @('I-14637', 'I-14637')))
$r = Resolve-SoEntryByDocNumAndItem -Candidates $dupLine -ItemCode 'I-14637'
Check 'the same item on two lines of ONE order is not ambiguous' ($r.Entry -eq '2891') "$($r.Entry)"

Write-Host "`nSelect-LeastAdvancedPo - which of several POs covers the line" -ForegroundColor Cyan

# Labels as config.json carries them, so the assertions read in app terms.
$labels = [pscustomobject]@{
    boposPlanned   = 'Planned'
    boposReleased  = 'In Production'
    boposClosed    = 'Closed'
    boposCancelled = 'Cancelled'
}
function Po { param([string] $Num, [string] $Status) [pscustomobject]@{ DocumentNumber = $Num; ProductionOrderStatus = $Status } }
function StageOf { param($P) if ($null -eq $P) { return '<none>' } Resolve-CurrentStage -Po $P -Labels $labels -StageSource 'routing_stages' }

# The case reported on 18 September 2026: one cancelled, one released.
$p = Select-LeastAdvancedPo @((Po '4422' 'boposCancelled'), (Po '4429' 'boposReleased'))
Check 'cancelled + released -> the RELEASED one is reported' ("$($p.DocumentNumber)" -eq '4429') "$($p.DocumentNumber)"
Check '  and the line reads In Production'                   ((StageOf $p) -eq 'In Production') (StageOf $p)

# Order of arrival must not change the answer.
$p = Select-LeastAdvancedPo @((Po '4429' 'boposReleased'), (Po '4422' 'boposCancelled'))
Check 'the same however they arrive' ("$($p.DocumentNumber)" -eq '4429') "$($p.DocumentNumber)"

$p = Select-LeastAdvancedPo @((Po '4422' 'boposCancelled'))
Check 'cancelled alone -> nothing covers the line' ($null -eq $p) "$($p.DocumentNumber)"

$p = Select-LeastAdvancedPo @((Po '1' 'boposCancelled'), (Po '2' 'boposCancelled'))
Check 'every one cancelled -> nothing covers the line' ($null -eq $p) "$($p.DocumentNumber)"

$p = Select-LeastAdvancedPo @((Po '1' 'boposReleased'), (Po '2' 'boposClosed'))
Check 'released + closed -> the released one still holds the line open' ("$($p.DocumentNumber)" -eq '1') "$($p.DocumentNumber)"

# DELIBERATE, and the one that surprises people: two LIVE production orders
# report the least advanced, so a Planned one alongside a Released one drags the
# line back to Not Started. That is right when the two cover different parts of
# the quantity - the line is not in production until the planned part starts -
# but it looks exactly like the hand-linking bug, so it is pinned here.
$p = Select-LeastAdvancedPo @((Po '1' 'boposPlanned'), (Po '2' 'boposReleased'))
Check 'planned + released -> the PLANNED one is reported' ("$($p.DocumentNumber)" -eq '1') "$($p.DocumentNumber)"
Check '  so the line reads Planned, which the apps show as Not Started' ((StageOf $p) -eq 'Planned') (StageOf $p)

# A replacement PO still sitting in Planned, with the old one cancelled, is the
# common shape of that: it reads Not Started until somebody releases it.
$p = Select-LeastAdvancedPo @((Po '4422' 'boposCancelled'), (Po '4430' 'boposPlanned'))
Check 'cancelled + a replacement not yet released -> Planned' ((StageOf $p) -eq 'Planned') (StageOf $p)

# An unmapped status must never read as finished; it ranks as in-production.
$p = Select-LeastAdvancedPo @((Po '1' 'boposSomethingNew'), (Po '2' 'boposClosed'))
Check 'an unknown status outranks Closed rather than reading as done' ("$($p.DocumentNumber)" -eq '1') "$($p.DocumentNumber)"

$p = Select-LeastAdvancedPo @()
Check 'no production orders at all -> nothing' ($null -eq $p) "$($p.DocumentNumber)"

Write-Host ''
Write-Host ("{0} passed, {1} failed." -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
