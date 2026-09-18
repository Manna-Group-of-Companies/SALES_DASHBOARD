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
| `Test-SalesPerson.ps1`, `Test-LineReconcile.ps1`, `Test-PoLinking.ps1` | **yes** — they build their cases in memory and touch nothing |
| `Test-OrderLinePricing.ps1` | yes — ERPNext only, and read-only |
| `Sync-SapOrders.ps1`, the seeding scripts, the poller | **no** |

The three offline suites are the ones to develop against. They cover the
pricing, the line reconcile, the rep mapping and which production order covers
a line, which is most of the logic worth changing.

### And it is pointed at production

There is no sandbox. `config.json` names `HITECH_PRETREADS_LIVE` and the live
ERPNext site, so `Sync-SapOrders.ps1` creates real SAP orders and writes to
real ERPNext ones. **Use `-DryRun` first, every time** — it prints the exact
POST body and the ERPNext writes it would make, and changes nothing.

## Files

| File | Purpose |
| --- | --- |
| `Sync-SapOrders.ps1` | The whole job. Dry-run first, then `-Limit 2`, then unrestricted. |
| `Invoke-SapOrderSyncPoller.ps1` | Task-Scheduler poller. Reads `SAP Order Sync Control`, claims a run, executes the job as a child process with a hard timeout, reports status back. Same shape as `sap-credit-sync\Invoke-SapSyncPoller.ps1`. |
| `config.example.json` / `config.json` | Job config. `config.json` holds live creds and is git-ignored. |
| `poller.config.example.json` / `poller.config.json` | Poller config. Git-ignored. |
| `erpnext-setup.md` | Spec for the `SAP Order Sync Control` single + trigger button (not created yet). |
| `Test-PoLinking.ps1` | Offline. Attaching a hand-linked production order to the right sales order, and which PO covers a line. 25 assertions. |
| `Test-SalesPerson.ps1` | Offline. The rep -> SAP sales employee mapping, 27 assertions. Runs with SAP down. |
| `Test-LineReconcile.ps1` | Offline. What PASS B's line reconcile corrects, and what it refuses to. |
| `Test-OrderLinePricing.ps1` | Live-read. Proves a SAP line totals what the manager approved. Writes nothing. |
| `.gitignore` | keeps configs + logs out of git. |

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

**PASS B — pull production / stage / delivery.** In scope:
```
custom_sap_sales_order is set
custom_sap_delivery_order in ["", null]
docstatus < 2
```
Using **one** scan of open `ProductionOrders` and **one** scan of recent
`DeliveryNotes` (this SL build rejects lambda `$filter`, so joins are done in
memory):
* `custom_sap_sales_order_status` ← refreshed `DocumentStatus` verbatim (`bost_Cancelled` when `Cancelled = tYES`).
* `custom_sap_production_order` ← `ProductionOrders.DocumentNumber` of the production order linked to this SO. **Three** ways it can be linked, and SAP fills different fields for each: a `ProductionOrdersSalesOrderLines` row with `BaseAbsEntry` = this SO's `DocEntry`; `ProductionOrderOriginEntry` = `DocEntry` (origin `bopooSalesOrder` **or** `bopooManual` — requiring the former matched 1 of 31,853); or, when the order was raised by hand and the sales order NUMBER typed into the Sales Order field, **`ProductionOrderOriginNumber` = `DocNum` with `OriginEntry` null** — resolved back to a `DocEntry` by item, because `DocNum` is not unique here. See `../shared/SAP_ORDER_SYNC.md`.
* `custom_sap_production_stage` ← current routing stage: lowest-`SequenceNumber` `ProductionOrdersStages` row with no `EndDate`, else the last stage; **if the PO has no routing stages, a label mapped from `ProductionOrderStatus`** — `Planned` / `In Production` / `Closed` (chosen to land right in the app fixture: → Not Started / In Production / Ready).
* `custom_sap_delivery_order` ← `DeliveryNotes.DocNum` where a line has `BaseType = 17` and `BaseEntry` = this SO's `DocEntry`. Written to **every** ERPNext order the delivery carries, because each order is matched independently. **This is the Hi-Tech DN into the Manna Treads godown — stock becoming available to dispatch, not a delivery to the end customer.** The app relabels it accordingly; the sync writes it unchanged.
* `custom_sap_delivery_date` ← that delivery's `DocDueDate` (config `delivery_ship_date_from`). **Only ever set from a delivery.**
* `custom_sap_synced_at` ← now, **every pass, changed or not**.
* `custom_sap_sync_error` ← "" on any clean pass.

**Never written here:** `custom_production_status` (the app derives it from
stage + delivery), and `custom_sap_delivery_date` from anything but a delivery.

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
    "status_source": "document_status",                   // (reserved) how custom_sap_sales_order_status is filled
    "stage_source": "routing_stages",                     // routing_stages | production_status
    "stamp_erpnext_name_in": "NumAtCard",                 // NumAtCard | U_FreeText | none
    "delivery_ship_date_from": "DocDueDate",              // DocDate | DocDueDate
    "production_scan_statuses": ["boposPlanned","boposReleased","boposClosed"],
    "delivery_scan_days": 120,                            // DeliveryNotes with DocDate within N days
    "production_status_labels": { "boposPlanned":"Planned", "boposReleased":"In Production",
                                  "boposClosed":"Closed", "boposCancelled":"Cancelled" }
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
* **Stage → status is entirely app-side** (`shared/fixtures/sap_order_state.json`). The job copies `ProductionOrdersStages[].Name` verbatim and writes nothing to `custom_production_status`. Unrecognised stage ⇒ app reads it as *In Production* (correct/safe). A non-empty `custom_sap_delivery_order` ⇒ app reads *Dispatched* regardless of stage.
* **`custom_sap_production_stage` fallback** — while routing stages are unused in B1, the job emits a label from `ProductionOrderStatus` chosen to land right in the fixture: `boposPlanned→"Planned"` (→ Not Started), `boposReleased→"In Production"`, `boposClosed→"Closed"` (→ Ready). Once *Administration → Setup → Production → Routing Stages* is populated and stages are on the BOM routing, real stage names flow through with no code change.
* **`custom_sap_sales_order_status`** — `DocumentStatus` verbatim (`bost_Open`/`bost_Close`, `bost_Cancelled` on cancel). Display-only; the app's *Ready* comes from the stage, not this. `bost_Close` here does **not** imply Ready.
* **Ship date** — `DocDueDate` (the promised date a rep repeats to a customer), set in `config.json`.
* **Datetime** — `yyyy-MM-dd HH:mm:ss`, naive, site TZ (Asia/Kolkata). **The scheduled-task host must run in IST** or the stamp is wrong (same caveat as the credit sync).
* **`custom_rolls` / `custom_loose_belts`** — dropped, as instructed.
* **Automations** — the three Sales Order DocType-event server scripts are disabled; nothing fires on these writes.
* **PO⇄SO / Delivery⇄SO** — the floor builds production order and delivery as a document chain **from** the Hi-Tech SAP sales order (confirmed with the site), so `ProductionOrdersSalesOrderLines[].BaseAbsEntry` / `ProductionOrderOriginEntry` and `DeliveryNotes.DocumentLines[].BaseEntry` (BaseType 17) carry the SO `DocEntry`.

### Customer & items — settled by the final scope

* **Customer** — always `CardCode 20416`. No `custom_bp_code`, no lookup, no mapping table. (`custom_bp_code` holds `MANNA_TREADS_LIVE` codes for the out-of-scope stage-two push; a `C-`-strip transform against those was checked and produced only false positives — `10016`/`10047` are different customers in the two books. Never derive a CardCode.)
* **Items** — `item_code` **is** the `HITECH_PRETREADS_LIVE` `ItemCode` by construction (the 10 Sep 2026 FG import took them from that DB). No transform. Five pre-existing non-SAP items (`BONDING GUM`, `COMPOUNDED RUBBER`, `220 MXM 128 (MANNA)`, `RUBBER VULCANISING SOLUTION 10LTR`, `DEMO-RETREAD-1000x20`) won't resolve; an order containing one fails whole (SAP rejects the `POST`, the error names the line, `custom_sap_sync_error` records it). Matches the contract.

### Minor decisions (left as-is; revisit if needed)

* **Line price** — `send_line_unit_price` is **true**, changed 17 September 2026 on the instruction that "the sales order should have the pricing same as what the app gave it". The SAP order carries the **approved net rate per kilo**, computed as `amount / custom_total_weight` with `DiscountPercent` forced to 0. It is deliberately NOT `custom_rate_per_kg`: that field is the *pre*-discount quote, and on SAL-ORD-2026-00135 (25/kg less 10%) it would have overcharged the factory document by the discount. Discounts were then removed from both apps entirely — the rep types the rate after discount — so on a current order the two agree, and a gap between them only means a legacy `discount_percentage` the computed figure has already absorbed. The sync logs that case and sends the computed figure, which is what was approved.
* **Split deliveries** — if one SO ships on more than one Hi-Tech delivery, the job writes the **earliest** delivery's DocNum + `DocDueDate`.
* **Delivered orders** — drop out of PASS B once `custom_sap_delivery_order` is set; `custom_sap_synced_at` stops moving. Widen PASS B if the app flags such orders as stale.
