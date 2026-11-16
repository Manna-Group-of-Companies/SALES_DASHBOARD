<#
.SYNOPSIS
  Proves the credit-period push (16 Nov 2026) in Sync-SapCreditLimits.ps1.

.DESCRIPTION
  OFFLINE. Extracts the real functions from Sync-SapCreditLimits.ps1 by AST
  (its main body never runs), runs Get-TermPushPlan and Get-SapTermDays on
  every case of shared/fixtures/credit_period_request.json - the cases the
  Server Script and both apps test too - and drives Invoke-TermPushes against
  a stand-in for the Service Layer and ERPNext. No SAP, no ERPNext.

.EXAMPLE
  .\Test-CreditPeriodPush.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$syncPath = Join-Path $PSScriptRoot 'Sync-SapCreditLimits.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($syncPath, [ref]$null, [ref]$null)
$fnText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
           ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($fnText))

$fixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\shared\fixtures\credit_period_request.json') -Raw | ConvertFrom-Json

$script:pass = 0
$script:fail = 0
function Check {
    param([string] $What, [bool] $Ok, [string] $Got = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  " + $What + $(if ($Got) { "  ->  $Got" } else { '' })) -ForegroundColor Red }
}
# The log goes nowhere; the stand-ins below record what would have been sent.
function Write-Log { param([string] $Level, [string] $Message) $script:log.Add("$Level $Message") }

Write-Host "`nA term's days (term_days)"
foreach ($c in $fixture.term_days) {
    $got = Get-SapTermDays -Name $c.name -Months $c.months -Days $c.extra_days
    Check $c.why ($got -eq $c.days) "$got"
}

Write-Host "`nWhat the sync does with a request (sap_push)"
foreach ($c in $fixture.sap_push) {
    $plan = Get-TermPushPlan -Request $c.request -Terms @($c.sap_terms) -CurrentCode $c.sap_current_code
    Check $c.why ($plan.Action -eq $c.expect) ("{0}: {1}" -f $plan.Action, $plan.Reason)
}

Write-Host "`nThe push itself, against a stand-in Service Layer"
# Stand-ins: a function wins over a cmdlet of the same name.
$script:bp = @{}
$script:calls = New-Object System.Collections.Generic.List[string]
$script:results = New-Object System.Collections.Generic.List[object]
$script:patchFails = $false
function Invoke-RestMethod {
    param($Method, $Uri, $WebSession, $ErrorAction, $TimeoutSec, $Body, $ContentType, [switch] $SkipCertificateCheck)
    $code = [regex]::Match($Uri, "BusinessPartners\('([^']+)'\)").Groups[1].Value
    $script:calls.Add("$Method $code")
    if ($Method -eq 'Patch') {
        if ($script:patchFails) { throw 'SAP says no' }
        $script:bp[$code] = ($Body | ConvertFrom-Json).PayTermsGrpCode
        return $null
    }
    return [pscustomobject]@{ CardCode = $code; PayTermsGrpCode = $script:bp[$code] }
}
function Send-ErpTermPushResult {
    param([string] $Name, [bool] $Ok, [string] $ErrorText = '', [string] $PreviousTerm = '', [string] $Company = '')
    $script:results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Error = $ErrorText; Previous = $PreviousTerm; Company = $Company })
}
function Reset { $script:bp = @{ 'C-1001' = 1; 'C-1002' = 1 }; $script:calls.Clear(); $script:results.Clear(); $script:log = New-Object System.Collections.Generic.List[string]; $script:patchFails = $false }
$terms = @(
    [pscustomobject]@{ code = 1; name = 'Net-30'; days = 30 },
    [pscustomobject]@{ code = 10; name = 'Net-35'; days = 35 }
)
function Req {
    param([string] $Name, [string] $Bp, [int] $Code, [string] $Term, [int] $Days, [string] $Role)
    return [pscustomobject]@{ name = $Name; status = 'Sending to SAP'; bp_code = $Bp; requested_term_code = $Code; requested_term = $Term; requested_days = $Days; approver_role = $Role }
}
function Push { param([object[]] $Reqs, [bool] $Enabled = $true, [bool] $Dry = $false)
    Invoke-TermPushes -BaseUrl 'https://sl/b1s/v1' -Session $null -UseSkipCert $false -Requests $Reqs -Terms $terms `
        -CompanyName 'Manna Treads' -CompanyDb 'TEST_MANNA_TREADS' -Enabled $Enabled -IsDryRun $Dry }

Reset
$r = Push @(Req 'CPR-00001' 'C-1001' 10 'Net-35' 35 'gm')
Check 'the GM-approved request changes the term in SAP' ($script:bp['C-1001'] -eq 10) "$($script:bp['C-1001'])"
Check 'it reads the partner, writes, and reads it back' (($script:calls -join ',') -eq 'Get C-1001,Patch C-1001,Get C-1001') ($script:calls -join ',')
Check 'and tells ERPNext it is in SAP, with the term before and the company' ($script:results.Count -eq 1 -and $script:results[0].Ok -and $script:results[0].Previous -eq 'Net-30' -and $script:results[0].Company -eq 'TEST_MANNA_TREADS') ($script:results | ConvertTo-Json -Compress)
Check 'counted as done' ($r.Done -eq 1 -and $r.Failed -eq 0)

Reset
$r = Push @(Req 'CPR-00002' 'C-1001' 10 'Net-35' 35 'manager')
Check 'a manager-approved 35 days is never written' ($script:bp['C-1001'] -eq 1 -and -not ($script:calls -contains 'Patch C-1001'))
Check 'and the request is told why' ($script:results.Count -eq 1 -and -not $script:results[0].Ok -and $script:results[0].Error -match 'GM') ($script:results | ConvertTo-Json -Compress)
Check 'counted as a failure' ($r.Failed -eq 1)

Reset
$script:bp['C-1001'] = 10
$r = Push @(Req 'CPR-00003' 'C-1001' 10 'Net-35' 35 'gm')
Check 'already on the term: no write, but it is In SAP' (-not ($script:calls -contains 'Patch C-1001') -and $script:results[0].Ok) ($script:calls -join ',')

Reset
$script:patchFails = $true
$script:bp['C-1001'] = 4
$r = Push @((Req 'CPR-00004' 'C-1001' 1 'Net-30' 30 'manager'), (Req 'CPR-00005' 'C-1002' 10 'Net-35' 35 'gm'))
Check "SAP's refusal goes back on the request" ($script:results[0].Name -eq 'CPR-00004' -and -not $script:results[0].Ok -and $script:results[0].Error -match 'SAP says no') ($script:results | ConvertTo-Json -Compress)
Check 'and one failure does not stop the next request' ($script:results.Count -eq 2 -and $r.Failed -eq 2)

Reset
$r = Push @(Req 'CPR-00006' 'C-1001' 10 'Net-35' 35 'gm') -Enabled $false
Check 'push_payment_terms off: nothing written to SAP' ($script:bp['C-1001'] -eq 1 -and -not ($script:calls -contains 'Patch C-1001'))
Check 'nor to ERPNext - the request waits' ($script:results.Count -eq 0)
Check 'but the log says what would happen' (($script:log -join "`n") -match 'would patch')

Reset
$r = Push @(Req 'CPR-00007' 'C-1001' 10 'Net-35' 35 'gm') -Dry $true
Check 'DryRun: nothing written anywhere' ($script:bp['C-1001'] -eq 1 -and $script:results.Count -eq 0)

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
