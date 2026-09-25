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

A **quality** is an SAP item property (1–64), ticked on the item: 1 Black
Pearl, 2 Platinum, 3 Polygold, 4 Silver, 5 Diamond.

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
(Mathews Alias). Every tab opens on summaries, one row per quality or per
dealer, and a row opens onto its detail. Item lists are filterable and show 25
at a time.

- **Qualities & list prices**: each quality with Manna Treads' prices today, a
  "change by ₹/kg" box, the new prices, and what Hi-Tech's price for the same
  items becomes.
- **Dealer discounts**: rupees off per kg, per dealer, per quality.
- **Preview & confirm**: every change, grouped by company. Confirm saves the
  rules and downloads the DTW files.
- **Check against SAP**: dealer prices against Manna Treads' list, and Hi-Tech
  prices against Manna Treads' price less the margin, as of the last sync.

## The procedure

1. On the screen: change a quality's price, or a dealer's discount. Look at
   the Preview, then Confirm. The files download, and each file's name starts
   with its company.
2. In DTW, logged in as **MANNA_TREADS_LIVE**, import in this order:
   - `treads-…-1a` + `1b` together: *Items*, *Update existing data*, with OITM
     as Items and ITM1 as Items_Prices.
   - `treads-…-2a`: *Special Prices for Business Partners*, *Add new data*.
   - `treads-…-2b`: the same object, *Update existing data*.
3. Then, logged in as **HITECH_PRETREADS_LIVE**, import `hitech-…-3a` + `3b`
   together as one Items import.
4. Press *Sync from SAP*. On the Check tab every row should be OK, and the
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

Manna Treads' item properties are still unnamed. Until they are named, the
screen shows Hi-Tech's names for them and says so.

**The test rules** (in ERPNext):
- ZZ-TEST-A gets ₹5 off Black Pearl, ₹3 off Platinum and ₹8 off Polygold.
- ZZ-TEST-B gets ₹8 off Black Pearl, ₹4 off Silver and ₹5 off Diamond.

### Running the demo

0. Name item properties 1–5 in Manna Treads' SAP: Administration › Setup ›
   Inventory › Item Properties, as in Hi-Tech.
1. **Dealer prices.** Preview shows 12 dealer prices to add, all whole rupees:
   A pays 195 for I-14636 and B pays 192. Confirm, import `treads-…-2a`, then
   Sync. The Check tab shows 12 OK.
2. **See them in SAP.** In Manna Treads, a Sales Quotation for ZZ-TEST-A with
   I-14636 proposes 195. Close it without adding, so test documents stay out
   of the books.
3. **A price change.** Black Pearl +5. Preview shows:
   - Manna Treads 200 → 205 and 190 → 195;
   - every Black Pearl dealer price up by 5, each dealer's rupees unchanged;
   - Hi-Tech 190 → 195 and 180 → 185.

   Confirm, import the `treads-` files and then the `hitech-` pair, and Sync.
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
  Hi-Tech's sales order to Manna Treads (20416) should carry Hi-Tech's own
  list price, not the dealer's rate. The live `send_line_unit_price` is still
  on. Turn it off once Hi-Tech's Price List 01 really follows Manna Treads',
  and not before.
- **Manna Treads' 2,728 special prices**, held by 17 dealers and all built as
  percentages. Review them before real rules replace them. Until then the
  screen lists them as prices with no discount behind them.
- **Qualities on real items.** Ticking properties 1–5 on Manna Treads' real
  treads is what brings them onto the screen.
