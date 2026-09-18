<#
.SYNOPSIS
  Proves Resolve-SapSalesPersonCode tags a SAP order with the rep who raised it.

.DESCRIPTION
  Dot-sources the real Sync-SapOrders.ps1 and calls the SAME function PASS A
  calls - not a copy. Nothing is written and nothing is read: the map is built
  in memory, so this runs with SAP down.

  Two things it exists to hold:

    * the join is the NAME, and nothing else is forgiven. A near-match must
      not silently tag the wrong person's order.
    * an unknown rep must never stop the order reaching the factory. It is a
      warning with a fallback, never a refusal.

.EXAMPLE
  .\Test-SalesPerson.ps1
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

# The live map, as SAP holds it today (codes 10-15).
$map = @{
    'pareeth kb'        = 10
    'jaimon d'          = 11
    'sirajudheen kasim' = 12
    'amjad pr'          = 13
    'prashanth'         = 14
    'test rep'          = 15
}

Write-Host "`nResolve-SapSalesPersonCode" -ForegroundColor Cyan

# --- the rep who raised it ------------------------------------------------
$r = Resolve-SapSalesPersonCode -RepName 'Test Rep' -Map $map -Fallback ''
Check "Test Rep is tagged as SAP sales employee 15" ($r.Code -eq 15) "$($r.Code)"
Check "  with nothing to warn about"                ($r.Warning -eq '')  $r.Warning

foreach ($pair in @(@('Pareeth Kb', 10), @('Jaimon D', 11), @('Sirajudheen Kasim', 12), @('Amjad Pr', 13), @('Prashanth', 14))) {
    $r = Resolve-SapSalesPersonCode -RepName $pair[0] -Map $map -Fallback ''
    Check ("{0} is tagged {1}" -f $pair[0], $pair[1]) ($r.Code -eq $pair[1]) "$($r.Code)"
}

# --- what matching forgives, and what it does not -------------------------
$r = Resolve-SapSalesPersonCode -RepName 'test rep' -Map $map -Fallback ''
Check 'case does not matter'            ($r.Code -eq 15) "$($r.Code)"
$r = Resolve-SapSalesPersonCode -RepName '  Test Rep  ' -Map $map -Fallback ''
Check 'surrounding blanks do not matter' ($r.Code -eq 15) "$($r.Code)"

# A near-match must NOT resolve. Tagging 'Test Reps' orders to 'Test Rep'
# would file one person's work under another's, which is worse than blank.
foreach ($near in @('Test Reps', 'TestRep', 'Test  Rep', 'Test', 'Rep')) {
    $r = Resolve-SapSalesPersonCode -RepName $near -Map $map -Fallback ''
    Check ("'{0}' does not match 'Test Rep'" -f $near) ($null -eq $r.Code) "$($r.Code)"
}

# --- an unknown rep is a warning, never a refusal -------------------------
$r = Resolve-SapSalesPersonCode -RepName 'Nobody At All' -Map $map -Fallback ''
Check 'an unknown rep still lets the order through' ($null -eq $r.Code) "$($r.Code)"
Check '  and names the rep in the warning'          ($r.Warning -match "Nobody At All") $r.Warning
Check '  and says where to add them'                ($r.Warning -match 'Sales Employees') $r.Warning

$r = Resolve-SapSalesPersonCode -RepName 'Nobody At All' -Map $map -Fallback '7'
Check 'an unknown rep falls back to the configured code' ($r.Code -eq 7) "$($r.Code)"
Check '  and still warns'                                ($r.Warning -ne '')  'silent'

# --- no rep at all --------------------------------------------------------
# Nothing to warn about: the order simply does not name one.
foreach ($blank in @('', '   ', 'null')) {
    $r = Resolve-SapSalesPersonCode -RepName $blank -Map $map -Fallback ''
    Check ("a blank rep ('{0}') sends no code" -f $blank) ($null -eq $r.Code) "$($r.Code)"
    Check "  and does not warn"                           ($r.Warning -eq '') $r.Warning
}
# 'null' is an unset Frappe Link read back through naive interpolation. Treating
# it as a rep name would warn on every order that never had one.
$r = Resolve-SapSalesPersonCode -RepName 'null' -Map $map -Fallback '7'
Check "Frappe's string 'null' is not a rep, it is an empty one" ($r.Code -eq 7 -and $r.Warning -eq '') "$($r.Code) / $($r.Warning)"

# --- an empty map ---------------------------------------------------------
# SAP reachable but holding no sales employees: every order warns, none fails.
$r = Resolve-SapSalesPersonCode -RepName 'Test Rep' -Map @{} -Fallback ''
Check 'an empty map warns rather than throwing' ($null -eq $r.Code -and $r.Warning -ne '') "$($r.Code)"

Write-Host ''
Write-Host ("{0} passed, {1} failed." -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
