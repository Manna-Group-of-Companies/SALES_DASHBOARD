<#
.SYNOPSIS
  Proves PASS I's link from Manna Treads' A/R invoices to the order lines
  they billed (12 Nov 2026): the invoice that counts for targets under
  manna_first is Manna Treads' to the customer, not Hi-Tech's.
.DESCRIPTION
  OFFLINE. Extracts the real functions from Sync-SapOrders.ps1 by AST (its main
  body never runs) and calls Get-MtInvoiceLinks as PASS I does. Nothing is read
  or written: no SAP, no ERPNext.
.EXAMPLE
  .\Test-MtInvoices.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$syncPath = Join-Path $PSScriptRoot 'Sync-SapOrders.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($syncPath, [ref]$null, [ref]$null)
$fnText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
           ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($fnText))

$pass = 0; $fail = 0
function Check([string] $Name, [bool] $Ok) {
    if ($Ok) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}
function Obj($h) { [pscustomobject]$h }

# Sales order 590 (two items) delivered on delivery 12; invoice 566 raised from the delivery.
$dn12 = Obj @{ DocEntry = 12; Cancelled = 'tNO'; CancelStatus = 'csNo'; DocumentLines = @(
    (Obj @{ LineNum = 0; ItemCode = 'PMB00200502'; BaseType = 17; BaseEntry = 590 }),
    (Obj @{ LineNum = 1; ItemCode = 'PMB00212508'; BaseType = 17; BaseEntry = 590 })) }
$inv566 = Obj @{ DocEntry = 9565; DocNum = 566; DocDate = '2026-11-12'; Cancelled = 'tNO'; CancelStatus = 'csNo'; DocumentLines = @(
    (Obj @{ ItemCode = 'PMB00200502'; BaseType = 15; BaseEntry = 12; BaseLine = 0 })) }

$links = Get-MtInvoiceLinks -Deliveries @($dn12) -Invoices @($inv566)
Check 'an invoice raised from a delivery is followed back to the sales order line' ($links.ContainsKey('590|PMB00200502') -and "$($links['590|PMB00200502'].DocNum)" -eq '566')
Check 'a delivered line not invoiced yet has no invoice' (-not $links.ContainsKey('590|PMB00212508'))

$inv570 = Obj @{ DocEntry = 9570; DocNum = 570; DocDate = '2026-11-13'; Cancelled = 'tNO'; CancelStatus = 'csNo'; DocumentLines = @(
    (Obj @{ ItemCode = 'PMB00212508'; BaseType = 17; BaseEntry = 590 })) }
$links = Get-MtInvoiceLinks -Deliveries @($dn12) -Invoices @($inv570, $inv566)
Check 'an invoice raised straight from the sales order counts too' ("$($links['590|PMB00212508'].DocNum)" -eq '570')
Check 'each line keeps its own invoice' ("$($links['590|PMB00200502'].DocNum)" -eq '566')

$inv566x = Obj @{ DocEntry = 9566; DocNum = 567; DocDate = '2026-11-14'; Cancelled = 'tNO'; CancelStatus = 'csNo'; DocumentLines = @(
    (Obj @{ ItemCode = 'PMB00200502'; BaseType = 15; BaseEntry = 12; BaseLine = 0 })) }
$links = Get-MtInvoiceLinks -Deliveries @($dn12) -Invoices @($inv566x, $inv566)
Check 'the earliest invoice wins for a line, whatever order SAP lists them in' ("$($links['590|PMB00200502'].DocNum)" -eq '566')

$cancelled = Obj @{ DocEntry = 9565; DocNum = 566; DocDate = '2026-11-12'; Cancelled = 'tYES'; CancelStatus = 'csYes'; DocumentLines = $inv566.DocumentLines }
$links = Get-MtInvoiceLinks -Deliveries @($dn12) -Invoices @($cancelled)
Check 'a cancelled invoice does not count' (-not $links.ContainsKey('590|PMB00200502'))

$dnCancelled = Obj @{ DocEntry = 12; Cancelled = 'tYES'; CancelStatus = 'csYes'; DocumentLines = $dn12.DocumentLines }
$links = Get-MtInvoiceLinks -Deliveries @($dnCancelled) -Invoices @($inv566)
Check 'an invoice on a cancelled delivery cannot be followed to the order' (-not $links.ContainsKey('590|PMB00200502'))

$links = Get-MtInvoiceLinks -Deliveries @() -Invoices @()
Check 'nothing in SAP links nothing' ($links.Count -eq 0)

Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
