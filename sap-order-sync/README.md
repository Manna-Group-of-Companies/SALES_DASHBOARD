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
`20416` ("Manna Treads Private Limited(GJ)"), dates, item codes, quantities, and
the opaque ERPNext order name in `NumAtCard`. No end-customer name, code,
address, territory, contact, comment or line remark — anywhere. End-customer
traceability lives in ERPNext, keyed on the order name. **One ERPNext order →
one Hi-Tech Sales Order; never aggregated.**

The customer-wise re-order into `MANNA_TREADS_LIVE` by the godown storekeeper is
**stage two, out of scope** — this project builds nothing for it. `custom_bp_code`
belongs to stage two and is not read here.

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
| `Invoke-FlagWatch.ps1` | The watcher. Every minute Task Scheduler starts one per sync; it reads that sync's request flag every 15 s and starts its poller only when the flag is up. Shared by the order, stock and credit syncs. |
| `Register-FlagWatchTasks.ps1` | **Run elevated, by hand.** Removes every timed order/stock/credit task and registers the three watchers. Previews unless given `-Apply`. |
| `Test-FlagWatch.ps1` | Offline. When the watcher starts a poller and when it does not. 9 assertions. |
| `Register-OrderSyncTasks.ps1` | **Superseded 24 Sep 2026** by `Register-FlagWatchTasks.ps1`; refuses to run, because it would restore the timed sync. |
| `config.example.json` / `config.json` | Job config. `config.json` holds live creds and is git-ignored. |
| `poller.config.example.json` / `poller.config.json` | Poller config. Git-ignored. |
| `erpnext-setup.md` | Spec for the `SAP Order Sync Control` single + trigger button (not created yet). |
| `Test-InvoiceLinking.ps1` | Offline. Which sales order an invoice line belongs to (directly, or through its delivery), which invoice completes an order, and that an invoiced line is never reconciled away as dropped. 19 assertions. |
| `Test-SalesPerson.ps1` | Offline. The rep -> SAP sales employee mapping, 27 assertions. Runs with SAP down. |
| `Test-LineReconcile.ps1` | Offline. What PASS B's line reconcile corrects, and what it refuses to. |
| `Test-OrderLinePricing.ps1` | Live-read. Proves a SAP line totals what the manager approved. Writes nothing. |
| `.gitignore` | keeps configs + logs out of git. |

## When it runs — only when somebody asks (from 24 Sep 2026)

Nothing syncs with SAP on a timer any more — not orders, not stock, not credit
limits. A sync runs when:

* somebody presses **Sync** — the button on every screen of both apps; or
* an order is **approved** (or created already approved from a lead order) —
  both apps raise the order flag themselves.

The press raises a flag on the sync's ERPNext Single; `Invoke-FlagWatch.ps1`
reads it every 15 seconds and starts that sync's poller. Windows Task Scheduler
cannot repeat faster than once a minute, so each watcher is a one-minute task
that looks four times inside its minute. The look is one small HTTPS read and
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
   * `CardCode` ← `order_sync.fixed_card_code` (`20416`) — always, no lookup.
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

**Dispatch is the invoice, not the delivery** (decided 24 Sep 2026). The floor
posts a delivery first, so a delivered-but-uninvoiced order reads *Pushed to
SAP*. The delivery scan stays for two jobs only: the line reconcile needs it to
tell a shipped closed line from a dropped one, and an invoice raised from a
delivery is followed back through it. Invoices feed the reconcile too — a line
invoiced straight from the order has no delivery, and would otherwise read as
dropped and be deleted.

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
    "fixed_card_code": "20416",                           // REQUIRED. Every SO uses this CardCode — no lookup
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

* **Customer** — always `CardCode 20416`. No `custom_bp_code`, no lookup, no mapping table. (`custom_bp_code` holds `MANNA_TREADS_LIVE` codes for the out-of-scope stage-two push; a `C-`-strip transform against those was checked and produced only false positives — `10016`/`10047` are different customers in the two books. Never derive a CardCode.)
* **Items** — `item_code` **is** the `HITECH_PRETREADS_LIVE` `ItemCode` by construction (the 10 Sep 2026 FG import took them from that DB). No transform. Five pre-existing non-SAP items (`BONDING GUM`, `COMPOUNDED RUBBER`, `220 MXM 128 (MANNA)`, `RUBBER VULCANISING SOLUTION 10LTR`, `DEMO-RETREAD-1000x20`) won't resolve; an order containing one fails whole (SAP rejects the `POST`, the error names the line, `custom_sap_sync_error` records it). Matches the contract.

### Minor decisions (left as-is; revisit if needed)

* **Line price** — `send_line_unit_price` is **true**, changed 17 September 2026 on the instruction that "the sales order should have the pricing same as what the app gave it". The SAP order carries the **approved net rate per kilo**, computed as `amount / custom_total_weight` with `DiscountPercent` forced to 0. It is deliberately NOT `custom_rate_per_kg`: that field is the *pre*-discount quote, and on SAL-ORD-2026-00135 (25/kg less 10%) it would have overcharged the factory document by the discount. Discounts were then removed from both apps entirely — the rep types the rate after discount — so on a current order the two agree, and a gap between them only means a legacy `discount_percentage` the computed figure has already absorbed. The sync logs that case and sends the computed figure, which is what was approved.
* **Warehouse** — `line_warehouse` is **"07"**, set 18 September 2026. Every order line names it explicitly. Leave it `""` and SAP falls back to its own default, which was **01**: the finished goods all sit in **07**, so SAP committed each order against a warehouse holding nothing while 07 looked entirely free. `I-14636` read `on hand 0 / committed 120` in 01 and `on hand 100 / committed 0` in 07 at the same moment. The company-wide figures netted out correctly — 100 on hand, 120 committed — which is exactly why it went unnoticed: the stock sync reads `Items`, not `ItemWarehouseInfoCollection`, so its numbers were right all along. Anything that asks about availability **per warehouse** would have been wrong in both directions. Orders 406 and 407 were moved to 07 by hand; `Test-OrderLinePricing.ps1` asserts the key is present, absent when unset, and survives the price-off early return.
* **Split invoices** — if one SO is invoiced across several invoices, each line records the invoice that carried it, and the order records the one that completed it (latest `DocDate`, then `DocEntry`).
* **Invoiced orders** — drop out of PASS B once `custom_sap_invoice` is set on the order, which happens only when every line is invoiced; `custom_sap_synced_at` then stops moving. An order SAP cancelled is never invoiced and so stays in PASS B, as it did before.
