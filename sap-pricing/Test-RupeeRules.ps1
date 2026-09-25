<#
  Offline tests for RupeeRules.ps1 - no SAP, no ERPNext. Most cases come from
  shared/fixtures/dealer_rates.json, which the rates screen's own tests run too
  (client/src/domain/__tests__/dealerRates.test.ts).
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-RupeeRules.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RupeeRules.ps1')

$script:pass = 0; $script:fail = 0
function Check([string] $what, $got, $want) {
    if ("$got" -eq "$want") { $script:pass++ } else { $script:fail++; Write-Host ("FAIL {0}: got [{1}] want [{2}]" -f $what, $got, $want) -ForegroundColor Red }
}
function Throws([string] $what, [scriptblock] $b, [string] $like) {
    try { & $b; $script:fail++; Write-Host "FAIL ${what}: did not throw" -ForegroundColor Red }
    catch { if ("$($_.Exception.Message)" -like $like) { $script:pass++ } else { $script:fail++; Write-Host ("FAIL {0}: threw [{1}]" -f $what, $_.Exception.Message) -ForegroundColor Red } }
}

# ---- the question this folder exists to answer ----
# Rs 1 off at a list price of 10 is 9. When the list becomes 12 it must be 11,
# not 10.80 - which is what a 10% discount would give.
Check 'Rs 1 off list 10' (Get-SpecialPrice 10 1).Price 9
Check 'Rs 1 off list 12' (Get-SpecialPrice 12 1).Price 11
Check 'what a kept percentage would have given' (Round-Money (12 * (1 - 0.10))) 10.8

# ---- shared/fixtures/dealer_rates.json ----
$fx = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\shared\fixtures\dealer_rates.json')) | ConvertFrom-Json
foreach ($c in $fx.special_price) {
    $r = Get-SpecialPrice ([double]$c.list) ([double]$c.rupees)
    Check "fixture: $($c.why)" $r.Price ([double]$c.price)
    Check "fixture %: $($c.why)" $r.DiscountPercent ([double]$c.percent)
}
foreach ($c in $fx.refused) { $l = [double]$c.list; $x = [double]$c.rupees; Throws "fixture: $($c.why)" { Get-SpecialPrice $l $x } "*$($c.error)*" }
foreach ($c in $fx.rounding) { Check "fixture: $($c.why)" (Round-Money ([double]$c.value)) ([double]$c.expect) }
foreach ($c in $fx.hitech_price) { Check "fixture: $($c.why)" (Get-HitechPrice ([double]$c.treads) ([double]$c.margin)) ([double]$c.hitech) }
foreach ($c in $fx.hitech_refused) { $t = [double]$c.treads; $m = [double]$c.margin; Throws "fixture: $($c.why)" { Get-HitechPrice $t $m } "*$($c.error)*" }

foreach ($c in $fx.item_kind) { Check "fixture type: $($c.why)" (Get-ItemKind -Type $c.type -Name $c.name) $c.kind }

# The type x quality change: the new Manna Treads prices, the dealers' and the twins'.
$q = $fx.quality_change
$moved = @{}; foreach ($ch in $q.changes) { $moved["$($ch.kind)|$([int]$ch.propertyNo)"] = [double]$ch.rupees }
foreach ($i in $q.items) {
    $kind = Get-ItemKind -Type $i.type -Name $i.code
    $by = @($i.props | Where-Object { $moved.ContainsKey("$kind|$([int]$_)") })
    $new = if ($by.Count) { Round-Money ([double]$i.listPrice + $moved["$kind|$([int]$by[0])"]) } else { [double]$i.listPrice }
    Check "fixture quality change: list $($i.code)" $new $q.expect_list.($i.code)
    Check "fixture quality change: Hi-Tech $($i.code)" (Get-HitechPrice $new ([double]$q.margin)) $q.expect_hitech.($i.code)
    foreach ($r in $q.rules | Where-Object { @($i.props) -contains [int]$_.propertyNo }) {
        Check "fixture quality change: dealer $($r.cardCode)|$($i.code)" (Get-SpecialPrice $new ([double]$r.rupeesOff)).Price $q.expect_dealer.("$($r.cardCode)|$($i.code)")
    }
}

# The check: the same counts the screen gets from checkAgainstSap + checkCounts.
$c = $fx.check
$items = foreach ($i in $c.items) { [pscustomobject]@{ Code = $i.code; Props = @($i.props | ForEach-Object { [int]$_ }); ListPrice = $i.listPrice; Twin = $i.twin } }
$special = @{}; foreach ($s in $c.special) { $special["$($s.card)|$($s.item)"] = [pscustomobject]@{ Price = [double]$s.price; PriceListNum = [int]$s.priceList } }
$hitech = @{}; foreach ($h in $c.hitech) { $hitech["$($h.code)"] = $h.listPrice }
$rules = foreach ($r in $c.rules) { [pscustomobject]@{ CardCode = $r.cardCode; Property = [int]$r.propertyNo; Rupees = [double]$r.rupeesOff } }
$res = Get-RatesCheck -Items @($items) -Special $special -Hitech $hitech -Rules @($rules) -Margin ([double]$c.margin)
foreach ($s in 'OK', 'DRIFT', 'MISSING', 'KIND') { Check "fixture check: dealer $s" $res.dealer[$s] $c.expect_dealer_counts.$s }
foreach ($s in 'OK', 'DRIFT', 'MISSING') { Check "fixture check: Hi-Tech $s" $res.hitech[$s] $c.expect_hitech_counts.$s }
Check 'fixture check: no twin' $res.noTwin $c.expect_no_twin
Check 'fixture check: conflicts' $res.conflicts $c.expect_conflicts
Check 'fixture check: the rules as the screen writes them' ($res.rules -join ';') 'A|1|5;A|2|3'
Check 'fixture check: the margin it used' $res.margin 12

# ---- beyond the fixture ----
Check 'a rule with paise, written as the screen writes it' (Get-RuleSignature 'A' 2 8.5) 'A|2|8.5'
$noMargin = Get-RatesCheck -Items @($items) -Special $special -Hitech $hitech -Rules @($rules) -Margin 0
Check 'no margin: no Hi-Tech price is checked' ($noMargin.hitech.OK + $noMargin.hitech.DRIFT + $noMargin.hitech.MISSING) 0
Check 'no margin: the twins are still counted' $noMargin.noTwin 2
Check 'no margin: recorded as not set' ($null -eq $noMargin.margin) $true
$noHitech = Get-RatesCheck -Items @($items) -Special $special -Hitech $null -Rules @($rules) -Margin 12
Check 'Hi-Tech not read: nothing counted as without a twin' $noHitech.noTwin 0

Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
