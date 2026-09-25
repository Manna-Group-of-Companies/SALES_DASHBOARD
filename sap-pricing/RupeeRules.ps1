<#
  The rates rules, as pure functions - the PowerShell twin of
  client/src/domain/dealerRates.ts, pinned together with it by
  shared/fixtures/dealer_rates.json. Dot-sourced by Sync-SapPricingSnapshot.ps1,
  which checks SAP with them on every sync, and exercised offline by
  Test-RupeeRules.ps1.

  THE RULES

    dealer price  = the item's Manna Treads Price List 01 price
                    - the dealer's rupees off for the item's quality
    Hi-Tech price = the same item's Manna Treads price - the inter-company margin

  A customer gets a fixed number of rupees off per kg on every item of one
  quality: "dealer A gets Rs 5 off Black Pearl". SAP cannot store that - its
  discount groups hold only a percentage, and a special price holds a price or
  a percentage - so the rupees live in ERPNext (SAP Dealer Rate Rule) and SAP
  holds only what they produce, recomputed whenever a price or a rule changes.

  The dealers are Manna Treads' customers; Hi-Tech Pretreads bills Manna Treads
  a fixed number of rupees per kg below Manna Treads' own price, item by item
  (decided 25 Sep 2026). The margin is kept in ERPNext, not here: this code is
  public.

  Every price and discount is GST-inclusive as it stands. Nothing here adds or
  removes GST.

  A quality is an SAP item property (1-64) ticked on the item. An item matching
  two ruled properties for the same customer is refused, not guessed at.
#>

Set-StrictMode -Version 1.0

$script:Invariant = [Globalization.CultureInfo]::InvariantCulture

# Through decimal: 146.525 as a double is a hair under 146.525, and rounding
# the double directly would give 146.52 on the half-paisa.
function Round-Money([double] $x) {
    return [double][math]::Round([decimal]$x, 2, [MidpointRounding]::AwayFromZero)
}

<#
  The dealer price for one item, from its list price and the rupees off.
  Returns Price (rounded to the paisa) and DiscountPercent (for display only,
  from the rounded price). Refuses a discount that is not smaller than the list
  price - a free or negative price is a mistake in the rules, not an instruction.
#>
function Get-SpecialPrice {
    param([double] $ListPrice, [double] $RupeesOff)
    if ($ListPrice -le 0) { throw "no list price" }
    if ($RupeesOff -le 0) { throw "rupees off must be more than zero" }
    $price = Round-Money ($ListPrice - $RupeesOff)
    if ($price -le 0) { throw ("Rs {0} off is not less than the list price {1}" -f (Round-Money $RupeesOff), $ListPrice) }
    $pct = [math]::Round((($ListPrice - $price) / $ListPrice) * 100, 6)
    return [pscustomobject]@{ Price = $price; DiscountPercent = $pct }
}

<# Hi-Tech Pretreads' price for an item: Manna Treads' price for its twin less the margin. #>
function Get-HitechPrice {
    param([double] $TreadsPrice, [double] $Margin)
    if ($Margin -le 0) { throw "no inter-company margin is set" }
    if ($TreadsPrice -le 0) { throw "no Manna Treads price" }
    $price = Round-Money ($TreadsPrice - $Margin)
    if ($price -le 0) { throw ("the margin Rs {0} is not less than Manna Treads' price {1}" -f (Round-Money $Margin), $TreadsPrice) }
    return $price
}

<#
  The item's type as the office says it - HOT, PCTR (precured), BONDING GUM or
  OTHER - from its type field, then its name. List prices move per type x
  quality (the user, 25 Sep 2026). Gum is looked for first (gum is never a
  tread); precured wins over hot. The twin of itemKind() in dealerRates.ts.
#>
function Get-ItemKind {
    param([string] $Type, [string] $Name)
    foreach ($t in @("$Type".ToUpperInvariant(), "$Name".ToUpperInvariant())) {
        if ($t -match '\bGUM\b') { return 'BONDING GUM' }
        if ($t.Contains('PRECURED') -or $t -match '\bPCTR\b') { return 'PCTR' }
        if ($t -match '\bHOT\b') { return 'HOT' }
    }
    return 'OTHER'
}

<# A rule as the screen compares it: card|property|rupees. #>
function Get-RuleSignature {
    param([string] $CardCode, [int] $Property, [double] $Rupees)
    return ('{0}|{1}|{2}' -f $CardCode, $Property, (Round-Money $Rupees).ToString('0.##', $script:Invariant))
}

<#
  The office server's own check of SAP - counted exactly as the screen's
  checkAgainstSap + checkCounts count, so the two can be compared.

  $Items    Manna Treads items: Code, Props (ticked named property numbers),
            ListPrice (or $null), Twin (Hi-Tech item code or $null)
  $Special  hashtable "<card>|<item>" -> object with Price and PriceListNum
  $Hitech   hashtable Hi-Tech item code -> its Price List 01 price (or $null);
            $null when Hi-Tech was not read
  $Rules    objects with CardCode, Property, Rupees
  $Margin   rupees per kg; 0 or less = not set

  Dealer prices: OK / DRIFT (another price) / KIND (still a percentage of a
  price list) / MISSING (SAP has none). Hi-Tech prices: OK / DRIFT / MISSING (the
  twin has no price). Refused rows (no list price, too big a discount) are not
  counted; conflicts (an item in two of one dealer's ruled qualities) are.
#>
function Get-RatesCheck {
    param($Items, [hashtable] $Special, $Hitech, $Rules, [double] $Margin)
    $dealer = [ordered]@{ OK = 0; DRIFT = 0; MISSING = 0; KIND = 0 }
    $hi = [ordered]@{ OK = 0; DRIFT = 0; MISSING = 0 }
    $conflicts = 0; $noTwin = 0; $refused = 0

    foreach ($card in @($Rules | ForEach-Object { "$($_.CardCode)" } | Sort-Object -Unique)) {
        $mine = @($Rules | Where-Object { "$($_.CardCode)" -eq $card })
        foreach ($it in $Items) {
            $hit = @($mine | Where-Object { @($it.Props) -contains [int]$_.Property })
            if ($hit.Count -eq 0) { continue }
            if ($hit.Count -gt 1) { $conflicts++; continue }
            $list = if ($null -eq $it.ListPrice) { 0 } else { [double]$it.ListPrice }
            try { $sp = Get-SpecialPrice -ListPrice $list -RupeesOff ([double]$hit[0].Rupees) } catch { $refused++; continue }
            $key = "$card|$($it.Code)"
            if (-not $Special.ContainsKey($key)) { $dealer.MISSING++; continue }
            $now = $Special[$key]
            if ([int]$now.PriceListNum -ne 0) { $dealer.KIND++ }
            elseif ([math]::Abs([double]$now.Price - $sp.Price) -gt 0.004) { $dealer.DRIFT++ }
            else { $dealer.OK++ }
        }
    }

    if ($null -ne $Hitech) {
        foreach ($it in $Items) {
            $tw = "$($it.Twin)"
            if (-not $tw -or -not $Hitech.ContainsKey($tw)) { $noTwin++; continue }
            if ($Margin -le 0) { continue }
            $list = if ($null -eq $it.ListPrice) { 0 } else { [double]$it.ListPrice }
            try { $want = Get-HitechPrice -TreadsPrice $list -Margin $Margin } catch { $refused++; continue }
            $now = $Hitech[$tw]
            if ($null -eq $now -or [double]$now -le 0) { $hi.MISSING++ }
            elseif ([math]::Abs([double]$now - $want) -le 0.004) { $hi.OK++ }
            else { $hi.DRIFT++ }
        }
    }

    return [ordered]@{
        margin = $(if ($Margin -gt 0) { Round-Money $Margin } else { $null })
        rules = @($Rules | ForEach-Object { Get-RuleSignature -CardCode $_.CardCode -Property $_.Property -Rupees $_.Rupees })
        dealer = $dealer; hitech = $hi; noTwin = $noTwin; conflicts = $conflicts; refused = $refused
    }
}
