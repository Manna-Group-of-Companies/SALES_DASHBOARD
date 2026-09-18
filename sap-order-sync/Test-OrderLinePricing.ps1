<#
.SYNOPSIS
  Proves New-SapOrderLine prices a line the way the manager approved it.

.DESCRIPTION
  Dot-sources the real Sync-SapOrders.ps1 and calls the SAME function PASS A
  calls - not a copy of it - against live ERPNext Sales Orders. Nothing is
  written anywhere: no SAP POST, no ERPNext PUT.

  The assertion that matters is one line:

      Quantity x UnitPrice x (1 - DiscountPercent/100)  ==  the ERPNext amount

  If that holds for every line, the SAP order totals what the rep quoted and
  the manager approved.

.EXAMPLE
  .\Test-OrderLinePricing.ps1 -ConfigPath .\config.json
  .\Test-OrderLinePricing.ps1 -ConfigPath .\config.json -Orders SAL-ORD-2026-00135
#>
[CmdletBinding()]
param(
    [string]   $ConfigPath = "$PSScriptRoot\config.json",
    [string[]] $Orders,
    [int]      $Limit = 10
)

$ErrorActionPreference = 'Stop'

# Dot-source the sync for its helpers. `-WhatIfOnlyLoadFunctions` does not
# exist, so the script is loaded with a parameter set that makes its main body
# a no-op: it needs -ConfigPath, and we give it one, but we never let it run
# because the body is guarded by the $MyInvocation check below. In practice the
# sync's body runs on load, so instead the file is parsed and only its function
# definitions are executed.
$syncPath = Join-Path $PSScriptRoot 'Sync-SapOrders.ps1'
if (-not (Test-Path $syncPath)) { throw "Cannot find $syncPath" }

$ast = [System.Management.Automation.Language.Parser]::ParseFile($syncPath, [ref]$null, [ref]$null)
$fnText = ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
           ForEach-Object { $_.Extent.Text }) -join "`n"
. ([scriptblock]::Create($fnText))

# The sync's own logger writes to a file and a log level; the test only needs
# it to not blow up when New-SapOrderLine warns.
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log { param($Level, $Message) Write-Host ("    [{0}] {1}" -f $Level, $Message) -ForegroundColor DarkYellow }
} else {
    function Write-Log { param($Level, $Message) Write-Host ("    [{0}] {1}" -f $Level, $Message) -ForegroundColor DarkYellow }
}

$cfg  = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$erp  = $cfg.erpnext
$send = $true
if ($null -ne $cfg.order_sync -and $null -ne $cfg.order_sync.send_line_unit_price) {
    $send = [bool]$cfg.order_sync.send_line_unit_price
}

$headers = @{ Authorization = ("token {0}:{1}" -f $erp.api_key, $erp.api_secret) }
$base    = $erp.site.TrimEnd('/')

if (-not $Orders) {
    $listUrl = "$base/api/resource/Sales%20Order?fields=%5B%22name%22%5D&limit_page_length=$Limit&order_by=creation%20desc"
    $Orders  = (Invoke-RestMethod -Uri $listUrl -Headers $headers -Method GET).data | ForEach-Object { $_.name }
}

Write-Host ""
Write-Host ("send_line_unit_price = {0}" -f $send) -ForegroundColor Cyan
Write-Host ""

$fail = 0
$checked = 0

foreach ($name in $Orders) {
    $doc = (Invoke-RestMethod -Uri ("$base/api/resource/Sales%20Order/" + [uri]::EscapeDataString($name)) -Headers $headers -Method GET).data
    Write-Host ("{0}   ERPNext total {1}" -f $name, $doc.grand_total) -ForegroundColor White

    $sapTotal = 0.0
    $idx = 0
    foreach ($it in $doc.items) {
        $built = New-SapOrderLine -Item $it -SendUnitPrice $send -OrderName $name -Index $idx
        if ($built.Error) {
            Write-Host ("    REFUSED: {0}" -f $built.Error) -ForegroundColor Red
            $fail++; $idx++; continue
        }
        $l = $built.Line
        $lineTotal = [double]$l.Quantity * [double]$l.UnitPrice * (1 - ([double]$l.DiscountPercent / 100))
        $sapTotal += $lineTotal
        $want = [double]$it.amount
        $ok   = [math]::Abs($lineTotal - $want) -le [math]::Max(0.02, 0.0005 * [math]::Max($want, 1))
        if (-not $ok) { $fail++ }
        $checked++

        Write-Host ("    {0,-11} {1,8} kg x {2,9} /kg  less {3,5}%  = {4,11}   erpnext {5,11}   {6}" -f `
            $l.ItemCode, $l.Quantity, $l.UnitPrice, $l.DiscountPercent,
            [math]::Round($lineTotal, 2), $want, $(if ($ok) { 'OK' } else { 'MISMATCH' })) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        $idx++
    }

    $totalOk = [math]::Abs($sapTotal - [double]$doc.total) -le 0.05
    Write-Host ("    -> SAP order would total {0}  (ERPNext net total {1})  {2}" -f `
        [math]::Round($sapTotal, 2), $doc.total, $(if ($totalOk) { 'MATCH' } else { 'DIFFERS' })) `
        -ForegroundColor $(if ($totalOk) { 'Green' } else { 'Red' })
    if (-not $totalOk) { $fail++ }
    Write-Host ""
}

Write-Host ("{0} lines checked, {1} problem(s)." -f $checked, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
