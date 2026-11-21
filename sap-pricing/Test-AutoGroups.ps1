<# Offline tests for AutoGroups.ps1, from shared/fixtures/price_groups.json (which
   manna_sap_pricing.py's tests read too):  powershell -File .\Test-AutoGroups.ps1 #>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AutoGroups.ps1')
$fx = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\shared\fixtures\price_groups.json')) | ConvertFrom-Json
$props = @($fx.properties | ForEach-Object { @{ no = [int]$_.no; name = "$($_.name)" } })
$fail = 0
function Check($what, $got, $want) {
    if ("$got" -ne "$want") { Write-Host "FAIL $what : got '$got', want '$want'" -ForegroundColor Red; $script:fail++ }
    else { Write-Host "ok   $what" -ForegroundColor DarkGray }
}

foreach ($c in $fx.groups) {
    $g = Get-AutoGroup -Name $c.name -SubType $c.subType -ItemGroupName $c.itemGroup -Properties $props
    Check $c.why $g.Property $c.property
    if ($null -eq $c.property -and -not $g.Reason) { Write-Host "FAIL $($c.why) : left out with no reason" -ForegroundColor Red; $fail++ }
}
foreach ($c in $fx.standIns) {
    Check "stand-ins: $($c.why)" (Test-StandInCompanies $c.treads $c.hitech) $c.on
}
foreach ($c in $fx.medians) {
    Check "median: $($c.why)" (Get-MedianPrice @($c.prices | ForEach-Object { [double]$_ })) $c.median
}

if ($fail) { Write-Host "$fail failed" -ForegroundColor Red; exit 1 }
Write-Host 'all passed' -ForegroundColor Green
