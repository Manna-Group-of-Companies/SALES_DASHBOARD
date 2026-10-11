# SAP order sync — the ERPNext contract

The manufacturing floor moved to SAP on **11 September 2026**. This is what the
apps read, what the sync must write, and the handful of things that will bite
whoever writes it.

The apps do not push to SAP and do not compute floor state. They report it.

---

## The flow

1. A sales manager approves an order in ERPNext.
   `custom_po_status` becomes `PO Approved - Ready for SAP`. The order is **not
   submitted** — neither app has ever submitted a Sales Order; approval is a
   field write and the order stays `docstatus = 0`. See `DIVERGENCES.md`.
2. **The sync creates a Sales Order in SAP** and writes its DocNum back to
   `custom_sap_sales_order`. The apps now show the order as **Pushed to SAP**.
3. SAP is the record from here. A line the factory reduces or drops in SAP is
   reduced or removed in ERPNext by the sync's line reconcile.
4. An **A/R invoice** is raised against the order, possibly in parts. The sync
   writes it onto each line it carried, and onto the order once every line is
   invoiced. The apps now show it as **Dispatched**.
5. **Stage two (26 September 2026) — switched off 8 October 2026.** Once Hi-Tech has closed the order, the
   accountant approves it on the dashboard and the sync creates the matching
   Sales Order in **`MANNA_TREADS_LIVE`**, to the end customer, for what Hi-Tech
   actually delivered. See *Stage two — Manna Treads sales orders* below.

**Changed 24 September 2026:** production orders and deliveries no longer drive
anything. Under MRP one production order pools the demand of many sales orders
and SAP does not record which order it is for — MRP-created orders carry no
sales-order link, and the link table has no quantity column — so a per-order
production stage would be a guess. And the floor delivers before it invoices,
so a delivery is not dispatch. See `fixtures/sap_order_state.json`.

**When it runs — changed 24 September 2026.** Nothing syncs on a timer. The
sync runs when somebody presses **Sync** (on every screen of both apps), or
when an order becomes approved. See `sap-order-sync/README.md` → *When it
runs*. That puts one obligation on **both** apps, and it is a shared rule:

> **Anything that makes a Sales Order `PO Approved - Ready for SAP` must then
> call `manna_sap_order_request_sync`.** Otherwise the order never reaches SAP
> until somebody happens to press Sync.

Today that is two places on each side: approving an order (`decideOrder` /
`approveSalesOrderPO`) and converting a lead order, which creates the Sales
Order already approved (`approveLeadOrder` / `_salesOrderFromLeadOrder`). The
request is fire-and-forget — the approval stands whether it lands or not — and
a failure is logged, because nothing sweeps the order up afterwards.

---

## The fields

On `Sales Order`, all `allow_on_submit = 1`, all read-only in Desk.

| field | type | written by | means |
|---|---|---|---|
| `custom_sap_sales_order` | Data | sync, step 2 | SAP's DocNum. The proof it reached the factory. |
| `custom_sap_sales_order_status` | Data | sync | SAP's own words. Shown verbatim, never parsed — except `bost_Cancelled`. |
| `custom_sap_invoice` | Data | sync, step 4 | The invoice that **completed** the order. Set only once every line is invoiced. |
| `custom_sap_invoice_date` | Date | sync, step 4 | That invoice's posting date. |
| `custom_sap_synced_at` | Datetime | sync, every pass | When this order was last reconciled. |
| `custom_sap_sync_error` | Small Text | sync, on failure | Why the last push or pull failed. |

And on `Sales Order Item`, per line:

| field | type | written by | means |
|---|---|---|---|
| `custom_sap_invoice` | Data | sync, step 4 | The invoice that carried **this** line. |
| `custom_sap_invoice_date` | Date | sync, step 4 | That invoice's posting date. |

`custom_sap_section` is a Section Break, for the Desk form only.

Stage two added three more line fields and seven order fields on 26 September
2026 — listed under *Stage two — Manna Treads sales orders* below.

**No longer written or read (24 Sep 2026):** `custom_sap_production_order`,
`custom_sap_production_stage`, `custom_sap_delivery_order` and
`custom_sap_delivery_date`, on both the order and the line. They stay in
ERPNext with whatever they last held. Nothing may act on them.

**`allow_on_submit` is set on every field above, and kept set.** Today it is inert —
the apps do not submit Sales Orders, so the sync writes to drafts and Frappe
would take these fields either way. It stays because the flag is the trap
`custom_production_stage` originally shipped without: the day anything does
start submitting orders, a field missing it can never be written again for the
life of the document.

---

## What you must NOT write

**`custom_production_status`.** The apps derive the status from the SAP order
number and the invoice, in `shared/fixtures/sap_order_state.json`. Writing it
as well gives two sources for one answer.

**The order-level `custom_sap_invoice` on a partial invoice.** It is what takes
an order out of the sync's polling. Set it on the first invoice and the rest of
the order is never followed again.

**Anything on an order that has not been approved.** `custom_po_status ==
"PO Approved - Ready for SAP"` is the gate, together with `docstatus < 2` (any
live order — draft or, if that ever changes, submitted — but never a Frappe
cancel). An order that has not passed the gate has no business in SAP.

---

## Five things that will bite you

1. **Clear `custom_sap_sync_error` on success.** A stale error makes a working
   order look broken forever. An empty error and an empty
   `custom_sap_sales_order` together mean "not picked up yet", which is a
   normal state and is shown differently from a failure — that distinction only
   works if you clear it.

2. **Resolve a pooled invoice line by line**, not invoice by invoice. One
   invoice can carry lines from several orders, and a line may be based on the
   order (`BaseType 17`) or on a delivery (`BaseType 15`) that must be followed
   back to its own base. A rep whose order is on somebody else's invoice has no
   other way to learn it has gone.

3. **Percent-encode doctype names with spaces** in REST paths
   (`Sales%20Order`). An unencoded space returns an empty body, not an error,
   and reads exactly like "no records".

4. **The useful error is in the BODY of a 417**, not the status code.

5. **Stamp `custom_sap_synced_at` on every pass**, including the ones that
   changed nothing. The apps show an order as stale when it goes quiet, and
   "nothing changed" is different from "nobody looked".

---

## How an order gets its status

Three values, from two facts. The full table is
`shared/fixtures/sap_order_state.json`, read by both test suites.

- no SAP order number: **Not Started**;
- SAP has the order, not invoiced: **Pushed to SAP**;
- invoiced: **Dispatched**.

Per line, a line is Dispatched only when **that** line was invoiced, and the
order rolls up to its least advanced line — a partly-invoiced order is still
Pushed to SAP. `bost_Cancelled` outranks all of it.

An order **list** (and the completion tick, and the phone's duplicate-order
check) shows this status once SAP has the order, and the stored in-app
`custom_production_status` only before — `orderProgress` on both sides, cases
`order_progress`. An in-app Dispatched on an order SAP has not invoiced is not
dispatch. A list query must therefore fetch `custom_sap_sales_order` and
`custom_sap_invoice`, or every order silently falls back to the in-app status.

*Superseded 24 Sep 2026:* the stage-to-status table that used to be here —
`Finished`/`Closed` → Ready, unknown stage → In Production, delivery →
Dispatched — is gone with the production-order link.

---

## SAP corrects the order; ERPNext follows — added 18 September 2026

Approval locks an order in both apps (`shared/fixtures/order_locked_after_approval.json`).
Changes go through the manufacturing team in SAP instead, so PASS B now reads
SAP's lines and makes ERPNext match. `order_sync.reconcile_lines_from_sap`,
default **on** — an app that cannot be edited and does not follow would just be
stale.

`Get-ErpLineCorrections` plans; `Test-LineReconcile.ps1` proves it against the
real function without touching either system.

### What it does

Quantities are compared in **kilos**: SAP's `Quantity` against ERPNext's
`custom_total_weight`, which is what the sync sends in the first place.

- **Reduced** → the ERPNext line is scaled. `custom_total_weight` takes SAP's
  figure exactly; `qty`, `custom_rolls`, `custom_loose_belts` and `amount`
  scale with it; `rate` and `custom_rate_per_kg` do not move, because the price
  per roll has not changed. The packing note is rebuilt.
- **Dropped** → the ERPNext row is deleted.
- **Unchanged** → nothing is written.

Child rows go through `frappe.client.set_value` and `frappe.client.delete`. Both
leave the parent's totals correct — verified live: 5,800 → 4,600 on a reduce,
and again on a delete.

### Closed is ambiguous, and the delivery note is the tie-breaker

A SAP order line reads `bost_Close` with `RemainingOpenQuantity 0` in two
unrelated situations: **it shipped**, or **somebody closed the row to drop it**.
There is no `DeliveredQuantity` on a Service Layer order line to separate them —
checked against the live DB, the quantity fields are `Quantity`,
`RemainingOpenQuantity` and `LineStatus`, and that is all.

So the reconcile takes the item codes a delivery note **or an A/R invoice**
actually carried, which PASS B has in `$dnByEntryItem` and `$invByEntryItem`.
Closed **with** either is finished and left alone. Closed **without** either is
the factory dropping an item, and the ERPNext row goes.

Invoices were added on 24 September 2026, when the invoice became the dispatch
signal: a line invoiced straight from the order has no delivery at all, and
without invoices in the set it would read as dropped and be deleted — a line
the customer has already been billed for.

Getting this backwards deletes the lines the customer has already been sent.

**A cancelled delivery is not a delivery — fixed 26 September 2026.** SAP
keeps a cancelled delivery (`Cancelled = tYES`, `CancelStatus = csYes`) and
posts a reversal beside it (`CancelStatus = csCancellation`, lines `BaseType
15`). The scan never asked, so a cancelled delivery counted as "shipped" here,
and a line the factory then closed to drop it was kept. The delivery scan now
selects `Cancelled,CancelStatus` and counts only `csNo`.

### Five things it refuses to do

Each of these plans nothing and says why, because a wrong correction silently
rewrites a customer's order:

1. **SAP returned no lines.** That is a failed read, not an emptied order.
2. **No delivery information at all** on an order whose lines are closed —
   the all-gone guard catches it rather than deleting a shipped order.
3. **The same item on two lines**, either side. Matching is by item code.
4. **Every line absent from SAP.** Frappe refuses the last row anyway
   (`MandatoryError: items`); an order that has lost everything wants a human.
5. **A family whose packing note cannot be rebuilt** — anything but PCTR and
   CTR. Corrected figures beside a stale note are worse than an untouched line,
   and reproducing the BG/VS packing breakdown here would be that rule's third
   implementation.

### A bug this uncovered

`Invoke-ErpApi` sent its JSON body as a **string**. PS 5.1's `ConvertTo-Json`
emits non-ASCII literally rather than as `\uXXXX`, and `Invoke-RestMethod` then
encoded it with the default codepage — so ERPNext stored `3 rolls ? 144.00 kg`
where the middle dot belonged. The body is now UTF-8 **bytes** with an explicit
charset. Every non-ASCII character this script could ever have written was
affected; it had simply never written one before.

### Verified end to end, 18 September 2026

ERPNext order → SAP (DocEntry 2890, ₹10,128 at 30/kg and 28/kg, matching
exactly) → line reduced in SAP twice (192 → 144 → 120 kg) → ERPNext corrected
each time, totals agreeing to the rupee → second line closed without a delivery
→ ERPNext row removed, order left at ₹3,600 on one line → re-run planned
nothing, so the reconcile is idempotent. Test data removed afterwards: the
ERPNext order deleted, SAP 2890 cancelled.

---

## The rep is tagged on the SAP order — added 18 September 2026

The SAP order now carries the rep who raised it, as **SalesPersonCode**. Before
this it carried nothing: the sync had a single `sap.sales_person_code` setting
in its config, it was `null`, and every order arrived at the factory with no
sales employee at all.

**The join is the name.** There is no id the two systems share, so PASS A reads
`custom_sales_person` off the Sales Order and looks it up among SAP's active
sales employees by name — case-insensitive, surrounding blanks ignored, nothing
else forgiven. Every SAP sales employee was created with exactly the ERPNext
`Sales Person` spelling for this reason.

| ERPNext `Sales Person` | SAP `SalesEmployeeCode` |
|---|---|
| Pareeth Kb | 10 |
| Jaimon D | 11 |
| Sirajudheen Kasim | 12 |
| Amjad Pr | 13 |
| Prashanth | 14 |
| Test Rep | 15 |

Those are the six `Sales Person` records whose `custom_company` is **Manna
Treads**, which is every rep whose orders reach this SAP company. The other
twelve belong to Manna Tyre Retreads and Manna Tyres UAE and have no SAP
counterpart.

**Add a rep on one side and you must add them on the other.** A near-match is
deliberately not accepted — tagging "Test Reps" as "Test Rep" would file one
person's work under another's, which is worse than leaving it blank.

### An unknown rep is a warning, never a failure

The order is still created, with `sap.sales_person_code` if one is configured
and otherwise with no sales employee. An order stuck outside SAP because nobody
added an employee record stops the factory; an order inside it with the
employee blank is a field to fill in. The log names the rep and says where to
add them, and the run summary counts it as `rep unmatched: N`.

Inactive employees are not matched, and neither is SAP's own
`-No Sales Employee-` placeholder (code -1).

### It does not leak the customer

This is the only thing in the payload that names a person, and it names one of
**ours**. The end customer stays invisible: CardCode is always the fixed
inter-company code, and there is still no address, contact, territory or
comment on the order.

### Verified end to end, 18 September 2026

ERPNext `SAL-ORD-2026-00143`, raised by Test Rep → SAP DocNum **407**
(DocEntry 2892), read back carrying `SalesPersonCode: 15` and
`DocTotal 16000.0`, which is the approved price to the rupee (40 kg + 24 kg at
₹250). `Test-SalesPerson.ps1` holds the mapping offline in 27 assertions.

---

## Stage two — Manna Treads sales orders — added 26 September 2026

> **Switched off 8 October 2026, on the user's instruction** ("for now, we
> cannot send the sales orders to Manna Treads from the accountant view"). The
> release carries only the Hi-Tech order sync and the accountant's read-only
> view, *Orders at Hi-Tech*: every order at Hi-Tech with its real customer and
> Hi-Tech's SO number, showing the delivery's contents once any delivery exists
> and the sales order until then (`client/src/domain/accountantView.ts`).
>
> - The Server Script `manna_mt_so_request` is **disabled** on the site, so
>   nothing can mark an order requested; PASS C therefore finds nothing to do.
> - The dashboard no longer offers *Create in Manna Treads*. The request code
>   stays in `client/src/api/mannaTreads.ts`, and PASS C stays in the sync.
> - To switch it back on: re-enable the script and restore the button. The
>   sync's own switch is `manna_treads.enabled` in `config.json` (default on).
>
> Everything below describes the path as built, for when it returns.

Decided by the user on 26 September 2026. Hi-Tech (`HITECH_PRETREADS_LIVE`)
makes and delivers every app order and bills Manna Treads, CardCode `10118`.
Manna Treads then bills the **end customer**, for what Hi-Tech actually
delivered — which is not always what was ordered. The accountant (Jineesh, the
dashboard role `accountant`) sees each order Hi-Tech has **closed**, grouped by
customer, with only what Hi-Tech delivered, and approves it. The office order
sync then creates a Sales Order in **`MANNA_TREADS_LIVE`** to the end customer,
through the Service Layer — the user's explicit choice of a second write path,
"just as how the order is pushed to Hi-Tech on manager approval".

The commercial boundary is unchanged: nothing about the end customer ever goes
to Hi-Tech. This is Manna Treads billing its own customer in its own company.

**The rule** is `fixtures/manna_treads_reorder.json` — its `rules` block is the
specification — implemented by the dashboard (TypeScript) and by
`Get-MtReorderPlan` in the sync, and both test suites read that file. Bill what
was **delivered**, line by line; only an order with no delivery at all is
billed on what was **invoiced**; never both. A line with nothing is left out.
The price is the approved `amount / custom_total_weight`, which is
GST-inclusive, so the SAP line carries it **net of GST** with the tax code.

### The fields

On `Sales Order Item`, written by the sync's PASS B, all `read_only`,
`allow_on_submit`, `no_copy`:

| field | type | means |
|---|---|---|
| `custom_hitech_delivered_kg` | Float (3) | kg on Hi-Tech delivery notes with `CancelStatus = csNo`, drawn from this line |
| `custom_hitech_invoiced_kg` | Float (3) | kg on Hi-Tech A/R invoice lines drawn **straight** from this line (`BaseType 17`); cancelled invoices excluded; a line invoiced from a delivery is not counted here |
| `custom_hitech_delivery_refs` | Small Text | `DN 4 (18-09-2026), DN 7 (20-09-2026)` |

On `Sales Order`:

| field | type | written by | means |
|---|---|---|---|
| `custom_mt_so_requested` | Check | **`manna_mt_so_request` only** | the accountant approved it |
| `custom_mt_so_requested_by` / `_at` | Data / Datetime | `manna_mt_so_request` | who, when |
| `custom_mt_sales_order` | Data | sync, PASS C | the Manna Treads DocNum |
| `custom_mt_sales_order_entry` | Data | sync, PASS C | its DocEntry — DocNum is not unique in SAP |
| `custom_mt_sync_error` | Small Text | sync, PASS C (cleared by the request script) | why it was not created |
| `custom_mt_synced_at` | Datetime | sync, PASS C | when PASS C last wrote to it |

And `User.custom_is_accountant` (Check) is how the dashboard recognises the
accountant, the way `custom_is_managing_director` recognises the MD.

### The request — `manna_mt_so_request`

`POST /api/method/manna_mt_so_request`, form field `orders` = a JSON array of
Sales Order names. Accountant or System Manager only. Per order it re-checks
that the order is in SAP, Hi-Tech-closed, not cancelled, has a Manna Treads
customer code and no Manna Treads order yet; then sets
`custom_mt_so_requested = 1` / `_by` / `_at`, clears `custom_mt_sync_error`, and
raises `SAP Order Sync Control.sync_requested`. Returns
`{ results: [{ order, ok, message }], flag_raised }`.

### What the sync does — PASS C

After PASS A and B, for the rule's **queued** orders only —
`custom_mt_so_requested = 1`, no `custom_mt_sales_order`, **no
`custom_mt_sync_error`**, `custom_sap_sales_order` set, **`custom_po_status`
exactly the PASS A gate** and `docstatus < 2` — inside a named system mutex so
two runs cannot both post (a run that finds it held skips PASS C with a WARN):

1. Before the Manna Treads login: re-read and plan with the rule, and work out
   — not yet act on — what refuses it, the first that applies:
   **not asked for by an approver** (`custom_mt_so_requested_by` not in
   `manna_treads.approvers`, by default the accountant alone); **another live
   ERPNext order on the same Hi-Tech SO** (a Desk *Duplicate* copies
   `custom_sap_sales_order`; one Hi-Tech order is billed once); **an item on
   two lines** (PASS B cannot split Hi-Tech's kilos between them, so the order
   would post short); **Hi-Tech's own order, read by the Hi-Tech session this
   run, not backing the recorded kilos** — not found, its `NumAtCard` naming
   another order, not closed now, dated before the scan windows, an item it
   sent on two of its lines or on a line this order lacks, kilos recorded for
   an item not on it, or recorded kilos that differ from what it shows now;
   the rule's state (not closed, cancelled, nothing delivered); another
   unit's order; no customer code; a line with no price; **delivered, and
   part invoiced straight from the order** (the rule's `delivery_wins` would
   leave those kilos unbilled); **an item not on the allowlist**
   (`manna_treads.item_allowlist`, by default exactly the ten SYNC TEST items
   `I-14636`..`I-14645`). The Hi-Tech session therefore logs in whenever PASS
   C has a queued order.
2. Only if a queued order is left: **its own Service Layer session** to
   `MANNA_TREADS_LIVE`, opened after the Hi-Tech session has logged out — never
   two of the five SAP seats at once — and logged out in a `finally`.
3. **The `NumAtCard` lookup comes first.** One live Manna Treads order
   carrying the ERPNext name is **adopted** whatever step 1 said (a previous
   run posted it and failed to write it back); two are refused as a
   duplicate; none, and step 1's refusal stands.
4. Otherwise validate the customer (exists, live, **its `CardName` the ERPNext
   `customer_name`**, billed in Kerala) and every
   item (exists, live, a sales item, **and the same product: its Manna Treads
   `ItemName` equals the ERPNext line's `item_name`**, spacing and case
   aside), then `POST /Orders`: CardCode = `Customer.custom_bp_code`, dated
   **today**, NumAtCard = the ERPNext name, **Series 189**, branch 1,
   **DiscountPercent 0 on the header and every line**, warehouse `01`,
   `CG+SG@18`, location 2, one line per billable line at the net price. The
   details are in `sap-order-sync/README.md` → *Stage two*.

**A refusal is the order's, a transient failure is the run's.** Every refusal
above — and SAP refusing the POST itself (HTTP 4xx with an SAP error body) —
writes the reason (plain words, at most 250 characters) into
`custom_mt_sync_error` with `custom_mt_synced_at`, **leaves
`custom_mt_so_requested = 1`**, and does **not** fail the run. The order is
then *failed* in the fixture's terms: the dashboard shows it with the reason
and **Try again**, which calls `manna_mt_so_request`, which clears the error.
The sync never retries a failed order by itself. A transient failure — no
response, a timeout, a login failure, HTTP 5xx or the empty-body 500, any SAP
read, any ERPNext read or write, or stale kilos on an order PASS B was due to
refresh this run — writes **nothing** on the order, leaves it queued for the
next run, and fails the run (exit 1). Stale kilos on an order nothing will
refresh (retired, closed at Hi-Tech) are a refusal.

**PASS B keeps following an order it has retired while Hi-Tech's SO is still
open** — every line invoiced (`custom_sap_invoice` set) but the SAP status not
`bost_Close` / `bost_Cancelled`, `custom_company = "Manna Treads"`, no Manna
Treads order yet. For those it refreshes only `custom_sap_sales_order_status`
and the three `custom_hitech_*` kilo fields (kilos first; a failed kilo write
holds the status back a run), so a short-delivered order invoiced before
Hi-Tech closed it still becomes *ready*. **On every PASS B order the kilos are
written before the header**; if any kilo write fails, the header holds back
the SAP status (so the order does not read *ready* on stale kilos) and, on the
pass that would retire it, the order-level invoice. And PASS B writes **no**
kilos to an order when the Hi-Tech SO's `NumAtCard` names another ERPNext
order — they are that order's.

### Things that will bite you

1. **`qty` is rolls**, whatever the UOM says. Ordered kilos are
   `custom_total_weight`; billed kilos are the two Hi-Tech fields above.
2. **Delivered and invoiced are never added — and an order with both is
   refused.** `custom_hitech_invoiced_kg` counts only invoice lines drawn
   straight from the order, so an invoice drawn from a delivery is never
   counted twice. But that also means that on an order with any delivery,
   `custom_hitech_invoiced_kg` is always goods that left *without* one, which
   the fixture's `delivery_wins` leaves unbilled. The sync refuses such an
   order (*"Hi-Tech invoiced ... straight from its order without a delivery,
   and delivered the rest ..."*) until the rule itself is decided — fixture
   and both implementations, one commit.
3. **The approved rate includes GST.** `220` gross is `UnitPrice 186.440678`
   under `CG+SG@18`. Sending the gross rate bills the customer 18% high.
4. **Items do not map yet, and the same code can be a different product.**
   Real item codes differ between the two companies and there is no mapping;
   at least one Hi-Tech code exists in Manna Treads SAP as a different tread.
   Only the SYNC TEST items `I-14636`..`I-14645` were created as the same
   product in both (names checked equal in both companies, 26 Sep 2026), and
   they are the whole default allowlist. Any other item is refused by name —
   *"I-11688 is not set up for Manna Treads sales orders yet."* — and an
   allowed item whose Manna Treads name differs from ERPNext's is refused
   naming both. Widening `manna_treads.item_allowlist` is a decision, not a
   config tidy-up.
5. **A customer billed outside Kerala is refused.** `CG+SG@18` is the
   intra-state split; out of state is IGST, and the sync does not guess a tax
   code.
6. **Only `manna_mt_so_request` is meant to set `custom_mt_so_requested` —
   and the sync checks who it names.** The field and `_by` are permlevel 0, so
   REST can set them without the script's role check. PASS C acts only when
   `custom_mt_so_requested_by` is one of `manna_treads.approvers` (the sync's
   ERPNext user cannot read `User` or `Has Role`). That catches the flag set
   by anything else, not a forger who also sets `_by`: for that, the three
   request fields belong at permlevel 1 (System Manager write; read for the
   Manna Treads screen's roles and *SAP Sync Bot*).
7. **The gate is PASS A's, never wider.** An order at `Pending Final Approval`
   or `Pending GM Approval` reaches neither company.
8. **Rounding is the dashboard's, to the paisa.** Both sides take the value
   to 15 significant figures and round the *decimal* half away from zero
   (`roundTo` / `Get-RoundedHalfUp`); the fixture case "half-paisa midpoints
   round UP" pins it. Rounding the raw double keyed `6029.70 / 60 kg` into SAP
   at 100.49 where the accountant approved 100.50.
9. **GST is fixed: 18%, and the approved rate includes it** — the fixture's
   `gst_percent`, the dashboard's `GST_PERCENT`, the sync's `Get-MtGstPercent`.
   It is not a config key.
10. **An item on two lines is refused, not posted short.** PASS B matches
    Hi-Tech's kilos to a row by item code, so an item on two rows gets none on
    either, and the rule would leave both out as "nothing delivered". The
    sync refuses the order — *"I-xxxxx is on two lines of this order;
    Hi-Tech's kilos cannot be split between them - raise it in SAP by hand."*
    The dashboard cannot see this and shows it as the sync's error.
11. **The same on Hi-Tech's side.** An item Hi-Tech sent on two of its lines,
    or on a line the ERPNext order does not have (added at the factory), gets
    no kilos from PASS B — so PASS C checks Hi-Tech's own order, read that
    very run, against every kilo recorded, and refuses rather than post
    short (*"Hi-Tech delivered I-14641 (25 kg) on a line this order cannot be
    matched to - raise it in SAP by hand."*).
12. **One Hi-Tech order is billed once.** `custom_sap_sales_order` and its
    status are copied by a Desk *Duplicate* (`no_copy = 0`), and PASS B finds
    the Hi-Tech order by `DocNum`. PASS C refuses an order whose Hi-Tech SO is
    on any other live ERPNext order, or whose `NumAtCard` names another order;
    PASS B writes no kilos in the second case. Setting `no_copy = 1` on
    `custom_sap_sales_order` and `custom_sap_sales_order_status` closes the
    Desk route. Note the one legitimate clash this also stops: two Hi-Tech
    series restarting their numbers, so two different SOs share a `DocNum` —
    raise that one by hand.

---

## A production order linked by hand — fixed 18 September 2026

> **Superseded 24 September 2026.** The sync no longer reads production orders
> at all (see *The flow* above), so this fix and its code are gone. The section
> is kept because its measurement still stands and explains the decision: the
> factory's production orders almost never carry a sales-order link.

**The symptom.** SAP order 406 had a **Released** production order against its
I-14637 line. The PWA showed the order as Not Started. The sync was not
mis-reporting the stage — it had never seen the production order at all.

**The cause.** SAP records the sales-order link on a production order in two
different places depending on how it was made:

| How the production order was made | `OriginEntry` (DocEntry) | `OriginNumber` (DocNum) |
|---|---|---|
| Procurement Confirmation Wizard | set | set |
| Raised by hand, order number typed into the **Sales Order** field | **null** | set |

The sync joined on `ProductionOrderOriginEntry` only, and a comment in it
claimed SAP filled that field for both styles. It does not. Every hand-linked
production order was invisible.

Measured on the live database: of 32,590 production orders, 9 carried
`OriginAbs` (all wizard-made) and exactly 1 carried `OriginNumber` with no
`OriginAbs` — the hand-linked one that exposed this.

**The fix.** The prefetch now scans on both fields, and a number-only link is
resolved back to a DocEntry by `Resolve-SoEntryByDocNumAndItem`.

### Why the number alone is not enough

`DocNum` is not unique in this database. **DocNum 406 is four different sales
orders** — DocEntry 406 (Jan 2024), 1013 (Aug 2024), 2041 (Sep 2025) and 2891
(Sep 2026). A production order saying "sales order 406" does not say which.

**The item is the tie-breaker.** A production order makes one item, and that
item has to be on the order it is for. I-14637 appears on only DocEntry 2891 of
the four, so the link resolves cleanly.

The resolver returns a DocEntry **only** when exactly one candidate carries the
item. Zero candidates, two or more candidates, or a production order naming no
item are all **refused with a warning** and attached to nothing. Guessing would
report a stranger's order as being made; refusing leaves the line Not Started,
which is wrong but visibly wrong.

### What this means for the floor

Typing the sales order number into a production order's **Sales Order** field
now works — the sync will find it. That is the cheap path, and it needs no
change to how the floor works beyond filling that one field in.

It is still worth knowing that **no real production order in this database
carries either link today**. Every one the floor has raised is
`bopooManual` with both fields null, so until that field gets filled in, real
orders will report Not Started however healthy the sync is.

### Verified 18 September 2026

`SAL-ORD-2026-00142` / SAP 406: line I-14636 → PO 4421, line I-14637 → PO
**4429**, both **In Production**. The cancelled PO 4422 on that same line was
correctly ignored — `Select-LeastAdvancedPo` skips cancelled orders, so the
live one wins rather than the line reading Not Started.
`Test-PoLinking.ps1` holds the resolver offline in 14 assertions.

### Which production order covers a line, when there are several

`Select-LeastAdvancedPo` reports the **least advanced of the non-cancelled**
ones. Not "the open one" — the distinction matters. Verified behaviour:

| Production orders on the line | Reported | The apps show |
|---|---|---|
| Cancelled + Released | the Released one | In Production |
| Cancelled only | none | Not Started |
| All cancelled | none | Not Started |
| Released + Closed | the Released one | In Production |
| **Planned + Released** | **the Planned one** | **Not Started** |
| **Cancelled + a replacement still Planned** | **the Planned one** | **Not Started** |
| An unmapped status + Closed | the unmapped one | In Production |

The last three are the surprising ones, and they are deliberate. Two live
production orders usually mean the quantity was split — part started, part not
— and the line is not in production until the planned part starts. Reporting
the most advanced would tell a rep an order is being made while some of it has
not been touched.

**The practical consequence:** cancel a production order, raise a replacement,
and the line reads **Not Started until somebody Releases it**. That looks
exactly like the hand-linking bug above but is not the same thing — check the
replacement's status before suspecting the sync. `Test-PoLinking.ps1` pins all
seven rows.
