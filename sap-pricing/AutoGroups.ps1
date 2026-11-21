<#
  Which "Type - Quality" group an item belongs to when nobody has ticked one
  for it in SAP, and the stand-in price a test uses for an item SAP has no
  Price List 01 price for. Pure functions, dot-sourced by
  Sync-SapPricingSnapshot.ps1 and exercised offline by Test-AutoGroups.ps1.

  THE GROUPS (decided with the user, 11 Nov 2026)

  The groups are still Manna Treads' named item properties ("Hot - Black
  Pearl", "PCTR - Platinum"). A property ticked on the item still wins. An item
  with none ticked joins one by:

    type     its SAP item group: HOT -> Hot, PRECURED -> PCTR. Other item
             groups (patches, tubes, tools) join no group.
    quality  its name first ("TREAD RUBBER PRECURED BLACK PEARL 120 ..."),
             else U_SubTypeA. When both say a quality and they disagree, the
             item is left out and listed, not guessed at: in TEST_MANNA_TREADS
             48 of 1,681 treads do (I-1039 is named Platinum, U_SubTypeA says
             Black Pearl). So is an item neither of them names a quality for.

  THE STAND-IN PRICE (local tests only)

  An item with no Price List 01 price (none, or 0) gets its group's median
  price in whole rupees - its type's, when nothing in the group is priced - and
  is marked listPriceSource = 'placeholder'. Only when neither company is
  *_LIVE (Test-StandInCompanies); on live an unpriced item stays unpriced.
#>

Set-StrictMode -Version 1.0

# Name -> quality, matched as text with every space removed - no regex, so the
# ERPNext Server Script (manna_sap_pricing.py, where `re` is not allowed) does
# exactly the same. "POLYCOLD" is how U_SubTypeA spells Polygold on 66 items.
# shared/fixtures/price_groups.json pins the two together.
$script:QualityWords = [ordered]@{
    'BLACK PEARL' = @('BLACKPEARL')
    'PLATINUM'    = @('PLATINUM', 'PLATNIUM')
    'POLYGOLD'    = @('POLYGOLD', 'POLYCOLD')
    'SILVER'      = @('SILVER')
    'DIAMOND'     = @('DIAMOND', 'DAIMOND')
}

<# The one quality a text names, '' when none, 'MULTI' when more than one. #>
function Get-QualityFromText {
    param([string] $Text)
    $t = ("$Text".ToUpperInvariant() -replace '\s', '')
    $found = @(foreach ($q in $script:QualityWords.Keys) {
        if (@($script:QualityWords[$q] | Where-Object { $t.Contains($_) }).Count) { $q }
    })
    if ($found.Count -eq 0) { return '' }
    if ($found.Count -gt 1) { return 'MULTI' }
    return $found[0]
}

<# The type an SAP item group stands for: HOT, PCTR, or '' for any other group. #>
function Get-TypeFromItemGroup {
    param([string] $GroupName)
    $g = "$GroupName".Trim().ToUpperInvariant()
    if ($g -eq 'HOT') { return 'HOT' }
    if ($g -eq 'PRECURED' -or $g -eq 'PCTR') { return 'PCTR' }
    return ''
}

<# "Hot - Black Pearl" / "Hot -Platinum" / "PCTR -- Silver" -> @{ Type = 'HOT'; Quality = 'BLACK PEARL' }, or $null.
   The type is what comes before the first dash; the quality, everything after it. #>
function Split-GroupName {
    param([string] $PropertyName)
    $n = "$PropertyName"
    $i = $n.IndexOf('-')
    if ($i -lt 0) { return $null }
    $type = Get-TypeFromItemGroup $n.Substring(0, $i)
    $quality = Get-QualityFromText $n.Substring($i + 1)
    if (-not $type -or -not $quality -or $quality -eq 'MULTI') { return $null }
    return @{ Type = $type; Quality = $quality }
}

<#
  The group for an item with no property ticked.
  Returns @{ Property = <no or $null>; Reason = <why not, or ''> }.
  $Properties: the named properties, each @{ no; name }.
#>
function Get-AutoGroup {
    param([string] $Name, [string] $SubType, [string] $ItemGroupName, [object[]] $Properties)
    $type = Get-TypeFromItemGroup $ItemGroupName
    if (-not $type) { return @{ Property = $null; Reason = "item group $ItemGroupName is not HOT or PRECURED" } }
    $byName = Get-QualityFromText $Name
    $bySub = Get-QualityFromText $SubType
    if ($byName -eq 'MULTI') { return @{ Property = $null; Reason = 'the name names more than one quality' } }
    if ($byName -and $bySub -and $bySub -ne 'MULTI' -and $byName -ne $bySub) {
        return @{ Property = $null; Reason = "the name says $byName, U_SubTypeA says $SubType" }
    }
    $quality = if ($byName) { $byName } elseif ($bySub -and $bySub -ne 'MULTI') { $bySub } else { '' }
    if (-not $quality) { return @{ Property = $null; Reason = 'neither the name nor U_SubTypeA names a quality' } }
    foreach ($p in $Properties) {
        $g = Split-GroupName $p.name
        if ($g -and $g.Type -eq $type -and $g.Quality -eq $quality) { return @{ Property = [int]$p.no; Reason = '' } }
    }
    return @{ Property = $null; Reason = "no group is named for $type $quality" }
}

<# Stand-in prices only when neither company is live (*_LIVE) and both are named. #>
function Test-StandInCompanies {
    param([string] $TreadsDb, [string] $HitechDb)
    foreach ($d in @($TreadsDb, $HitechDb)) {
        $u = "$d".Trim().ToUpperInvariant()
        if (-not $u -or $u.EndsWith('_LIVE')) { return $false }
    }
    return $true
}

<# The median of some prices, in whole rupees; $null for none. #>
function Get-MedianPrice {
    param([double[]] $Prices)
    $p = @($Prices | Where-Object { $_ -gt 0 } | Sort-Object)
    if ($p.Count -eq 0) { return $null }
    $mid = [int][math]::Floor($p.Count / 2)
    $m = if ($p.Count % 2) { $p[$mid] } else { ($p[$mid - 1] + $p[$mid]) / 2 }
    return [double][math]::Round([decimal]$m, 0, [MidpointRounding]::AwayFromZero)
}
