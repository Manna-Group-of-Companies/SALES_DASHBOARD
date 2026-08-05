# Manna Field Sales — handoff for the PWA dashboards

You are building web dashboards (HR, Sales Manager, Production Manager,
Accounts) against the **same ERPNext site** as the existing Flutter field-sales
app. This document is what that app learned the hard way. Read it before
writing any code that touches stock, orders or approvals.

The Flutter source is the reference implementation. Where this document and the
code disagree, the code is right and this document is stale — say so.

---

## 0. The one thing that will bite you

**The site cannot run Server Scripts.** The plan was downgraded and every
server-side rule was disabled. Every business rule now lives *in the client*.

That was survivable with one client. **You are about to become the second.**
Anything you do not re-implement is simply not enforced for your users:

| Rule | Enforced only in | Consequence if you skip it |
| --- | --- | --- |
| Minimum-stock headroom | client | two users oversell the same rolls |
| 1 pm edit cutoff | client | orders change after the factory has acted |
| Rate lock after approval | client | signed-off prices get edited |
| Customer hidden from production | client (API layer) | production sees who bought what |
| Order timestamp immutability | client | who-ordered-first becomes unprovable |

There is no backend that will catch you. Budget for this: it is not a
"nice to have port", it is the correctness surface of the whole system.

If you only take one thing from this document, take the booking protocol in
§4 — get that wrong and the warehouse ships stock it does not have.

---

## 1. Connecting

- **Site:** `https://mannarubber.m.frappe.cloud`
- **API:** the plain Frappe REST resource API, `/api/resource/<DocType>`
- **Auth:** token pair — `Authorization: token <api_key>:<api_secret>`.
  Frappe never expires these, which is why the app prefers them over the
  session cookie. Get credentials from the office; they are not in this repo.
- Frappe exempts token requests from CSRF. Cookie auth does not — send
  `X-Frappe-CSRF-Token` on writes if you ever fall back to it.

Two patterns worth copying from `lib/core/session.dart`:

**Treat <500 as a response, not an exception.** Frappe returns 417 for
validation errors with a useful body. If your HTTP client throws on 4xx you
will lose the message.

**Take the clock off the `Date` response header, not the browser.** Several
rules turn on time of day (the 1 pm cutoff, attendance windows). A user
controls their own clock. `lib/core/server_clock.dart` keeps a skew from every
response and every rule reads through it. This matters less in a browser than
on a phone, but the rules must agree across clients or the same order is
editable in one and frozen in the other.

### Version gate

`Manna App Settings` (Single) holds `minimum_app_version` and
`update_message`. The Flutter app refuses to run below the minimum. It exists
because a stale client writes past rules it does not know about.

**Decide deliberately whether the PWA participates.** A web app updates itself,
so the gate matters less — but if you skip it, note that the field is currently
`1.1.0` and is about the *mobile* client only. Do not lower it.

---

## 2. Business units vs ERPNext companies

These are different axes and conflating them cost real money once.

- **Business unit** — `custom_company` on Sales Order, `custom_company` on
  Sales Person. Values: `Manna Treads`, `Manna Tyre Retreads`,
  `Manna Tyres UAE`. This is what the app filters by.
- **ERPNext Company** — `company` on Sales Order. Values:
  `Manna Rubber Products Private Limited` (INR),
  `Manna Rubber UAE` (AED).

`companyForUnit()` in `lib/core/constants.dart` maps unit → company. UAE maps
to the AED company, everything else to the INR one.

**The bug this prevents:** an earlier version picked whichever Company was
created most recently, for every rep. Rupee orders were filed into the dirham
company and silently converted — ₹5,467 became AED 210.27 with cost centre
`Main - MRU`. If you create Sales Orders, set `company`, `custom_company`,
`cost_center`, `currency` and `conversion_rate` explicitly. Do not let ERPNext
guess.

---

## 3. Products, units and the weight fields

### Item groups → families

`item_group` decides everything about how a line behaves. Match
**case-insensitively** — the app uppercases before comparing.

| Item group | Family | Counted in |
| --- | --- | --- |
| `Precured` | PCTR | rolls + loose belts |
| `Hot Rubber` | CTR | rolls |
| `Bonding Gum` | — | kg |
| `Vulcanizing Solution` | — | cans |

### `custom_avg_weight_per_roll` is the weight of a **belt**

The field name is wrong. Two rows from the live master settle it:

| Item | `custom_avg_weight_per_roll` | `custom_belts_per_roll` | `custom_weight_per_roll` |
| --- | --- | --- | --- |
| TREAD RUBBER 174 MLG 120 ''LW | 10.1 | 4 | **40.4** |
| …BLACK PEARL 102 AJAX 60 | 2.4 | 14 | **33.6** |

`field × belts = roll weight` in both. So:

- `custom_avg_weight_per_roll` → **per belt**
- `custom_weight_per_roll` → **per roll**, for PCTR *and* CTR

The name is left wrong in ERPNext because every import sheet uses it. Correct
it once, at your model boundary, and derive whichever is missing from the belt
count. Reading it as a roll weight prices a 40.4 kg roll at 10.1 kg — about a
quarter of the money.

### The qty/rate identity

ERPNext has one `qty` and one `rate`. Tread rubber is *counted in rolls* but
*priced by the kilogram*. So:

```
qty  = rolls (+ belt fraction for PCTR)
rate = ratePerKg × rollWeight
```

which preserves `qty × rate == totalWeight × ratePerKg`. There is a test
asserting exactly that in `test/order_line_test.dart`. Keep it.

`custom_rate_per_kg` stores what the rep actually quoted. Show that, not `rate`.

### Incomplete items must not price at zero

An item missing its weight would price at `rate × 0` and look normal on the
proforma. The app blocks the line instead — see `Product.isMisconfigured`.
Do the same. As of this writing **no Hot Rubber item has a roll weight**, so
CTR cannot be priced at all until the product import lands.

---

## 4. Minimum stock — read this twice

Three doctypes:

- **`Manna Minimum Stock Item`** — the pool. `item_code` (autoname),
  `qty`, `loose_belts`, `custom_reserved_qty`,
  `custom_reserved_loose_belts`, `custom_last_sold_on`, `disabled`.
- **`Manna Minimum Stock Batch`** — dated stock. `item_code`, `batch_date`,
  `qty`, `loose_belts`, `original_qty`. Naming `MSB-.#####`.
- **`Manna Stock Reservation`** — one booking. `item_code`, `qty`,
  `loose_belts`, `sales_order`, `lead_order`, `sales_person`, `batch`,
  `status` (`Active`/`Released`/`Consumed`), `reserved_on`. Naming `MSR-.#####`.

### What the numbers mean

| Concept | Source | Answers |
| --- | --- | --- |
| Minimum stock | pool `qty` | what *should* be on the shelf |
| Undispatched stock | sum of batches | what *is* there |
| Available to sell | batches − `custom_reserved_qty` | what can be promised |

The pool's `qty` is a **threshold**, not a stock level. Restocking **adds a
batch row** and never edits the pool, so the two diverge the moment stock
arrives.

**A booking does not touch the batches.** Booked stock is still on the floor
until it ships. Only availability moves. Batches fall on dispatch — which
**is not built**; today they change only when the office edits them in Desk.

Do **not** show the undispatched total on a rep-facing screen; it was removed
deliberately. A manager dashboard is a different audience and it may well
belong on yours.

### The booking protocol — the compare-and-swap

This replaces a row lock. Get it wrong and two users book the same rolls.

```
for attempt in 1..4:
    pool = GET  Manna Minimum Stock Item/<item>      # keep `modified`
    shelf = sum of open batches (fall back to pool qty — see below)
    headroom = shelf - pool.custom_reserved_qty - rollsAlreadyCutForBookedBelts
    if wanted > headroom: refuse, do not retry
    ok = PUT pool { modified: <the one we read>, custom_reserved_qty: ... }
    if ok: write the Manna Stock Reservation row and stop
    # refused → someone else won → loop and re-read
```

Frappe rejects a stale `modified` with a timestamp mismatch (409, or 417 with
`TimestampMismatchError` in the body — check both status *and* message). That
rejection is the entire safety property. **Never write the pool without sending
the `modified` you read.**

Two racers for the last three rolls resolve to exactly one winner: the loser is
refused, re-reads, sees no headroom, and fails cleanly.

Cap the retries (4 is what the app uses) so a pathological case cannot spin.

### An empty batch row is not an empty shelf

19 items carry a batch row sitting at **zero** from the original import, while
the pool figure is what the office maintains. So:

> "No usable batch record" means the rows **hold nothing**, not merely that
> there are none — and it must mean the same thing in your display *and* your
> booking check.

Getting this inconsistent is exactly the bug that shipped: the screen dropped
empty batches and fell back to the pool (showing 10 available) while the guard
saw a row existed and read zero, refusing the order the same screen offered.

Cost of the fallback: an item that genuinely sells out reads the threshold
rather than zero. Safe only while nothing empties a batch. **Revisit when
dispatch is built.**

### Belts are cut from whole rolls

Ordering belts opens a roll. The belt ceiling is
`looseAvailable + (rollsAvailable × belts_per_roll)`, and any roll needed for
belts **counts against the roll headroom** — an order for 2 rolls + 1 belt needs
*three* rolls and is refused with two.

Belts already booked have already cost a roll. Four rolls at 10 belts each with
3 rolls + 2 belts booked leaves **no whole roll and 8 belts** — not 6. Counting
booked belts only against loose belts leaves the opened roll on the shelf *and*
conjures its belts from nowhere.

Nothing is physically cut at booking time; that happens at dispatch.

`custom_belts_per_roll = 0` (incomplete master) must mean *no roll is cuttable*,
not a guessed pack size.

### Editing an order rebooks by difference

Never "release everything then re-book". Releasing puts stock back on offer and
another user can take it in the gap — a user who changed one line would lose the
rest of an order they already held. Book increases **first**, then release
decreases. If an increase is refused there is nothing to undo.

---

## 5. Orders

### Statuses

`custom_po_status` on Sales Order drives everything downstream:

- `Pending Approval` — raised, waiting on the sales manager
- `Pending Rate Approval` — was approved, then edited, back in the queue
- `PO Approved - Ready for SAP` — **approved**; this exact string is what
  production, the monthly figures and every existing record key off
- `Rejected`

The strings still say "PO" although nothing scans a purchase order any more.
They were left alone because renaming would rewrite history to no benefit —
only the *label shown to the user* changed. Map to friendly wording at the
boundary (`approvalLabel()` in `lib/core/order_rules.dart`) and never show a
rep the word "PO".

### Two rate-approved flags, doing different jobs

- **`custom_rate_approved` on the order** — "there is a decision on this".
  Cleared when a rep edits an approved order, so it returns to the queue.
- **`custom_rate_approved` on each item** — "this price is final". Carried
  through untouched, so an approved rate stays locked while the order goes
  round again.

Read *status*, never the order-level flag, to decide "is this approved". A rep
who edits an approved order must look like work to do again.

### The 1 pm rule

An order stays fully editable until **1 pm on its required delivery date** —
not midnight, and not measured from when it was raised. That is the last moment
the factory can act on a change.

Editable by the rep who raised it **or their manager** (a customer who rings
the office should not wait for their rep to come back into signal).

A missing delivery date reads as *open*, not frozen — an order without a date is
a data problem and freezing it would prevent fixing the very field that is
missing.

### Sales Order Item custom fields

`custom_product_category` (`PCTR`/`CTR`/`Bonding Gum`/`Vulcanizing Solution`),
`custom_rolls`, `custom_loose_belts`, `custom_boxes`, `custom_cans`,
`custom_total_weight`, `custom_rate_per_kg`, `custom_packing_note`,
`custom_rate_approved`, `custom_fulfilment_mode`, `custom_aged_batch`,
`custom_production_stage`.

`custom_fulfilment_mode` is `From Minimum Stock` / `New Production`, decided
**per line** by the manager — an order can hold six pooled products and the
manager may want two out of the pool today. Both directions take effect
immediately via the rebook-by-difference path.

---

## 6. Leads

A lead orders on **exactly the same terms** as a customer. `Lead Order` and
`Lead Order Item` carry the same per-family fields as their Sales Order
equivalents, plus `delivery_date`, `custom_order_placed_at`,
`custom_rate_approved`, and `sales_order` (set on approval).

### Bookings point at one order or the other

`Manna Stock Reservation` has both `sales_order` and `lead_order`. **Exactly
one is set.** They are separate doctypes so one Link field could not serve
both. Make that choice once in a small value type — see
`lib/models/order_ref.dart` — not at every call site. A lead booking written
into `sales_order` holds stock against nothing.

### Approval converts the lead

Approving a lead order:

1. **Converts the lead to a customer** — matching on **GSTIN** first, because
   Accounts will create the same party in SAP by hand and a later sync joins on
   the GST number. Two customers sharing a GSTIN make that match ambiguous.
2. **Raises the real Sales Order**, already approved, carrying the full line
   detail and the **rep's** original timestamp (not the manager's — that is
   what settles who ordered first when stock is short).
3. **Re-points the live bookings** from `lead_order` to `sales_order`.

Step 3 is a plain field update, **not** release-and-rebook. Handing stock back
even for an instant puts it on offer, and a customer could lose at the moment of
approval the rolls they were promised days ago.

### The completeness gate

A lead cannot be approved until it has a **GST number, an address and a sales
route** — it becomes a customer on approval and is invoiced from there. Refuse
*before* the manager decides, naming exactly what is missing, rather than
letting the conversion fail somewhere they cannot act on.

Collected at approval rather than lead creation on purpose: a rep meeting
someone for the first time should be able to record them in thirty seconds.

### Nothing on a lead has a credit limit

Do not show a "within credit limit" check for a lead. It has no trading
history, and a green tick reads as *a check that passed* rather than one that
was never run. Show the order total and say there is no history.

---

## 7. Production

Reads Sales Orders where `custom_company` = the production manager's unit and
`custom_po_status` = `PO Approved - Ready for SAP`.

### Production must never see the customer

The floor needs what to make, how much, when, and **where it goes** — not who
bought it. The sales team asked for that boundary explicitly.

Enforce it in the **API layer**, not the view: strip `customer` and
`customer_name` from the record before the screen ever receives it, and restrict
search to order number and route so a hidden field cannot be probed by typing a
customer name into it.

### Stages are per item; the order-level status is a Select

`custom_production_stage` on the item row holds the fine stage
(`Compound Mixing`, `Extrusion`, `Curing`, `Trimming`, `Quality Check`,
`Packed`, `Dispatched` — the sequence differs per family; see
`lib/core/production_stages.dart`).

`custom_production_status` on the **order** is a Select accepting only:

```
Not Started | In Production | Ready | Dispatched
```

**You cannot copy the item stage into it.** Writing `"Curing"` is rejected
outright and the whole save fails. Roll up instead:

- **Ready** / **Dispatched** — decided by the *slowest* line. An order is not
  ready because one of its lines is packed.
- **In Production** — decided by the *fastest*. Once anything has been touched,
  work is under way.
- A stage no longer in the sequence counts as *unknown*, not finished, so
  revising the stage list cannot make an order look done.

The stage names are **placeholders** awaiting the real process document. When it
arrives, only `production_stages.dart` changes.

### Two more production rules

- The **delivery date can be moved** by production — they are who finds out a
  batch will not be ready. The **order creation timestamp cannot**.
- A rep editing an order after approval sets `custom_changed_after_approval`,
  and production must acknowledge it. Work may already have started against the
  old quantities.

---

## 8. Roles and who sees what

Team membership is **not** the Sales Person tree (everyone is under
`Sales Team`). It is:

- `Sales Person.custom_team_manager` — e.g. `Pareeth`
- `User.custom_managed_team` — the same value on the manager's login

A manager's team = every Sales Person whose `custom_team_manager` matches their
`custom_managed_team`. Other flags on User: `custom_is_general_manager`,
`custom_is_hr_manager`, `custom_is_production_manager`,
`custom_production_company`.

`Sales User` has create/write/delete on `Sales Route` and create/write on
`Manna Stock Reservation`.

**Minimum stock is a Manna Treads process.** Hide it entirely for Retreads and
UAE rather than showing an empty list that invites questions about data that
will never arrive.

### Where a decision lives

Order approvals belong in **one place** (the Team Orders view), not also in a
general approvals inbox. Two places to look is two places to miss one — that
shipped, and a lead order sat pending where nobody was looking. Keep
verifications and credit releases in the inbox; keep every order decision
together.

If your dashboard shows pending work per week, count what is outstanding
**across all time** somewhere too, or an order pending from three weeks ago
becomes invisible.

---

## 9. Routes

Route comes from the **`Sales Route`** doctype, never from `Territory`. Fields:
`route_name` (autoname), `sales_person`, `is_active`, `visit_day`,
`description`, `customers`.

Named `Rep - Area` by convention. Customers, leads and captured sites all carry
`custom_sales_route`.

Territory is a sales hierarchy, not a delivery run, and the two had drifted far
enough apart that production was planning trips from the wrong field. **If you
find code reading `territory` for a route, it is a leftover** — three separate
screens still had one months after the migration.

Deleting a route is refused by Frappe while anything points at it. That is
correct behaviour; surface the refusal rather than pre-empting it.

---

## 10. Gotchas that cost time

- **`custom_production_status` is a Select.** See §7. This one fails the whole
  save.
- **`Lead Order Item.amount` is not derived.** ERPNext computes `amount` for
  `Sales Order Item` but not for a custom child table. Send it explicitly or
  every lead order reads as worth zero to whoever sums the lines — while the
  header total looks fine, so it appears correct to the person who entered it.
- **Fetch fields you do not draw.** A screen built from a list row needs every
  field it will *later* read. Lead location capture appeared to fail entirely
  because the list query omitted `custom_location_status` — the data was
  always saved correctly.
- **Creating several Custom Fields on one child table in parallel races
  Frappe** — `IndexError: list index out of range` in its column lookup. Add
  them a few at a time and retry the loser; nothing is corrupted.
- **A non-administrator cannot grant the `All` role** to a custom doctype. Use
  concrete roles.
- **Frappe defaults a new permission row to full write.** Granting read gives
  write unless you explicitly set it back to 0. A settings row the gated user
  can edit is not a gate.
- **`DocPerm` and `Has Role` are not readable** by the integration account, so
  you cannot audit permissions through the API. Use Desk.
- **`GET_COUNT` with operator filters returns nonsense** in some cases (it
  reported more rows in a group than the group contains). Verify counts by
  listing rows.
- **Item UOM:** 157 tread-rubber items are still on `Nos` and should be `Roll`.
  See `server/item_uom_fix.csv` — a Data Import, not API writes.

---

## 11. Not built, and known wrong

Do not assume these exist:

1. **Dispatch.** Nothing moves a booking to `Consumed` or reduces a batch. This
   is the missing half of the stock model, and §4's fallback depends on it
   staying missing.
2. **Product weights.** No Hot Rubber item has a roll weight; solution has no
   pack size. Those families cannot be priced.
3. **Weekly dispatch grouping** and **replenishment / Stock Manager role** —
   specified, never built.
4. **Real process stage names** — placeholders.
5. **Restock has no UI.** Adding a dated batch is a Desk task.
6. **Six items carry invented roll weights** from earlier testing. They are
   load-bearing: zeroing them prices those products at zero.

---

## 12. Suggested reading order in the Flutter source

| File | Why |
| --- | --- |
| `lib/services/stock_service.dart` | The booking protocol, with the reasoning in the header comment |
| `lib/models/min_stock.dart` | Availability, belt ceiling, roll-cutting arithmetic |
| `lib/models/product_category.dart` | The qty/rate identity and the weight fields |
| `lib/core/order_rules.dart` | Edit window, rate lock, approval labels, lead completeness |
| `lib/models/order_ref.dart` | Sales Order vs Lead Order, and the party abstraction |
| `lib/services/api.dart` | Every ERPNext call, including the conversion and roll-up |
| `lib/core/production_stages.dart` | Stage sequences |
| `test/stock_service_test.dart` | An in-memory Frappe that enforces `modified` — the races are real, not mocked |
| `server/SCHEMA.md` | Full field-by-field schema |

The tests are the specification for the stock arithmetic. If you port one thing
faithfully, port those assertions.
