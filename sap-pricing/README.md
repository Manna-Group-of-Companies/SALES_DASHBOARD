# sap-pricing — dealer prices in rupees, and the Hi-Tech price list that follows

PowerShell, run on the SAP server, behind the Managing Director's rates screen
in the dashboard (`client/src/features/rates/`). Reads SAP through the Service
Layer. Writes to SAP only through DTW files that a person imports.

## The rules

Decided with the user on 25 September 2026.

- **The dealers are Manna Treads' customers.** Their prices live in
  `MANNA_TREADS_LIVE`, and Manna Treads' Price List 01 ("selling price") is
  the master.
- **Dealer price = Manna Treads' list price − the dealer's rupees off** for
  the item's quality. A dealer gets a fixed number of rupees off per kg on
  every item of one quality, precured and hot alike.
- **Hi-Tech price = Manna Treads' price for the same item − the inter-company
  margin.** Hi-Tech Pretreads bills Manna Treads that many rupees per kg below
  Manna Treads' own price, so Manna Treads earns its keep. The rule applies to
  Price List 01 in `HITECH_PRETREADS_LIVE`, item by item.
- **Every price and every discount includes GST, as it stands, in both
  companies.** Nothing multiplies or divides by a GST rate.
- **The margin is kept in ERPNext**, in *SAP Pricing Control → Hi-Tech Bills
  Manna Treads Less*. It is not kept here, because this repository is public.
  For the same reason the real dealer rules live in ERPNext
  (*SAP Dealer Rate Rule*).

**The groups are SAP's item properties** (1–64), which the user names
"Type - Quality" in both companies: "HOT - Black Pearl", "PCTR - Black Pearl",
and so on. Each item carries exactly one (25 Sep 2026).
- A list-price change is made per group: every item carrying that property
  moves by the same rupees.
- A dealer's discount is per group too, so a dealer can get different rupees
  off HOT and PCTR of the same quality.
- A property newly named in SAP, such as "BONDING GUM - Black Pearl", appears
  on the screen as a new group with no code change.
- An item carrying two named properties is flagged, and a change to both of
  its groups is refused for it.

The code still calls a group a "quality" in places; its name is whatever SAP
says. The type shown beside an item (HOT, PCTR, BONDING GUM) is read from its
name (`Get-ItemKind` / `itemKind`) and is for display only.

### Why SAP gets prices, not percentages

A 10% discount off ₹10 is ₹1. When the list price becomes ₹12, the same 10% is
₹1.20, not ₹1. SAP has no field that holds "list price minus ₹1":
- discount groups hold only a percentage;
- a special price holds either a price or a percentage.

A percentage also cannot carry whole rupees. SAP keeps it to two decimals and
its window works the price out again from that. For example, ₹3 off 175 is
1.7143%, kept as 1.71%, and shown as 172.01.

So SAP holds the price itself. Each dealer price is a special price "Without
Price List" (`PriceListNum` 0), stored with discount 0 and AutoUpdate off. It
is rebuilt from the rules whenever a list price or a rule changes. A fixed
price never moves by itself, and SAP's AutoUpdate did not move the old
percentage prices either (seen 25 Sep 2026). Moving them is the rebuild's job,
and the check is the safety net.

### Twins: "the same item" in two companies

A Manna Treads item's **twin** is the Hi-Tech item with the **same code and
the same name**. The code alone is not enough. Of Manna Treads' 1,119 treads:
- 426 match exactly one Hi-Tech tread by name;
- one shares its code;
- I-12279 exists in both but is a different tread in each.

An item with no twin gets no Hi-Tech price, and the screen counts it. The test
treads share their codes, so they are all twins. How real items should find
their twins is not decided yet (see the end of this file).

## Files

| File | What it does |
|---|---|
| `Sync-SapPricingSnapshot.ps1` | Reads ERPNext (the rules and the margin) and SAP: Manna Treads' qualities, items, dealers and special prices, and Hi-Tech's twins. Checks SAP itself, then writes one JSON snapshot (version 3) into `SAP Pricing Control.snapshot_json`. GETs only against SAP |
| `RupeeRules.ps1` | The rules and the check, as pure functions. It is the PowerShell twin of `client/src/domain/dealerRates.ts`, and `shared/fixtures/dealer_rates.json` pins the two together |
| `Test-RupeeRules.ps1` | Offline tests, including every fixture case: `powershell -File .\Test-RupeeRules.ps1` |
| `Invoke-SapPricingPoller.ps1` | Runs the sync when the MD presses *Sync from SAP* (flag `sync_requested`, cooldown) |
| `SapSession.ps1` | The Service Layer session (Expect: 100-continue off, B1SESSION added by hand) |
| `test/Setup-TreadsTestData.ps1` | The test set-up in Manna Treads (25 Sep 2026) |
| `test/Set-TestItemGroups.ps1` | After the properties are renamed "Type - Quality": ticks each test tread with its own group, in both companies, found by name. Dry run unless `-Apply` |
| `test/Setup-RateTestData.ps1` | The first test set-up, in Hi-Tech (24 Sep 2026) |

The live copies run from `C:\Users\eldhose\sap-pricing-sync\`, next to the
gitignored `poller.config.json`. The watcher is `SAP-Watch-Pricing` in
`sap-order-sync/Register-FlagWatchTasks.ps1`, and registering it needs an
elevated `-Apply`. A sync takes about 12 seconds and logs in three times, one
after the other: Hi-Tech, then Manna Treads, then Hi-Tech again.

**The office server checks too.** On every sync, `RupeeRules.ps1` works out
what every dealer price and every Hi-Tech price should be, and counts what SAP
really holds: OK, DRIFT, MISSING, KIND. It stores those counts beside the
snapshot. The screen counts the same things with its own code and says
whether the two agree. They are two separate implementations of the same
rules, so a disagreement means one of them is wrong, and no files should be
imported until it has been looked at.

## The Managing Director's rates screen

Route `/rates`. It is for the login flagged `User.custom_is_managing_director`
(Mathews Alias). Every tab opens on summaries, one row per group or per
dealer, and a row opens onto its detail. Item lists are filterable and show 25
at a time.

- **List prices by group**: one row per named item property, including a
  group no item carries yet. Each row shows Manna Treads' prices today, its own
  "change by ₹/kg" box, the new prices, and what Hi-Tech's price for the same
  items becomes.
- **Dealer discounts**: rupees off per kg per dealer per group. There are two
  views:
  - *By dealer*: one row per dealer, opening onto their groups.
  - *By group*: one row per group, opening onto every dealer on it. There you
    can edit each dealer, add a dealer to the group, or move every dealer's
    discount on it by the same rupees.
- **Preview & confirm**: every change. Confirm saves the rules and makes at
  most three files, each downloaded with its own button (see below).
- **Check against SAP**: dealer prices against Manna Treads' list, and Hi-Tech
  prices against Manna Treads' price less the margin, as of the last sync.

## The reps' phones read the same snapshot

The ERPNext Server Script `manna_customer_rates` answers the phone's order
screen from the same `SAP Pricing Control` copy:

- `?customer=`: the dealer's special price, else Price List 01.
- `?lead=`: Price List 01 only. Lead orders are taken at the list price.

For now it answers only for item group `ZZ - Test`, and only for an item with
a Hi-Tech twin. So a dealer rule shows on the phone only once its DTW file has
been imported and **Sync** pressed. `shared/DIVERGENCES.md` has the rest.

## The procedure

1. On the screen, change a group's price or a dealer's discount. Look at the
   Preview, then Confirm. The Preview tab then shows up to three files, each
   with its own Download button. They are not downloaded automatically, because
   a browser blocks all but the first of several downloads started at once;
   before 25 Sep 2026 that is how six files arrived as one.
2. Import each file in DTW, in its numbered order:

   | File | Log in to DTW as | Operation | Business object → slot |
   |---|---|---|---|
   | `1-treads-price-list-….csv` | MANNA_TREADS_LIVE | Update Existing Data | Items → tick **Items_Prices only** |
   | `2-treads-dealer-prices-….csv` | MANNA_TREADS_LIVE | Add New Data and Update Existing Data | Special Prices for Business Partners |
   | `3-hitech-price-list-….csv` | HITECH_PRETREADS_LIVE | Update Existing Data | Items → tick **Items_Prices only** |

   DTW 10.00.190's own help says a child can be imported without its parent
   in update mode: "If you choose Update Existing Data, you can select a child
   object without selecting a parent object." On the combined operation it
   says: "Add New Data and Update Existing Data means that the same source file
   contains new records and also records for update … relevant for master data
   and setup data only". Special Prices for Business Partners is setup data.

   If a DTW ever insists on the Items header file, the screen offers it under
   each price list.
3. Press *Sync from SAP*. On the Check tab every row should be OK, and the
   office server should agree.

Always Simulate first in DTW. Don't press **Update** in SAP's Special Prices
window on a row that is still a percentage: it saves the price it has
recalculated from the rounded percentage.

## The test set-up

**Hi-Tech, 24 September 2026** (`test/Setup-RateTestData.ps1`):
- Treads I-14636…I-14640 (precured) and I-14641…I-14645 (hot), in group 122
  *ZZ - Test*.
- Each quality (Black Pearl, Platinum, Polygold, Silver, Diamond) ticked as
  property 1–5.
- `U_Quality` and `U_ProductType` set. Every name ends
  `- SYNC TEST - DO NOT USE`.

Customers ZZ-TEST-A/B exist in Hi-Tech too. Their 12 fixed special prices
there are left over from the first test and are no longer used; delete them in
SAP when convenient.

**Manna Treads, 25 September 2026** (`test/Setup-TreadsTestData.ps1`):
- The same ten treads with the same codes and names, in a new group 116
  *ZZ - Test*.
- Properties 1–5 ticked the same way, and `U_SubTypeA` set to the quality.
- Tax and unit copied from Manna Treads' own treads.
- Price List 01 set to Hi-Tech's price plus the margin.
- Customers ZZ-TEST-A and ZZ-TEST-B: group 100, Price List 01, a Kerala
  address. ERPNext never sees them: the credit sync matches customers on
  `custom_bp_code` only and creates none.

The properties are named Black Pearl … Diamond in both companies. They are
being renamed "Type - Quality", 10 groups for the 10 test treads. After the
rename, `test/Set-TestItemGroups.ps1` ticks each tread with its own group in
both companies. It finds each group by name, so the numbers can be anything,
and it unticks the rest. It is a dry run unless given `-Apply`.

**The test rules** (in ERPNext) are on properties 1–5. After the rename, a
rule stays on its property number: a rule on property 1 applies to whatever
group property 1 then names. Rules for the new groups are added on the
Dealers tab, in the *By group* view.

### Running the demo

0. Rename the item properties "Type - Quality" in both companies
   (Administration › Setup › Inventory › Item Properties). Then run
   `test\Set-TestItemGroups.ps1 -Apply` and press Sync.
1. **Dealer prices.** Preview shows 12 dealer prices to add, all whole rupees:
   A pays 195 for I-14636 and B pays 192. Confirm, import `treads-…-2a`, then
   Sync. The Check tab shows 12 OK.
2. **See them in SAP.** In Manna Treads, a Sales Quotation for ZZ-TEST-A with
   I-14636 proposes 195. Close it without adding, so test documents stay out
   of the books.
3. **A price change.** HOT - Black Pearl +5 and PCTR - Black Pearl +3. Preview shows:
   - Manna Treads I-14641 (hot) 190 → 195 and I-14636 (precured) 200 → 203;
   - the dealers' Black Pearl prices up by the same, each dealer's rupees unchanged;
   - Hi-Tech 180 → 185 and 190 → 193.

   Confirm, then download and import the three files in order, and Sync.
   Everything is OK.

## History, in SAP

- **List prices**: in each company, Item Master Data › the item › Tools ›
  Change Log.
- **Dealer prices**: in Manna Treads, Inventory › Price Lists › Special Prices ›
  Special Prices for Business Partners.

## Not decided yet

- **Twins for real items.** One suggestion: a field on each Manna Treads item
  holding its Hi-Tech code, filled once by DTW from the 426 name matches and
  checked by a person. That field would be SAP configuration.
- **The order sync's price to Hi-Tech.** The user decided on 25 Sep 2026 that
  Hi-Tech's sales order to Manna Treads (10118; 20416 until 26 Sep 2026) should carry Hi-Tech's own
  list price, not the dealer's rate. The live `send_line_unit_price` is still
  on. Turn it off once Hi-Tech's Price List 01 really follows Manna Treads',
  and not before.
- **Manna Treads' 2,728 special prices**, held by 17 dealers and all built as
  percentages. Review them before real rules replace them. Until then the
  screen lists them as prices with no discount behind them.
- **Groups on real items.** Ticking one "Type - Quality" property on each of
  Manna Treads' real items is what brings them onto the screen. Bonding gum
  and vulcanizing solution are left out of the test for now.
