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
   `custom_sap_sales_order`.
3. SAP links a production order and moves it through stages. The sync copies
   the DocNum and the current stage back.
4. A SAP **Delivery Order** eventually carries several orders out together. The
   sync writes its DocNum and ship date onto **every order it carries**.

---

## The fields

All nine are on `Sales Order`, all `allow_on_submit = 1`, all read-only in
Desk. Created 11 September 2026 and verified live.

| field | type | written by | means |
|---|---|---|---|
| `custom_sap_sales_order` | Data | sync, step 2 | SAP's DocNum. The proof it reached the factory. |
| `custom_sap_sales_order_status` | Data | sync | SAP's own words. Shown verbatim, never parsed. |
| `custom_sap_production_order` | Data | sync, step 3 | SAP's production order DocNum. |
| `custom_sap_production_stage` | Data | sync, step 3 | SAP's stage name, free text. |
| `custom_sap_delivery_order` | Data | sync, step 4 | SAP's delivery DocNum. |
| `custom_sap_delivery_date` | Date | sync, step 4 | When that delivery ships. |
| `custom_sap_synced_at` | Datetime | sync, every pass | When this order was last reconciled. |
| `custom_sap_sync_error` | Small Text | sync, on failure | Why the last push or pull failed. |

`custom_sap_section` is a Section Break, for the Desk form only.

**`allow_on_submit` is set on all eight, and kept set.** Today it is inert —
the apps do not submit Sales Orders, so the sync writes to drafts and Frappe
would take these fields either way. It stays because the flag is the trap
`custom_production_stage` originally shipped without: the day anything does
start submitting orders, a field missing it can never be written again for the
life of the document.

---

## What you must NOT write

**`custom_production_status`.** The apps derive it from the stage and the
delivery, in `shared/fixtures/sap_order_state.json`. Writing it as well gives
two sources for one answer, and they will disagree the first time a delivery
lands before a stage update.

**Anything on an order that has not been approved.** `custom_po_status ==
"PO Approved - Ready for SAP"` is the gate, together with `docstatus < 2` (any
live order — draft or, if that ever changes, submitted — but never a Frappe
cancel). An order that has not passed the gate has no business in SAP.

**`custom_sap_delivery_date` from anywhere but a delivery order.** It is a date
a rep repeats to a customer.

---

## Five things that will bite you

1. **Clear `custom_sap_sync_error` on success.** A stale error makes a working
   order look broken forever. An empty error and an empty
   `custom_sap_sales_order` together mean "not picked up yet", which is a
   normal state and is shown differently from a failure — that distinction only
   works if you clear it.

2. **Write the delivery onto every order it carries**, not just the first. A
   rep whose order is on somebody else's delivery has no other way to learn
   when it ships.

3. **Percent-encode doctype names with spaces** in REST paths
   (`Sales%20Order`). An unencoded space returns an empty body, not an error,
   and reads exactly like "no records".

4. **The useful error is in the BODY of a 417**, not the status code.

5. **Stamp `custom_sap_synced_at` on every pass**, including the ones that
   changed nothing. The apps show an order as stale when it goes quiet, and
   "nothing changed" is different from "nobody looked".

---

## How a stage becomes a status

The apps map SAP's free-text stage onto the four values every screen already
acts on. The full table is `shared/fixtures/sap_order_state.json`, read by
both test suites. In short:

- a **delivery order** means `Dispatched`, whatever the stage says — the
  delivery is the later fact, and a production record can be stale;
- `Finished`, `Closed`, `Completed`, `Ready` mean `Ready`;
- empty, `Planned`, `Open`, `Pending` mean `Not Started`;
- **anything else means `In Production`**.

That last one is deliberate. A stage nobody has mapped means the floor has
started and we do not know how far. Calling it `Ready` would tell a rep an
order is made when it is halfway through a press, so the unknown case rounds
towards "in progress" and never towards "done".

**You can add stages in SAP freely.** A new one shows up verbatim on the rep's
screen and counts as In Production without an app release. Only stages that
should read as *finished* or *not begun* need a line adding to the fixture.

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

So the reconcile takes the item codes a delivery note actually carried, which
PASS B already has in `$dnByEntryItem`. Closed **with** a delivery is finished
and left alone. Closed **without** one is the factory dropping an item, and the
ERPNext row goes.

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
