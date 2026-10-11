<#
.SYNOPSIS
  Tick each of the ten SYNC TEST treads with its own "Type - Quality" item
  property, in both companies. Dry run unless -Apply.

.DESCRIPTION
  The user renames the item properties "Type - Quality" in both companies
  (25 Sep 2026): "HOT - Black Pearl", "PCTR - Black Pearl", ... Prices and
  dealer discounts then move per property, so each item must carry exactly the
  one property of its type and quality:

    I-14636 precured Black Pearl  ->  PCTR - Black Pearl
    I-14641 hot Black Pearl       ->  HOT - Black Pearl      ... and so on.

  The property is found BY NAME in each company (spaces and case ignored,
  "PCTR" or "PRECURED" both accepted), so the numbers the user chooses do not
  matter and can differ between the companies. Every other named property is
  unticked on the item. Items and properties are left alone when the name is
  not there yet - the run says which names it could not find.

  Type from the item's name (Get-ItemKind: PRECURED/PCTR, HOT); quality from
  the name (BLACK PEARL, PLATINUM, POLYGOLD, SILVER, DIAMOND). Test data only:
  refuses any item not in group ZZ - Test or not named SYNC TEST.

.EXAMPLE
  .\Set-TestItemGroups.ps1           # show what would change
  .\Set-TestItemGroups.ps1 -Apply    # tick them
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $ConfigPath = 'C:\Users\eldhose\sap-treads-stock-sync\config.json'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'SapSession.ps1')
. (Join-Path $root 'RupeeRules.ps1')
function Say([string] $m, [string] $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Key([string] $s) { return (($s.ToUpperInvariant() -replace 'PRECURED', 'PCTR') -replace '[\s\-]+', ' ').Trim() }

$codes = 14636..14645 | ForEach-Object { "I-$_" }
$qualities = 'BLACK PEARL', 'PLATINUM', 'POLYGOLD', 'SILVER', 'DIAMOND'
$failed = 0; $missing = New-Object System.Collections.Generic.List[string]
Say ("{0} - one Type - Quality property per test tread, both companies" -f $(if ($Apply) { 'APPLY' } else { 'DRY RUN (nothing is written; -Apply to write)' })) $(if ($Apply) { 'Yellow' } else { 'Cyan' })

foreach ($db in 'MANNA_TREADS_LIVE', 'HITECH_PRETREADS_LIVE') {
    $s = New-SapSession -ConfigPath $ConfigPath -CompanyDb $db
    try {
        Say "`n=== $db" Cyan
        $named = @{}
        foreach ($p in @(Get-SapAll $s 'ItemProperties?$select=Number,PropertyName')) {
            if ("$($p.PropertyName)" -notmatch '^Items Property \d+$') { $named[[int]$p.Number] = "$($p.PropertyName)" }
        }
        $byKey = @{}; foreach ($n in $named.Keys) { $byKey[(Key $named[$n])] = $n }
        Say ("named properties: " + (($named.Keys | Sort-Object | ForEach-Object { "$_='$($named[$_])'" }) -join ', ')) DarkGray
        $sel = (1..64 | ForEach-Object { "Properties$_" }) -join ','
        $flt = ($codes | ForEach-Object { "ItemCode eq '$_'" }) -join ' or '
        foreach ($it in @(Get-SapAll $s "Items?`$select=ItemCode,ItemName,ItemsGroupCode,$sel&`$filter=$flt") | Sort-Object ItemCode) {
            $name = "$($it.ItemName)"
            if ($name -notmatch 'SYNC TEST') { throw "$($it.ItemCode) in $db is not a SYNC TEST item - refusing" }
            $kind = Get-ItemKind -Type '' -Name $name
            $quality = @($qualities | Where-Object { $name.ToUpperInvariant().Contains($_) })[0]
            if ($kind -notin 'HOT', 'PCTR' -or -not $quality) { Say ("  {0} type or quality not readable from '{1}' - skipped" -f $it.ItemCode, $name) Yellow; continue }
            $want = "$kind - $((Get-Culture).TextInfo.ToTitleCase($quality.ToLowerInvariant()))"
            $target = $byKey[(Key $want)]
            $ticked = @(1..64 | Where-Object { $it."Properties$_" -eq 'tYES' })
            if (-not $target) {
                if (-not $missing.Contains("$db|$want")) { $missing.Add("$db|$want") }
                Say ("  {0} needs '{1}' - no property of that name in {2} yet; left as it is (ticked now: {3})" -f $it.ItemCode, $want, $db, $(if ($ticked) { $ticked -join ',' } else { 'none' })) Yellow
                continue
            }
            $body = [ordered]@{}
            if ($ticked -notcontains $target) { $body["Properties$target"] = 'tYES' }
            foreach ($n in $ticked) { if ($n -ne $target -and $named.ContainsKey($n)) { $body["Properties$n"] = 'tNO' } }
            if (-not $body.Count) { Say ("  OK   {0} carries only {1} '{2}'" -f $it.ItemCode, $target, $named[$target]) Green; continue }
            $what = ($body.Keys | ForEach-Object { "$($_ -replace 'Properties', 'property ')=$(if ($body[$_] -eq 'tYES') { 'on' } else { 'off' })" }) -join ', '
            if (-not $Apply) { Say ("  WOULD {0} -> {1} '{2}': {3}" -f $it.ItemCode, $target, $named[$target], $what); continue }
            $r = Invoke-SapWrite -Session $s -Method PATCH -Path "Items('$($it.ItemCode)')" -Body $body
            if ($r.Http -eq '204') { Say ("  SET  {0} -> {1} '{2}': {3}" -f $it.ItemCode, $target, $named[$target], $what) Green }
            else { $failed++; Say ("  {0} -> HTTP {1}: {2}" -f $it.ItemCode, $r.Http, (Get-SapShort $r.Body)) Red }
        }
    }
    finally { Close-SapSession $s }
}
if ($missing.Count) { Say ("`nNot named yet: " + (($missing | ForEach-Object { $_ -replace '\|', ': ' }) -join '; ')) Yellow }
if ($failed) { Say "`n$failed write(s) failed." Red; exit 1 }
