<#
.SYNOPSIS
  Proves the temporary credit extension job's decisions (16 Nov 2026) offline.

.DESCRIPTION
  Extracts the functions of Sync-CreditExtensions.ps1 and of the credit sync
  it borrows from, by AST (no body runs), and runs every 'payments',
  'sap_raise' and 'sap_restore' case of shared/fixtures/credit_extension.json.
  No SAP, no ERPNext.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

foreach ($f in 'Sync-SapCreditLimits.ps1', 'Sync-CreditExtensions.ps1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $f), [ref]$null, [ref]$null)
    . ([scriptblock]::Create((($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        ForEach-Object { $_.Extent.Text }) -join "`n")))
}
$fx = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\shared\fixtures\credit_extension.json') -Raw | ConvertFrom-Json

$script:pass = 0; $script:fail = 0
function Check {
    param([string] $What, [bool] $Ok, [string] $Got = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  " + $What + $(if ($Got) { "  ->  $Got" } else { '' })) -ForegroundColor Red }
}

Write-Host "`nPayments that count (payments)"
foreach ($c in $fx.payments) {
    $got = Get-CountedPayments -Payments @($c.payment) -From $c.approved_on -To $c.commitment
    $sum = [double](($got | ForEach-Object { $_.amount } | Measure-Object -Sum).Sum)
    Check $c.why ($sum -eq [double]$c.expect) "$sum"
}
$p = [pscustomobject]@{ DocEntry = 9; DocDate = '2026-11-18'; Cancelled = 'tNO'; Proforma = 'tNO'; TransferSum = 50000 }
$twice = Get-CountedPayments -Payments @($p, $p) -From '2026-11-16' -To '2026-11-26'
Check 'the same payment read twice counts once' ($twice.Count -eq 1) "$($twice.Count)"

Write-Host "`nRaising the limit (sap_raise)"
foreach ($c in $fx.sap_raise) {
    $plan = Get-ExtensionRaisePlan -Status $c.status -SavedOriginal $c.saved_original -SapLimit $c.sap_limit -Amount $c.amount -OtherRaised ([bool]$c.other_raised) `
        -SavedCommitment $c.saved_commitment -SapCommitment $c.sap_commitment
    $ok = ($plan.Action -eq $c.expect)
    if ($ok -and $c.PSObject.Properties['target']) {
        $ok = ($plan.Target -eq [double]$c.target -and $plan.Original -eq [double]$c.original -and
               $plan.OriginalCommitment -eq [double]$c.original_commitment -and $plan.CommitmentTarget -eq [double]$c.commitment_target)
    }
    Check $c.why $ok ("{0} {1} -> {2}, commitment {3} -> {4}: {5}" -f $plan.Action, $plan.Original, $plan.Target, $plan.OriginalCommitment, $plan.CommitmentTarget, $plan.Reason)
}

Write-Host "`nPutting it back (sap_restore)"
foreach ($c in $fx.sap_restore) {
    $plan = Get-ExtensionRestorePlan -Original $c.original -Amount $c.amount -SapLimit $c.sap_limit `
        -OriginalCommitment $c.original_commitment -RaisedCommitment $c.raised_commitment -SapCommitment $c.sap_commitment
    Check $c.why ($plan.Action -eq $c.expect) ("{0}: {1}" -f $plan.Action, $plan.Reason)
}

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
