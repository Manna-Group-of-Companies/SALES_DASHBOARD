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
