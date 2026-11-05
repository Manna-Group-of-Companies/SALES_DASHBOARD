<#
.SYNOPSIS
  Proves the SAP Invoice mirror (5 Nov 2026) and the TEST/local pairing guard
  in Sync-SapCreditLimits.ps1.

.DESCRIPTION
  OFFLINE. Extracts the real functions from Sync-SapCreditLimits.ps1 by AST
  (its main body never runs) and calls the same ones the sync calls. Nothing
  is read or written: no SAP, no ERPNext.

.EXAMPLE
  .\Test-InvoiceMirror.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$syncPath = Join-Path $PSScriptRoot 'Sync-SapCreditLimits.ps1'
if (-not (Test-Path $syncPath)) { throw "Cannot find $syncPath" }
$ast = [System.Management.Automation.Language.Parser]::ParseFile($syncPath, [ref]$null, [ref]$null)
$fnText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
           ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($fnText))

# The script-scope constants the functions read, as the sync sets them.
$script:MONEY_EPS  = 0.005
$script:INV_FIELDS = @('customer', 'invoice_no', 'sap_card_code', 'posting_date', 'due_date', 'total', 'paid', 'balance', 'status')
$script:INV_MONEY  = @('total', 'paid', 'balance')
$src = Get-Content -LiteralPath $syncPath -Raw
foreach ($name in 'INV_FIELDS', 'INV_MONEY') {
    $line = ([regex]::Match($src, "(?m)^\`$script:$name\s*=\s*(.+)$")).Groups[1].Value.Trim()
    $mine = (Get-Variable -Scope Script -Name $name).Value
    if ($line -ne ("@('" + ($mine -join "', '") + "')")) { throw "Test copy of `$script:$name differs from the sync's: $line" }
}

$script:pass = 0
$script:fail = 0
function Check {
    param([string] $What, [bool] $Ok, [string] $Got = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  " + $What + $(if ($Got) { "  ->  $Got" } else { '' })) -ForegroundColor Red }
}
function Throws { param([scriptblock] $Block) try { & $Block; return $false } catch { return $true } }
function Inv {
    param([hashtable] $Over = @{})
    $d = [ordered]@{ DocEntry = 9560; DocNum = 561; CardCode = 'C-1183'; DocDate = '2026-10-31T00:00:00Z'; DocDueDate = '2026-11-30T00:00:00Z'
                     DocTotal = 29526; PaidToDate = 0; DocumentStatus = 'bost_Open'; Cancelled = 'tNO' }
    foreach ($k in $Over.Keys) { $d[$k] = $Over[$k] }
    return [pscustomobject]$d
}
$cust = @{ 'C-1183' = 'Kannan Tyres'; 'C-1657' = 'Prasanth TM' }

Write-Host "`nThe pairing guard"
Check 'a TEST_ company with the local copy: allowed' (-not (Throws { Assert-SapErpPairing -ErpSite 'http://127.0.0.1:8000' -CompanyDbs @('TEST_MANNA_TREADS') }))
Check 'the live company with the live site: allowed' (-not (Throws { Assert-SapErpPairing -ErpSite 'https://mannarubber.m.frappe.cloud' -CompanyDbs @('MANNA_TREADS_LIVE') }))
Check 'a TEST_ company with the live site: refused' (Throws { Assert-SapErpPairing -ErpSite 'https://mannarubber.m.frappe.cloud' -CompanyDbs @('TEST_MANNA_TREADS') })
Check 'the live company with the local copy: refused' (Throws { Assert-SapErpPairing -ErpSite 'http://localhost:8000' -CompanyDbs @('MANNA_TREADS_LIVE') })

Write-Host "`nThe financial year"
Check 'November falls in the year from 1 April' ((Get-FyStart ([datetime]'2026-11-05')) -eq '2026-04-01')
Check 'March falls in the year before' ((Get-FyStart ([datetime]'2027-03-31')) -eq '2026-04-01')
Check '1 April starts a new year' ((Get-FyStart ([datetime]'2027-04-01')) -eq '2027-04-01')

Write-Host "`nOne invoice as a mirror row"
$r = ConvertTo-SapInvoiceRecord -Doc (Inv) -Company 'Manna Treads' -CustomerByCode $cust
Check 'is named by company and DocEntry, because DocNum restarts each year' ($r.sap_key -eq 'Manna Treads-9560')
Check 'carries the ERPNext customer found by code' ($r.customer -eq 'Kannan Tyres')
Check 'shows SAP DocNum as the invoice number' ($r.invoice_no -eq '561')
Check 'keeps the SAP dates as dates, not moved by the time zone' ($r.posting_date -eq '2026-10-31' -and $r.due_date -eq '2026-11-30')
Check 'an open invoice is Open, its balance the whole total' ($r.status -eq 'Open' -and $r.balance -eq 29526 -and $r.paid -eq 0)
$p = ConvertTo-SapInvoiceRecord -Doc (Inv @{ PaidToDate = 10000.456 }) -Company 'Manna Treads' -CustomerByCode $cust
Check 'a part payment leaves total - paid, to the paisa' ($p.paid -eq 10000.46 -and $p.balance -eq 19525.54) "$($p.paid) $($p.balance)"
$c = ConvertTo-SapInvoiceRecord -Doc (Inv @{ DocumentStatus = 'bost_Close'; PaidToDate = 29526 }) -Company 'Manna Treads' -CustomerByCode $cust
Check 'a paid invoice is Closed with nothing left' ($c.status -eq 'Closed' -and $c.balance -eq 0)
Check 'an invoice for a code ERPNext does not hold is left out' ($null -eq (ConvertTo-SapInvoiceRecord -Doc (Inv @{ CardCode = 'C-9999' }) -Company 'Manna Treads' -CustomerByCode $cust))
Check 'a DateTime (PowerShell 7 JSON) gives the date it carries' ((ConvertTo-IsoDate ([datetime]'2026-10-31')) -eq '2026-10-31')

Write-Host "`nThe plan"
function Row { param($Rec, [hashtable] $Over = @{}) $h = [ordered]@{ name = $Rec.sap_key }; foreach ($f in $script:INV_FIELDS) { $h[$f] = $Rec[$f] }; foreach ($k in $Over.Keys) { $h[$k] = $Over[$k] }; return [pscustomobject]$h }
$plan = Get-InvoiceMirrorPlan -Wanted @($r) -Existing @()
Check 'a new invoice is created' ($plan.Create.Count -eq 1 -and $plan.Update.Count -eq 0 -and $plan.Delete.Count -eq 0)
$plan = Get-InvoiceMirrorPlan -Wanted @($r) -Existing @((Row $r @{ total = '29526.000000'; posting_date = '2026-10-31' }))
Check 'a row ERPNext already holds the same is left alone (money as text, to the paisa)' ($plan.Create.Count -eq 0 -and $plan.Update.Count -eq 0 -and $plan.Delete.Count -eq 0)
$plan = Get-InvoiceMirrorPlan -Wanted @($c) -Existing @((Row $r))
Check 'a payment changes only paid, balance and status' ($plan.Update.Count -eq 1 -and (@($plan.Update[0].Fields.Keys) -join ',') -eq 'paid,balance,status') ((@($plan.Update[0].Fields.Keys)) -join ',')
$gone = Row (ConvertTo-SapInvoiceRecord -Doc (Inv @{ DocEntry = 1; DocNum = 1 }) -Company 'Manna Treads' -CustomerByCode $cust)
$plan = Get-InvoiceMirrorPlan -Wanted @($r) -Existing @((Row $r), $gone)
Check 'a row SAP no longer gives (cancelled) is deleted' ($plan.Delete.Count -eq 1 -and $plan.Delete[0].name -eq 'Manna Treads-1')
$many = 1..30 | ForEach-Object { Row (ConvertTo-SapInvoiceRecord -Doc (Inv @{ DocEntry = 100 + $_ }) -Company 'Manna Treads' -CustomerByCode $cust) }
$plan = Get-InvoiceMirrorPlan -Wanted @() -Existing $many
Check 'an empty SAP read deletes nothing from a mirror of 30' ($plan.Delete.Count -eq 0 -and $plan.DeletesHeld -eq 30)
$plan = Get-InvoiceMirrorPlan -Wanted @($many[0..19] | ForEach-Object { ConvertTo-SapInvoiceRecord -Doc (Inv @{ DocEntry = [int]($_.name -replace '.*-', '') }) -Company 'Manna Treads' -CustomerByCode $cust }) -Existing $many
Check 'ten of thirty gone is believed, and deleted' ($plan.Delete.Count -eq 10 -and $plan.DeletesHeld -eq 0)
$plan = Get-InvoiceMirrorPlan -Wanted @() -Existing @((Row $r), $gone)
Check 'a small mirror may empty (a customer with two invoices both cancelled)' ($plan.Delete.Count -eq 2)

Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
