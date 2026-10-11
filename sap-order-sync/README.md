# ERPNext ⇄ SAP Business One — Hitech order sync (SAP side)

One-way-ish bridge: **ERPNext is where orders are approved; SAP
`HITECH_PRETREADS_LIVE` (the factory) is where they are made.** This job creates
the SAP Sales Order from an approved ERPNext order and then copies SAP's own
numbers and states back onto the ERPNext order every pass. The ERPNext apps
never push to SAP and never compute floor state — they display what this job
writes.

**The commercial boundary.** Hi-Tech Pretreads manufactures and bills Manna
Treads. It has no visibility of the end customer and must not gain any. The SAP
Sales Order created here carries **only**: the fixed inter-company `CardCode`
`10118` ("Manna Treads Private Limited- SHOP", Ernakulam; until 26 Sep 2026 it was `20416`, the Gujarat company, by mistake), dates, item codes, quantities, and
the opaque ERPNext order name in `NumAtCard`. No end-customer name, code,
address, territory, contact, comment or line remark — anywhere. End-customer
traceability lives in ERPNext, keyed on the order name. **One ERPNext order →
one Hi-Tech Sales Order; never aggregated.**

**Stage two (26 Sep 2026) is PASS C**: once Hi-Tech has finished an order and
the accountant has approved it, this job creates the matching Sales Order in
`MANNA_TREADS_LIVE`, to the **end customer**, for what Hi-Tech actually
delivered. That is Manna Treads billing its own customer, in its own company —
the boundary above is untouched: nothing about the customer goes to Hi-Tech.
`custom_bp_code` is read by PASS C only. See
[Stage two — Manna Treads sales orders](#stage-two--manna-treads-sales-orders).

Contract: **`../shared/SAP_ORDER_SYNC.md`**, in this repository (received
2026-09-10, added to several times since). Read it before changing anything
here — it is the half of the rules the two apps display.

## Setting this up on another machine

This directory joined the repository on 18 September 2026. It had lived only on
the SAP server until then, which meant one bad edit and there was no way back.

Nothing here runs until you supply the two configs, and **neither is in git**:

```bash
cp config.example.json        config.json          # SAP + ERPNext credentials
cp poller.config.example.json poller.config.json   # only if running the poller
```

Fill them in from the copies on the SAP server
(`C:\Users\eldhose\sap-order-sync\`). **Copy those files by hand** — do not
route them through git, chat or email. `.gitignore` already refuses both, plus
`logs/` and the `sl-registry-fix/conf-backup-*` directories, which carry
DPAPI-encrypted Service Layer credentials.

### The SAP half will not run off the factory network

The Service Layer is at `https://192.168.100.200:50000`, a private address.
From anywhere else every SAP call fails on connect, so on a machine outside
that LAN (a laptop at home, without VPN) you can run:

| | Off the LAN |
|---|---|
| `Test-SalesPerson.ps1`, `Test-LineReconcile.ps1`, `Test-InvoiceLinking.ps1` | **yes** — they build their cases in memory and touch nothing |
| `Test-OrderLinePricing.ps1` | yes — ERPNext only, and read-only |
| `Sync-SapOrders.ps1`, the seeding scripts, the poller | **no** |

The three offline suites are the ones to develop against. They cover the line
reconcile, the rep mapping, and which sales order an invoice line belongs to,
which is most of the logic worth changing.

`Test-MannaTreadsReorder.ps1` (stage two, 26 Sep 2026) is offline too: every
case of `shared/fixtures/manna_treads_reorder.json`, the delivered and invoiced
kilos PASS B captures, and the body PASS C posts to Manna Treads.

### And it is pointed at production

There is no sandbox. `config.json` names `HITECH_PRETREADS_LIVE` and the live
ERPNext site, so `Sync-SapOrders.ps1` creates real SAP orders and writes to
real ERPNext ones. **Use `-DryRun` first, every time** — it prints the exact
POST body and the ERPNext writes it would make, and changes nothing.

## Files

| File | Purpose |
| --- | --- |
| `Sync-SapOrders.ps1` | The whole job. Dry-run first, then `-Limit 2`, then unrestricted. |
| `Invoke-SapOrderSyncPoller.ps1` | Reads `SAP Order Sync Control`, claims a run, executes the job as a child process with a hard timeout, reports status back. Same shape as `sap-credit-sync\Invoke-SapSyncPoller.ps1`. Started by the watcher, not by a timer. |
| `Invoke-FlagWatch.ps1` | The watcher. Every minute Task Scheduler starts one per sync; it reads that sync's request flag every 5 s (15 until 25 Sep 2026) and starts its poller only when the flag is up. Shared by the order, stock, credit and pricing syncs. |
| `Register-FlagWatchTasks.ps1` | **Run elevated, by hand.** Removes every timed order/stock/credit/products task and registers the four watchers (orders, stock, credit, pricing). Previews unless given `-Apply`. |
| `Test-FlagWatch.ps1` | Offline. When the watcher starts a poller and when it does not. 9 assertions. |
| `Register-OrderSyncTasks.ps1` | **Superseded 24 Sep 2026** by `Register-FlagWatchTasks.ps1`; refuses to run, because it would restore the timed sync. |
| `config.example.json` / `config.json` | Job config. `config.json` holds live creds and is git-ignored. |
| `poller.config.example.json` / `poller.config.json` | Poller config. Git-ignored. |
| `erpnext-setup.md` | Spec for the `SAP Order Sync Control` single + trigger button (not created yet). |
| `Test-InvoiceLinking.ps1` | Offline. Which sales order an invoice line belongs to (directly, or through its delivery), which invoice completes an order, and that an invoiced line is never reconciled away as dropped. 19 assertions. |
| `Test-SalesPerson.ps1` | Offline. The rep -> SAP sales employee mapping, 27 assertions. Runs with SAP down. |
| `Test-LineReconcile.ps1` | Offline. What PASS B's line reconcile corrects, and what it refuses to. |
| `Test-MannaTreadsReorder.ps1` | Offline. Stage two: every case of `shared/fixtures/manna_treads_reorder.json` through `Get-MtReorderPlan`, and GST in code equal to the fixture's; the rounding against the dashboard's `roundTo`; the Hi-Tech delivered/invoiced kilos (cancelled deliveries and reversals ignored, deliveries summed per line, an invoice drawn from a delivery never counted twice); the settings' defaults (Series 189, the ten-item allowlist, the approvers); the Manna Treads order body (DiscountPercent 0 on header and lines); PASS C's refusals (allowlist, item name, item on two lines, customer and its name, approver, another order on the same Hi-Tech SO, part invoiced direct on a delivered order); Hi-Tech's own order against the recorded kilos (an item on two Hi-Tech lines, a Hi-Tech line with no ERPNext row, stale kilos, not closed, older than the scans, whose SO it is by `NumAtCard`); the verdict's order; PASS B's hold-back on a failed kilo write; the lifecycle (only error-free requested orders taken, adoption before refusal, SAP refusal vs transient failure, stale kilos transient only when PASS B was due to refresh them); the PASS C lock. 289 assertions. |
| `Test-OrderLinePricing.ps1` | Live-read. Proves a SAP line totals what the manager approved. Writes nothing. |
| `.gitignore` | keeps configs + logs out of git. |

## When it runs — only when somebody asks (from 24 Sep 2026)

Nothing syncs with SAP on a timer any more — not orders, not stock, not credit
limits. A sync runs when:

* somebody presses **Sync** — the button on every screen of both apps; or
* an order is **approved** (or created already approved from a lead order) —
  both apps raise the order flag themselves.

The press raises a flag on the sync's ERPNext Single; `Invoke-FlagWatch.ps1`
reads it every 5 seconds and starts that sync's poller. Windows Task Scheduler
cannot repeat faster than once a minute, so each watcher is a one-minute task
that looks eleven times inside its minute. The look is one small HTTPS read and
never logs into SAP; SAP is only touched when the flag is up.

| Sync | Control Single | Flag | Request / status Server Scripts | Who may ask |
|---|---|---|---|---|
| Orders | `SAP Order Sync Control` | `sync_requested` | `manna_sap_order_request_sync` / `manna_sap_order_get_status` | anyone |
| Stock | `Hitech Stock Fetch Control` | `fetch_requested` | `manna_stock_request_sync` / `manna_stock_get_status` | Manna Treads |
| Credit | `SAP Sync Control` | `sync_requested` | `manna_sap_request_sync` / `manna_sap_get_status` | Manna Treads |

**Every request script always raises its flag**, even inside the cooldown or
during a run. The poller defers a flagged run until the cooldown has passed,
so a press is delayed, never dropped — which matters now that an approval
raises the flag: a refusal would strand the order. The flag is a yes/no, so
any number of presses between runs is one run.

The products/weights sync (`Sync-HitechProductsToTreads.ps1`, every 30 min)
was not part of the change and keeps its schedule.

## What it does, per pass

**PASS A — create SAP orders.** In scope:
```
custom_po_status = "PO Approved - Ready for SAP"
custom_sap_sales_order in ["", null]
docstatus < 2
```
`docstatus < 2`, not `= 1`: neither app submits a Sales Order — approval is a
field write and the order stays `docstatus 0`. The gate is `custom_po_status`;
`docstatus` only drops a Frappe cancel. See `shared/SAP_ORDER_SYNC.md` and
`../shared/DIVERGENCES.md`, both in this repository.
Per order, one at a time:
1. Re-read the order; abort if `custom_sap_sales_order` is no longer empty (**never create the same SAP order twice**).
2. If `stamp_erpnext_name_in` ≠ `none`, search SAP for an `Orders` row whose `NumAtCard` (or `U_FreeText`) already equals this ERPNext name → **adopt** its `DocNum` instead of creating a duplicate (covers a crash between POST and write-back last run).
3. Build the SAP Sales Order:
   * `CardCode` ← `order_sync.fixed_card_code` (`10118`) — always, no lookup.
   * `DocDueDate` ← `delivery_date` (fallback `transaction_date`).
   * line `ItemCode` ← `items[].item_code` (already the SAP ItemCode — no mapping table).
   * line `Quantity` ← `items[].custom_total_weight` (**KILOS, as approved — never recomputed from rolls × weight**). Missing/zero on any line ⇒ **fail the whole order**, name the line, leave it for a human.
   * line `UnitPrice` ← **`items[].amount / items[].custom_total_weight`** — the approved net rate per kilo — with `DiscountPercent` forced to **0**, whenever `send_line_unit_price` is true (and it now **is**, see "Line price" below). A line with no `amount` **fails the whole order**, rather than letting SAP invent a price from its own list.
   * `NumAtCard` ← the ERPNext order name (opaque idempotency stamp — the only reference on the document).
   * **Nothing else.** No `Comments`, address, territory or contact.
   `POST /Orders`.
4. **Immediately** write back: `custom_sap_sales_order` = DocNum, `custom_sap_sales_order_status` = SAP status verbatim, `custom_sap_synced_at` = now, `custom_sap_sync_error` = "" (cleared). If this write fails after the SAP order was created, the run logs the DocNum loudly and exits non-zero; the next run adopts via the stamp.

**PASS B — pull status, lines and invoices.** In scope:
```
custom_sap_sales_order is set
custom_sap_invoice in ["", null]
docstatus < 2
```
Using **one** scan of recent `DeliveryNotes` and **one** scan of recent
`Invoices` (this SL build rejects lambda `$filter`, so joins are done in
memory):
* `custom_sap_sales_order_status` ← refreshed `DocumentStatus` verbatim (`bost_Cancelled` when `Cancelled = tYES`).
* **lines** ← reconciled to SAP: a line the factory reduced or dropped there is reduced or removed here (`Get-ErpLineCorrections`).
* `custom_sap_invoice` / `custom_sap_invoice_date` **on each line** ← the A/R invoice that carried THAT line. An invoice line is based either on the sales order (`BaseType 17`, `BaseEntry` = the order's `DocEntry`) or on a delivery (`BaseType 15`), which is followed back to that delivery line's own sales-order base. A pooled invoice can carry several orders, so this is resolved per line (`Resolve-InvoiceLineSoEntry`). Cancelled invoices are ignored. Written only when the value changes.
* `custom_sap_invoice` / `custom_sap_invoice_date` **on the order** ← written only once **every** line is invoiced, naming the invoice that completed it (`Select-CompletingInvoice`). This is what takes an order out of PASS B, which is why a partial invoice must not set it.
* `custom_sap_synced_at` ← now, **every pass, changed or not**.
* `custom_sap_sync_error` ← "" on any clean pass.
* **Stage two, per line** (26 Sep 2026) — what Hi-Tech actually sent, which PASS C bills from:
  * `custom_hitech_delivered_kg` ← the `Quantity` (kg) of every live delivery line drawn from this sales-order line (`BaseType 17`, `BaseEntry`/`BaseLine`).
  * `custom_hitech_invoiced_kg` ← the kg on live invoice lines drawn **straight** from this sales-order line (`BaseType 17`). An invoice line based on a delivery (`BaseType 15`) is not added — those kilos are already the delivery's.
  * `custom_hitech_delivery_refs` ← `DN 4 (18-09-2026), DN 7 (20-09-2026)`, for the accountant.

  The SAP line is turned into its item through the order's own `DocumentLines` and matched to the ERPNext row by item code, as everywhere else here; an item on two lines, on either side, is skipped with a WARN — and so is a Hi-Tech line whose item has no ERPNext row, silently. PASS C does not trust those gaps: it re-checks Hi-Tech's own order before billing and refuses the order (see *Stage two*). Written only when a figure moves by more than 0.0005 kg or the refs change (`Get-HitechKgUpdates`). An order whose own `DocDate` is older than the scan window keeps what was last recorded rather than being rewritten from a scan that may have lost its early deliveries (and PASS C refuses to bill it).

  **Never another order's kilos** (26 Sep 2026). The Hi-Tech SO is found by `DocNum` — by `DocNum` alone when only one order has it — and `custom_sap_sales_order` is copied by a Desk *Duplicate* (the kilo fields are `no_copy`). So when the Hi-Tech SO's `NumAtCard` names **another** ERPNext order, no kilos are written to this one (`Get-HitechOwnerNote`, a WARN). An empty `NumAtCard` is no evidence either way. Status, lines and invoices are handled exactly as before.

  **Kilos first, then the header** (26 Sep 2026). The kilo writes go in *before* the order header, then the line invoices. If any kilo write fails, the header holds back what would move the order on as though they had gone in (`Limit-PassBHeaderOnKgFailure`): `custom_sap_sales_order_status` — so an order Hi-Tech has just closed does not read *ready* on stale kilos — and, on the pass that would retire it, the order-level `custom_sap_invoice` / `_date`, so it stays in PASS B. The next run writes them all again. (Until 26 Sep only the retiring pass wrote kilos first; every other order wrote header, line invoices, then kilos, and a failed kilo write only WARNed.)

**PASS B (follow) — invoiced in full, still open at Hi-Tech** (26 Sep 2026). In scope:
```
custom_company = "Manna Treads"
custom_sap_sales_order is set
custom_sap_invoice is set                 # PASS B has retired it
custom_mt_sales_order in ["", null]
docstatus < 2
custom_sap_sales_order_status not in ["bost_Close", "bost_Cancelled"]
```
PASS B retires an order once every line is invoiced, even while Hi-Tech's SO is still `bost_Open` — a short delivery invoiced before Hi-Tech closes the order. Nothing would then refresh its status or kilos, so it would never read `bost_Close`, never become *ready*, and never be billed. This set refreshes **only** `custom_sap_sales_order_status`, the three `custom_hitech_*` kilo fields and `custom_sap_synced_at` — no line reconcile, no invoice linking. Kilos first; if one fails, the status is held back a run, so an order does not leave the set (and reach the accountant) on stale kilos. It uses PASS B's own scans; its list read has its own `try`, so a failure there fails the run but not PASS A/B.

**Dispatch is the invoice, not the delivery** (decided 24 Sep 2026). The floor
posts a delivery first, so a delivered-but-uninvoiced order reads *Pushed to
SAP*. The delivery scan stays for two jobs only: the line reconcile needs it to
tell a shipped closed line from a dropped one, and an invoice raised from a
delivery is followed back through it. Invoices feed the reconcile too — a line
invoiced straight from the order has no delivery, and would otherwise read as
dropped and be deleted.

**A cancelled delivery is not a delivery** (fixed 26 Sep 2026). Cancelling a
delivery in SAP leaves the original in place (`Cancelled = tYES`,
`CancelStatus = csYes`) and posts a reversal (`CancelStatus = csCancellation`,
lines `BaseType 15`). The scan did not ask, so a cancelled delivery counted as
shipped in the line reconcile — a line the factory had then dropped was kept.
It now selects `Cancelled,CancelStatus` and counts only `csNo`
(`Test-SapDocumentCounts`), for the reconcile and the stage-two kilos alike.

**No production orders** (decided 24 Sep 2026). Under MRP one production order
pools many sales orders and SAP does not record which order it is for, so
production-order linking is out of the initial release. See
`../shared/fixtures/sap_order_state.json`.

**Never written here:** `custom_production_status` (the app derives it), and
the old `custom_sap_production_*` / `custom_sap_delivery_*` fields, which stay
in ERPNext with whatever they last held and are read by neither app.

**Known limit:** a line whose invoice is cancelled *after* it was recorded, or
has aged out of `invoice_scan_days`, cannot be told apart this run — it is left
as it is with a WARN in the log, rather than guessed at.

## Stage two — Manna Treads sales orders

Decided by the user on 26 September 2026. Hi-Tech makes and delivers every app
order and bills Manna Treads (CardCode `10118`). Manna Treads then has to bill
the **end customer** — for what Hi-Tech actually delivered, which is not always
what was ordered. The accountant (Jineesh, dashboard role `accountant`,
`User.custom_is_accountant`) sees each order Hi-Tech has finished, grouped by
customer, and approves it. The dashboard calls the Server Script
`manna_mt_so_request`, which re-checks the order, sets
`custom_mt_so_requested = 1` (with `_by` / `_at`), clears
`custom_mt_sync_error` and raises the order-sync flag. **PASS C** then creates
the order in `MANNA_TREADS_LIVE` through the Service Layer — the second write
path, chosen explicitly, "just as how the order is pushed to Hi-Tech on
manager approval".

**The rule** — what is billed, at what price, and which state an order is in —
is `shared/fixtures/manna_treads_reorder.json`, read by the dashboard's tests
and by `Test-MannaTreadsReorder.ps1`. `Get-MtReorderPlan` is this side's
implementation. In short: bill the **delivered** kilos line by line, or the
**invoiced** kilos only when nothing was delivered at all (never both); leave
out a line with nothing; price at the approved `amount / custom_total_weight`,
GST-inclusive, so the SAP line carries it **net of GST** (`220 → 186.440678`)
with the tax code, and SAP adds the tax back.

**In scope** (the same gate as PASS A, never a wider one) — the rule's
*queued* orders only:
```
custom_mt_so_requested = 1
custom_mt_sales_order in ["", null]
custom_mt_sync_error empty                # checked in code (Test-MtQueued)
custom_sap_sales_order is set
custom_po_status = "PO Approved - Ready for SAP"
docstatus < 2
```
An order with an error recorded is *failed*: it waits for the accountant's
**Try again**, which calls `manna_mt_so_request`, which clears the error and
raises the flag. The sync never retries a failed order by itself, so one bad
order cannot fail every order-sync run and show *Failed* to everyone. The
summary counts them as `mt failed waiting`.

**One run at a time.** PASS C runs inside a named system mutex
(`Global\MannaSapOrderSyncPassC`, `Enter-MtPassLock`): two runs at once could
both miss on `NumAtCard` and both post. If another run holds it, PASS C is
skipped this run with a WARN — not a failure — and its orders stay queued.
`-DryRun` posts nothing and does not take it.

Per order, one attempt per run, `-Limit` honoured:
1. **Before the Manna Treads login.** Re-read the order and its
   `Customer.custom_bp_code` (the `MANNA_TREADS_LIVE` CardCode) and
   `customer_name`, and plan it. Work out — but do **not** yet act on — what
   refuses it (`Get-MtPreSapRefusal`), the first that applies, in this order:
   * **who asked** — `custom_mt_so_requested_by` must be one of
     `manna_treads.approvers` (default: `jineesh@mannarubber.com`, the one
     user with `custom_is_accountant`). The flag and `_by` are permlevel 0,
     so anything that sets them without `manna_mt_so_request` is refused:
     *"Not approved by the accountant: ..."*. This sync's ERPNext user
     (role *SAP Sync Bot*) cannot read `User` or `Has Role`, which is why the
     list is config;
   * **another live ERPNext order on the same Hi-Tech SO** — one ERPNext list
     read by `custom_sap_sales_order`, this order and cancelled ones
     excluded: *"Hi-Tech SO 425 is also on SAL-ORD-... - one Hi-Tech order can
     be billed once; raise it by hand."* A Desk *Duplicate* copies
     `custom_sap_sales_order`, and PASS B finds the Hi-Tech order by `DocNum`,
     so without this the copy would bill the goods a second time. Both orders
     are refused until one is gone;
   * **an item on two lines** (*"I-xxxxx is on two lines of this order;
     Hi-Tech's kilos cannot be split between them - raise it in SAP by
     hand."* — PASS B writes no kilos for such an item, so posting would bill
     the order short);
   * **Hi-Tech's own order, as the Hi-Tech session read it this run**, must
     back the recorded kilos (`Resolve-HitechOrderFor`, `Get-MtHitechCheck`):
     found by `DocNum` and, if several share it, by `NumAtCard`; its
     `NumAtCard` not naming another order; `bost_Close` now; dated inside
     both scan windows (older, and its kilos may be incomplete); **no item it
     sent on two of its lines, and none on a line this order lacks** (*"Hi-Tech
     delivered I-14641 (25 kg) on a line this order cannot be matched to -
     raise it in SAP by hand."*); no row carrying kilos for an item not on its
     order; and the recorded kilos equal to what it shows now. That last one
     alone is **stale**: if PASS B was due to refresh the order this run (it
     is in the open or followed set) it is a *transient* failure — nothing
     written, retried next run (`Get-MtStaleVerdict`); otherwise nothing will
     refresh it and it is a refusal;
   * the rule's state (Hi-Tech has not closed it, cancelled it, or delivered
     nothing), another unit's order, no customer code, a line with no
     approved price;
   * **delivered, and part invoiced straight from the order** (*"Hi-Tech
     invoiced I-14640 (36 kg) straight from its order without a delivery, and
     delivered the rest - ..."*). `custom_hitech_invoiced_kg` only ever holds
     goods that left without a delivery note, and the fixture's
     `delivery_wins` would leave them unbilled — refused until that rule is
     decided (`shared/DIVERGENCES.md`);
   * **an item not on `item_allowlist`** (*"I-xxxxx is not set up for Manna
     Treads sales orders yet."*). The allowlist defaults to exactly the ten
     SYNC TEST items `I-14636`..`I-14645`, the only codes created as the same
     product in both companies — "only the test items for now".

   Because of the Hi-Tech check, the **Hi-Tech session logs in whenever PASS C
   has a queued order**, even when PASS A and B have nothing, and its order
   read includes PASS C's `DocNum`s. It is logged out before the Manna Treads
   login, so a run still holds one of the five seats at a time.
2. **Only if a queued order is left**, log in to `MANNA_TREADS_LIVE` — its own
   session, after the Hi-Tech one has logged out, so a run never holds two of
   the five seats. Refused unless the database is exactly `MANNA_TREADS_LIVE`
   and not Hi-Tech's (`Assert-MtCompanyDb`). Logged out in a `finally`.
3. **Adopt before anything is refused** (`Get-MtOrderDecision`).
   `Orders?$filter=NumAtCard eq '<ERPNext name>'`: one live order is adopted —
   DocNum and DocEntry written back, the error cleared, nothing created —
   *whatever step 1 said*, because a previous run posted it and failed to write
   it back, and Manna Treads is already billing the customer for it. Two live
   ones are refused as a duplicate, naming both. None: step 1's refusal, if
   any, is written now.
4. **Validate** against Manna Treads SAP, refusing the whole order with one
   message:
   * the customer exists, `cCustomer`, **its `CardName` equals the ERPNext
     `customer_name`** (spacing and case aside — `custom_bp_code` is typed by
     hand, and a mistyped code that is another real customer would bill
     them), `Valid tYES`, `Frozen tNO`, and its `BillToState` is in
     `allowed_bill_to_states` (`KL`). `CG+SG@18` is the intra-state split; a
     customer billed outside Kerala owes IGST, and the sync will not guess a
     tax code. All in the one `BusinessPartners` read;
   * every item exists, `Valid tYES`, `Frozen tNO`, `SalesItem tYES`, **and its
     Manna Treads `ItemName` equals the ERPNext line's `item_name`** (trimmed,
     spacing and case ignored) — at least one Hi-Tech code is a different tread
     in Manna Treads SAP, so "the code exists there" is not enough. Read in the
     same one filtered `Items` read. A mismatch names both names.
5. **Create** — `POST /Orders`:

   | field | value |
   |---|---|
   | `CardCode` | `Customer.custom_bp_code` |
   | `DocDate`, `DocDueDate` | today, server clock — never back-dated (the SAP login allows 2 days) |
   | `NumAtCard` | the ERPNext order name |
   | `Comments` | `From ERPNext <name> - Hi-Tech SO <DocNum> - DN 4 (18-09-2026), ...`, cut to 254 |
   | `Series` | `series` — **189**, Manna Treads' Kerala series (every recent order carries it; read 26 Sep 2026). `null` leaves it to SAP |
   | `BPL_IDAssignedToInvoice` | `bpl_id` (1, Kerala) |
   | `DiscountPercent` | **0** |
   | line `ItemCode` / `Quantity` | the item / the billable **kg** |
   | line `UnitPrice` | the approved rate **net of GST**, 6 dp |
   | line `DiscountPercent` | **0**, on every line |
   | line `TaxCode` / `WarehouseCode` / `LocationCode` | `CG+SG@18` / `01` / `2` |
   | `SalesPersonCode` | omitted — SAP takes the customer's own default, as every real order does |

   **DiscountPercent 0, header and every line**, as PASS A sends it on its
   lines. Left off, SAP's price determination fills a line discount from the
   customer's special prices or discount groups (and a document discount from
   the customer master) and applies it to the `UnitPrice` posted — the invoice
   would come out under the approved rate, silently.

   `-DryRun` logs this body and writes nothing.
6. **Write back** at once: `custom_mt_sales_order` = DocNum,
   `custom_mt_sales_order_entry` = DocEntry (DocNum is not unique in SAP),
   `custom_mt_synced_at`, `custom_mt_sync_error` cleared. If the order was
   created but the write-back fails, it stays queued and the next run adopts it
   by `NumAtCard` (step 3).

**A refusal is the order's; a transient failure is the run's** (26 Sep 2026):

| | what happens | run |
|---|---|---|
| **Refusal** — anything in steps 1, 3 (two live orders) and 4, and SAP refusing the POST itself (HTTP 4xx with an SAP error body, e.g. a tax or back-date rule) | the reason, in plain words, ≤ 250 characters, goes into `custom_mt_sync_error`, with `custom_mt_synced_at`; `custom_mt_so_requested` **stays 1**, so the dashboard shows it under *Failed* with the reason and **Try again**. Counted as `mt refused` | **not** a failure |
| **Transient** — a network error or timeout, a login failure, HTTP 5xx or the empty-body 500, 401/403/407/408/429, any SAP read failing, an ERPNext read or write failing, **stale kilos on an order PASS B was due to refresh this run** | nothing is written on the order; it stays queued and is taken again next run | failure — exit 1 |

(`Get-MtPostFailure` classifies a failed POST; `Write-MtRefusal` writes a
refusal, and a refusal it cannot write is itself a transient failure.)

A failure anywhere in PASS C stays in PASS C: its list is read inside its own
`try`, so a missing field or a bad `manna_treads` block skips PASS C with an
ERROR while PASS A and B run. The summary line gains
`hitech kg lines | invoiced but open at Hi-Tech, followed | mt queued | mt created | mt adopted | mt refused | mt failed waiting`.

**Rounding is the dashboard's, to the paisa** (`Get-RoundedHalfUp`): the value
is taken to 15 significant figures and the *decimal* rounded half away from
zero — `roundTo` in `client/src/domain/mannaTreadsReorder.ts`, bit for bit
(checked on 140,120 values, 26 Sep 2026). Rounding the raw double billed
`6029.70 / 60 kg` at 100.49 instead of 100.50. **GST is not configurable**:
18%, and the approved rate always includes it (`Get-MtGstPercent`), as the
fixture and the dashboard have it; the two keys that briefly existed are
refused if they disagree.

In `-DryRun`, PASS C plans from ERPNext as it stood before the run — PASS B's
fresh kilos were not written, so an order PASS B would have updated reads
*stale* against Hi-Tech; the log says so (INFO, not a failure) and shows no
body for it.

**What the sync cannot stop on its own.** `custom_mt_so_requested` / `_by` /
`_at` and the three `custom_hitech_*` kilo fields are permlevel 0, so any
Sales Order writer can set them over REST. Forged kilos are caught (the
Hi-Tech check compares them with Hi-Tech's own documents); a forged request
naming an approver in `_by` is not. The real control is ERPNext's: move the
three request fields to permlevel 1, writable by System Manager only, readable
by the roles that use the Manna Treads screen and by *SAP Sync Bot* —
`manna_mt_so_request` writes them with `frappe.db.set_value`, which does not
check field permissions.

## Config keys (`config.json`)

```jsonc
{
  "erpnext": { "site", "api_key", "api_secret" },        // token key:secret — the sapsync@mannarubber.com account
  "sap": {
    "url", "username", "password",
    "verify_ssl": false,                                  // self-signed cert on :50000 → host-scoped bypass
    "page_size": 200,
    "company": { "name": "Hi-Tech Rubber Industries", "company_db": "HITECH_PRETREADS_LIVE" },
    "series": null,                                       // optional B1 Series number for the SO
    "sales_person_code": null                             // FALLBACK only — see "Who the order is tagged to"
  },
  "order_sync": {
    "po_status_gate": "PO Approved - Ready for SAP",      // the ONLY in-scope custom_po_status
    "fixed_card_code": "10118",                           // REQUIRED. Every SO uses this CardCode — no lookup
    "send_line_unit_price":    true,                       // true = send the approved net rate as UnitPrice
    "line_warehouse":          "07",                     // the warehouse each order line names; "" = SAP default (see Warehouse below)
    "status_source": "document_status",                   // (reserved) how custom_sap_sales_order_status is filled
    "stamp_erpnext_name_in": "NumAtCard",                 // NumAtCard | U_FreeText | none
    "delivery_scan_days": 120,                            // DeliveryNotes with DocDate within N days (reconcile only)
    "invoice_scan_days": 120                              // Invoices with DocDate within N days; defaults to delivery_scan_days
  },
  // stage_source, production_scan_statuses, production_status_labels and
  // delivery_ship_date_from are no longer read (24 Sep 2026); a config that
  // still carries them is harmless.
  "manna_treads": {                                       // OPTIONAL - PASS C. Every key defaults IN CODE to what is shown
    "enabled": true,
    "company_db": "MANNA_TREADS_LIVE",                    // anything else is refused
    "series": 189,                                        // Manna Treads' Kerala series; null = leave it to SAP
    "warehouse": "01", "tax_code": "CG+SG@18",
    "location_code": 2, "bpl_id": 1,                      // null = leave off the order
    "allowed_bill_to_states": ["KL"],                     // outside these needs IGST -> refused
    "item_allowlist": ["I-14636", ..., "I-14645"],        // the ONLY items PASS C may bill; [] = none. Default: the ten SYNC TEST items
    "approvers": ["jineesh@mannarubber.com"],             // whose custom_mt_so_requested_by PASS C acts on; [] = nobody. Add a System Manager who approves
    // no GST keys: 18%, GST-inclusive, fixed in code. gst_percent / rate_includes_gst
    // are refused if they disagree (they existed for one day, 26 Sep 2026)
    "username": "...", "password": "..."                  // optional, both or neither; default = the sap login
  },
  "log_dir": "./logs",
  "log_keep_days": 30
}
```

## Who the order is tagged to

The SAP order carries the rep who raised it, as **SalesPersonCode**. PASS A
reads `custom_sales_person` off the ERPNext Sales Order and looks it up in
SAP's active sales employees **by name**.

The name is the whole join. There is no id shared between the two systems, so
every SAP sales employee here was created with exactly the ERPNext
`Sales Person` spelling:

| ERPNext `Sales Person` | SAP `SalesEmployeeCode` |
|---|---|
| Pareeth Kb | 10 |
| Jaimon D | 11 |
| Sirajudheen Kasim | 12 |
| Amjad Pr | 13 |
| Prashanth | 14 |
| Test Rep | 15 |

Matching is case-insensitive and ignores surrounding blanks; nothing else is
forgiven. **Add a rep on one side and you must add them on the other**, in
Administration ▸ Setup ▸ General ▸ Sales Employees.

A rep SAP does not know is a **warning, not a failure**: the order is still
created, with `sap.sales_person_code` if one is configured and otherwise with
no sales employee at all. An order stuck outside SAP because nobody added an
employee record would stop the factory; an order inside it with the employee
blank is a field to fill in. The log names the rep and the run summary counts
it as `rep unmatched: N`, so it does not stay quiet for long either.

Inactive employees are not matched — SAP would refuse the order — and neither
is SAP's own `-No Sales Employee-` placeholder (code -1).

This is the only thing in the payload that names a person, and it names one of
**ours**. The end customer is still invisible to the factory: the CardCode is
always the fixed inter-company code, and there is no address, contact,
territory or comment on the order.

## First run — in order

```powershell
cd C:\Users\eldhose\sap-order-sync

# 1. DRY RUN. Reads ERPNext + SAP, writes NOTHING. Prints the POST body and the
#    ERPNext write it WOULD make, per order. Inspect every payload.
.\Sync-SapOrders.ps1 -ConfigPath .\config.json -DryRun

# 2. Two real orders only. Check them in ERPNext AND in the SAP client.
.\Sync-SapOrders.ps1 -ConfigPath .\config.json -Limit 2

# 3. The rest.
.\Sync-SapOrders.ps1 -ConfigPath .\config.json
```

Re-running is safe: PASS A skips orders that already carry a `custom_sap_sales_order`
and adopts a stray SAP order via `NumAtCard`; PASS B is idempotent and only moves
`custom_sap_synced_at` + whatever genuinely changed.

Exit code is non-zero on any per-order failure or a fatal — Task Scheduler shows
**Last Run Result ≠ 0x0**.

## Reconciled against `shared/SAP_ORDER_SYNC.md` (received 2026-09-10)

Settled:

* **Nine fields** — the eight data fields match; the ninth is `custom_sap_section` (a Desk break, no data). All eight are `read_only=1` in Desk but API-writable. `custom_production_status` and `custom_po_status` are pre-existing and NOT written here.
* **Gate** — `custom_po_status = "PO Approved - Ready for SAP"` (only in-scope value) **and** `docstatus < 2`. The contract first said `docstatus = 1`, but neither app submits a Sales Order (approval is a field write; the order stays `docstatus 0`), so `= 1` matched nothing. Reconciled 10 Sep 2026 — see `shared/DIVERGENCES.md`.
* **Status is entirely app-side** (`shared/fixtures/sap_order_state.json`) and writes nothing to `custom_production_status`. *Superseded 24 Sep 2026:* the stage-to-status mapping and its `ProductionOrderStatus` fallback labels are gone. The apps now show *Pushed to SAP* once SAP has the order and *Dispatched* once it is invoiced — see PASS B above.
* **`custom_sap_sales_order_status`** — `DocumentStatus` verbatim (`bost_Open`/`bost_Close`, `bost_Cancelled` on cancel). Display-only apart from `bost_Cancelled`. `bost_Close` does **not** imply Dispatched — SAP closes an order when it is fully delivered, before it is invoiced.
* **Ship date** — `DocDueDate` (the promised date a rep repeats to a customer), set in `config.json`.
* **Datetime** — `yyyy-MM-dd HH:mm:ss`, naive, site TZ (Asia/Kolkata). **The scheduled-task host must run in IST** or the stamp is wrong (same caveat as the credit sync).
* **`custom_rolls` / `custom_loose_belts`** — dropped, as instructed.
* **Automations** — the three Sales Order DocType-event server scripts are disabled; nothing fires on these writes.
* **Delivery⇄SO / Invoice⇄SO** — `DeliveryNotes.DocumentLines[].BaseEntry` (BaseType 17) carries the SO `DocEntry`; an invoice line carries it directly (BaseType 17) or through its delivery (BaseType 15). *PO⇄SO was dropped 24 Sep 2026* — it assumed the floor raises production orders from the sales order, and a live check found MRP-created orders carry no sales-order link at all.

### Customer & items — settled by the final scope

* **Customer** — always `CardCode 10118` ("Manna Treads Private Limited- SHOP"; `20416` is Manna Treads Private Limited(GJ), Surat, a different company, and was used by mistake until 26 Sep 2026). No `custom_bp_code`, no lookup, no mapping table. (`custom_bp_code` holds `MANNA_TREADS_LIVE` codes, read only by PASS C for the stage-two order; a `C-`-strip transform against those was checked and produced only false positives — `10016`/`10047` are different customers in the two books. Never derive a CardCode.)
* **Items** — `item_code` **is** the `HITECH_PRETREADS_LIVE` `ItemCode` by construction (the 10 Sep 2026 FG import took them from that DB). No transform. Five pre-existing non-SAP items (`BONDING GUM`, `COMPOUNDED RUBBER`, `220 MXM 128 (MANNA)`, `RUBBER VULCANISING SOLUTION 10LTR`, `DEMO-RETREAD-1000x20`) won't resolve; an order containing one fails whole (SAP rejects the `POST`, the error names the line, `custom_sap_sync_error` records it). Matches the contract.

### Minor decisions (left as-is; revisit if needed)

* **Line price** — `send_line_unit_price` is **true**, changed 17 September 2026 on the instruction that "the sales order should have the pricing same as what the app gave it". The SAP order carries the **approved net rate per kilo**, computed as `amount / custom_total_weight` with `DiscountPercent` forced to 0. It is deliberately NOT `custom_rate_per_kg`: that field is the *pre*-discount quote, and on SAL-ORD-2026-00135 (25/kg less 10%) it would have overcharged the factory document by the discount. Discounts were then removed from both apps entirely — the rep types the rate after discount — so on a current order the two agree, and a gap between them only means a legacy `discount_percentage` the computed figure has already absorbed. The sync logs that case and sends the computed figure, which is what was approved.
* **Warehouse** — `line_warehouse` is **"07"**, set 18 September 2026. Every order line names it explicitly. Leave it `""` and SAP falls back to its own default, which was **01**: the finished goods all sit in **07**, so SAP committed each order against a warehouse holding nothing while 07 looked entirely free. `I-14636` read `on hand 0 / committed 120` in 01 and `on hand 100 / committed 0` in 07 at the same moment. The company-wide figures netted out correctly — 100 on hand, 120 committed — which is exactly why it went unnoticed: the stock sync reads `Items`, not `ItemWarehouseInfoCollection`, so its numbers were right all along. Anything that asks about availability **per warehouse** would have been wrong in both directions. Orders 406 and 407 were moved to 07 by hand; `Test-OrderLinePricing.ps1` asserts the key is present, absent when unset, and survives the price-off early return.
* **Split invoices** — if one SO is invoiced across several invoices, each line records the invoice that carried it, and the order records the one that completed it (latest `DocDate`, then `DocEntry`).
* **Invoiced orders** — drop out of PASS B once `custom_sap_invoice` is set on the order, which happens only when every line is invoiced; `custom_sap_synced_at` then stops moving. An order SAP cancelled is never invoiced and so stays in PASS B, as it did before.
