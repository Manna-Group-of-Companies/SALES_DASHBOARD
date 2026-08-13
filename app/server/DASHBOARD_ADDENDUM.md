# Addendum — everything that changed after `DASHBOARD_UI_SPEC.md`

Written 8 Aug 2026. **Read this alongside the other three documents, and where
it contradicts them, this one wins.**

| Document | Still valid? |
|---|---|
| `PWA_HANDOFF.md` | Yes — foundations, unchanged |
| `PWA_HANDOFF_MANAGERS.md` | Mostly — §3.7, §5.5, §11 are superseded below |
| `DASHBOARD_UI_SPEC.md` | Mostly — A2 Block 4a/4b, A3, B2 are superseded below |
| **This file** | Current |

The approval flows are the part that must match the mobile app exactly. They are
set out again in full in §7 so you do not have to reconcile three documents.

---

## 1. New and changed ERPNext schema

Everything below already exists on the live site.

### `Manna Minimum Stock Item` — new fields

| Field | Type | Meaning |
|---|---|---|
| `custom_in_production_qty` | Float | On a production run to refill this pool |
| `custom_in_production_belts` | Int | Same, loose belts |
| `custom_in_production_updated_on` | Datetime | When that figure was set (read-only) |
| `custom_in_production_updated_by` | Data | Who set it (read-only) |
| `custom_reserved_in_production_qty` | Float | Of the run, how much reps have claimed |
| `custom_reserved_in_production_belts` | Int | Same, belts |
| `custom_production_run_stage` | Data | Stage the run is on |

### `Manna Stock Reservation` — new field

| Field | Type | Values |
|---|---|---|
| `custom_source` | Select | `Shelf` (default) · `Production Run` |

### `Sales Order Item` — new field

| Field | Type | Meaning |
|---|---|---|
| `custom_stock_stage` | Data | Stage of the portion served **off the shelf**. `custom_production_stage` is the stage of the portion being **made**. |

`custom_production_stage` now has `allow_on_submit = 1`. It did not, which meant
the floor could not move a stage on any submitted order.

### `Lead Order Item` — new fields

| Field | Type | Meaning |
|---|---|---|
| `custom_price_list_rate` | Currency | The rate the rep quoted, before discount |
| `custom_discount_percentage` | Percent | Discount the sales manager gave |

These mirror the **standard** `price_list_rate` and `discount_percentage` on
`Sales Order Item`, which is what a customer order uses. `Lead Order Item` is
our own child table and has no standard pricing fields, so it needed its own
pair. See §11.

### `custom_fulfilment_mode` — a third value

On **both** `Sales Order` and `Sales Order Item`:

```
(blank)
From Minimum Stock
From Production Run     ← new
New Production
```

---

## 2. The big change: an order can exceed the pool

**Superseded: nothing refuses an order for being larger than the minimum stock.**

An order for 15 rolls against a pool of 10 is an order for 15. Ten come off the
shelf, five are made. Previously this was refused and the rep was told to reduce
the quantity, which was backwards — a customer wanting more than the pool is a
customer worth having.

**The rule:** place the order in full, and cap only the *reservation* at what the
pool can cover.

```
reserved = min(ordered, availableInPool)
toMake   = ordered - reserved
```

A line with nothing left to draw on reserves nothing and is made to order. It
must not fail the order.

**Show the split before it is sent.** The rep sees:

> ⑂ Split: 10 rolls from minimum stock, 5 rolls made to order.

When nothing comes from the pool, say *"This whole line will be made to order"* —
calling that a split would have somebody telling a customer half of it is in
stock.

### The split must be visible to everyone

This was a real bug worth not repeating. `SAL-ORD-2026-00106` is 8 rolls + 2
belts with 4 rolls + 2 belts reserved. The sales manager was shown only
*"booked by this order: 4 rolls + 2 belts"* — nothing said the order was for
eight or that four more had to be made. Production's line said "8 rolls" while
four sat in the plant, so a run raised off that screen would have been for
double.

**Sales manager line must read:**

```
Minimum stock held      10 rolls
Ordered                 8 rolls + 2 belts
Of that, from stock     4 rolls + 2 belts
To be made              4 rolls
Free for anyone else    0 rolls
```

**Production line must read:**

```
⑂ To make: 4  ·  8 ordered, 4 already in stock
```

### How to compute the split

The order line does not carry it — the reservation is a separate record. For
each order, query:

```
Manna Stock Reservation
  where sales_order = <name> and status = "Active"
```

Sum `qty` and `loose_belts` per `item_code`, then per line:
`toMake = custom_rolls - reservedQty`.

If that lookup fails, **show no split** rather than losing the order.

---

## 3. Production: two stage tracks per line

**Supersedes `DASHBOARD_UI_SPEC.md` §B2.**

A split line is two pieces of work finished separately. The shelf half only has
to be picked and packed; the made half runs the full family cycle. Showing the
shelf half against Curing and Extrusion described work nobody was doing.

Render **one track per half**, each with its own quantity, stage and dropdown:

| Half | Shown when | Sequence | Stage field |
|---|---|---|---|
| **From minimum stock** | `reserved > 0` | `Not Started → Packed → Dispatched` | `custom_stock_stage` |
| **To be made** | `toMake > 0` | the family's full cycle | `custom_production_stage` |
| *Progress* (fallback) | split unknown | `stagesForItem` as before | `custom_production_stage` |

Titles carry the quantity, e.g. *"From minimum stock · 4 + 2 belts"*, *"To be
made · 4"*.

### The roll-up now weighs both halves

```
for each line:
    if it has a reserved part:
        weigh(shortCycle,  custom_stock_stage)
        if it also has a made part:
            weigh(familyCycle, custom_production_stage)
    else:
        weigh(stagesForItem(line), custom_production_stage)   # unchanged

allDispatched            → "Dispatched"
all Packed-or-past       → "Ready"
any past Not Started     → "In Production"
otherwise                → "Not Started"
```

Unchanged and still load-bearing: **Ready and Dispatched are decided by the
slowest, started by the fastest, and an unrecognised stage counts as rank 0.**
Errors round **down**.

The case to get right: four rolls dispatched off the shelf while four are still
being made **is not a finished order**.

---

## 4. The minimum-stock pool, and production runs

### 4.1 Production manager's minimum stock screen

A list of every pool, ordered by how badly it needs a run — not by stock age,
which is the rep's ordering.

**Two alarms, and they do not fire together:**

- **Below minimum** — `shelfQty < minimumQty`. A run is owed.
- **Fully booked** — nothing left to promise. This fires *at exactly the
  minimum*, while the quantity still looks right, and it is the one turning
  reps away right now.

Urgency: both (3) → fully booked (2) → below minimum (1) → healthy (0). Within a
band, biggest shortfall first.

**Filters**, each with a live count: **Below minimum** (the default), **Fully
booked**, **Needs a run** (the union), **All**. Plus search, plus quality and
pattern (§4.2).

Per row: minimum to hold, on the shelf, booked by reps, left to sell, then a
movement line (last sold, oldest stock age).

**The shortfall is measured against the shelf, never against what is left to
sell.** Ten on the shelf with eight booked leaves two to sell, but all ten exist
and are waiting to go out — ordering eight more builds the same goods twice.

**No booking attribution.** Production is never told which customer an order is
for and a booking names its Sales Order, so show counts only.

### 4.2 Quality and pattern

Neither is recorded anywhere. There is no quality field, no pattern field,
`brand` is null on all 1,092 items and no Brand records exist. They live only in
the item name:

```
TREAD RUBBER PRECURED  BLACK PEARL  130  VK  90
└─ prefix ───────────┘ └ quality ─┘ └w┘ └p┘
```

**Parse rule:** uppercase, replace anything outside `[A-Z0-9 .'"/-]` with a
space (some names carry mojibake such as `93Â€`), strip the longest matching
prefix from `TREAD RUBBER PRECURED `, `TREAD RUBBER HOT `, `TREAD RUBBER `,
`PRECURED `, `PCTR `. Then find the **first standalone number** — that is the
width. Everything before it is the quality; the token straight after it is the
pattern.

Verified on the whole master: all 164 pools parse; the only 16 misses are
Bonding Gum and Compounded Rubber, which have no pattern.

On the minimum-stock list this yields 35 patterns (VK 20, RTS 19, PM 14, AJAX 12,
SL 10, SR 9, TVS 6, MSR 6, MG 6 …) and two qualities: `BLACK PEARL` (151) and
`BLACK PEARL B` (13), kept distinct.

Hide a dropdown that would offer only one value. A name that does not parse keeps
its row and loses only its place in the dropdown — never filter it out.

### 4.3 Recording a production run

The run is raised in **SAP**, which neither app can see. The production manager
records it here so everyone else knows stock is coming.

Writes `custom_in_production_qty` / `_belts`, stamps `_updated_on` (server clock)
and `_updated_by`. Setting 0 clears it.

**It is intent, not stock.** It never counts towards availability. The shortfall
nets it off, so a pool 20 short with 20 on order stops asking to be ordered
twice: *"Covers the shortfall"* or *"Still 5 rolls short after this run"*.

**Reps see it** — on the minimum-stock detail *and* on the product row inside an
order, which is the screen they are on when a customer asks:

> 🏭 23 rolls being made — not on the shelf yet

Keep it on its own line, never folded in beside "6 available". Two numbers in one
sentence, one sellable and one not, is how a rep promises stock nobody has made.

### 4.4 Claiming out of a run

A rep can claim against the run. **It is a second pool with its own counter and
its own compare-and-swap** — the same protocol as the shelf (see `PWA_HANDOFF.md`
§4), against `custom_reserved_in_production_qty`.

```
availableOnRun = custom_in_production_qty - custom_reserved_in_production_qty
```

**Never add the two pools together.** An empty shelf with a full run still sells
nothing off the shelf. This is the property to guard hardest.

No roll-cutting on a run — nothing has been made, so there is no roll to open.

A claimed line is stamped `custom_fulfilment_mode = "From Production Run"` by the
rep, and its reservation carries `custom_source = "Production Run"`.

### 4.5 The run's stage, and receiving it

**One batch is being made, not one job per order.** The stage lives on the run
(`custom_production_run_stage`); moving it writes that stage down onto
`custom_production_stage` of every order line claimed against it, and re-rolls
each order's status. That keeps every other screen working unchanged.

**"Run received"** when the goods land: in one conditional write, move the
claimed quantities onto the shelf counters, zero the run counters and the run
stage; then re-label those reservations `custom_source = "Shelf"`.

It does **not** create the batch. Receiving stock is a Desk job, and inventing a
batch would put rubber on the shelf nobody counted.

---

## 5. The fulfilment toggle is gone

**Supersedes `DASHBOARD_UI_SPEC.md` §A2 Blocks 4a and 4b entirely.**

Do not build a minimum-stock / new-production chooser. It was the wrong question
to put to a sales manager: two orders wanting more of a product than the pool
holds cannot both be served from it however anybody chooses — the stock belongs
to whoever booked first, because that booking is already holding it. Offering the
choice invited a manager to "switch" a line and quietly take stock off a rep.

**The line now reports what happened**, one read-only row:

| `custom_fulfilment_mode` | Shown as | Colour |
|---|---|---|
| `From Minimum Stock` | Served from minimum stock | blue |
| `From Production Run` | Claimed from a production run — not made yet | `#1A56A8` |
| anything else | Made to order | deep purple |

First booking takes the shelf, a claim takes the run, the rest is made.

---

## 6. Location capture no longer needs a photo or an approval

**Supersedes `DASHBOARD_UI_SPEC.md` §A3 and `PWA_HANDOFF_MANAGERS.md` §3.7.**

Capturing a customer's or a lead's location is **GPS only** and **verifies
itself**. One write:

```json
{ "custom_latitude": <lat>, "custom_longitude": <lng>,
  "custom_verified_latitude": <lat>, "custom_verified_longitude": <lng>,
  "custom_location_status": "Verified",
  "custom_location_captured_by": "<Sales Person>" }
```

**This applies to sales managers only.**

| Who captures | Photo | Status written | Verified coordinates |
|---|---|---|---|
| Sales manager | not asked | `Verified` | written immediately |
| Sales rep | **required** | `Pending Verification` | written by the manager on approval |

A rep's capture still goes to the manager's queue, because the photograph is the
only evidence the coordinates belong to the shop rather than to wherever the
phone happened to be, and it is a manager who says so. Only a manager's own
capture skips both — routing it into their own inbox would ask them to approve
themselves, and the photo exists solely for that check.

Decide this from the role, in one place, so no screen can forget it and quietly
let a rep self-verify.

**The approvals inbox therefore holds four queues:** proforma release, sites,
customer locations, lead locations. Approve writes `Verified` plus the verified
coordinate pair; reject writes `Not Captured` so the rep captures again.

Records still at `Pending Verification` are legacy. Treat them as captured.

**Sites are unchanged** — still a photo, still a manager approval. A site is
somebody asserting new premises exist, not a pin on a shop already on the books.

**The approvals inbox now holds two queues only:** proforma credit release, and
sites.

---

## 7. Approvals, stated in full

This is the part that must not differ between the two applications.

### 7.1 Where each decision lives

| Decision | Where | Never |
|---|---|---|
| Order approval (Sales Order) | **Team Orders only** | not the inbox |
| Lead order approval | **Team Orders only** | not the inbox |
| Proforma credit release | Approvals inbox | |
| Site verification | Approvals inbox | |
| Over-credit-limit orders | **GM queue** | |
| Customer / lead location | **nowhere — self-verifying** | |

### 7.2 Sales manager approving an order

`custom_po_status` values, unchanged:

```
No PO Yet · Pending Approval · Pending Rate Approval ·
PO Uploaded - Pending Approval · Pending GM Approval ·
PO Approved - Ready for SAP · Rejected
```

Show the rep-facing label, never the stored string (mapping in
`DASHBOARD_UI_SPEC.md` §A1).

**Approve** writes:

```json
{ "custom_po_status": "PO Approved - Ready for SAP", "custom_rate_approved": 1 }
```

**and stamps `custom_rate_approved = 1` on every line.** The per-line stamp is the
only way to tell an approved price from one added afterwards.

**Reject:** `{ "custom_po_status": "Rejected", "custom_rate_approved": 0 }`

### 7.3 Escalation is on the customer's credit limit

**Supersedes `PWA_HANDOFF_MANAGERS.md` §3.4.** The rep-outstanding trigger is
removed — different question, and it was dormant anyway.

```
projected = custom_outstanding_balance + orderTotal
escalates = custom_credit_limit > 0 && projected > custom_credit_limit
```

When it escalates, the sales manager's **Approve** becomes **Send to GM**, with:

> This order takes the customer past their credit limit. Approving sends it to
> the General Manager rather than finalising it.

Sending to GM writes `{ "custom_po_status": "Pending GM Approval" }`
(Lead Order: `{ "status": "Pending GM Approval" }`).

**A lead never escalates.** No limit, no trading history — a GM would be deciding
on nothing.

### 7.4 The GM queue

Everything at `Pending GM Approval`. Each card shows the credit picture, which is
the whole reason it arrived:

```
Owes now        ₹1,20,000
This order      ₹  45,000
Would owe       ₹1,65,000
Credit limit    ₹1,50,000
Over by ₹15,000
```

Plus **"Open the order"** — the same full review the sales manager gets.

### 7.5 What the GM may do that nobody else may

Two exemptions, both because the GM is who the other rules escalate *to*. An
escalation arriving with no power to change anything is a rubber stamp.

| Rule | Everyone else | GM |
|---|---|---|
| 1 pm edit deadline | binding | exempt |
| Only the rep or their manager may edit | binding | exempt |
| Rate locked once approved | binding | **exempt** |

So the GM can change lines, quantities, the delivery date, **and the rate** on an
order the sales manager already signed off.

A sales manager must **not** inherit either exemption — they are the one whose
approval set the lock.

### 7.6 Lead order approval — unchanged, restated

Three steps, all required:

1. Convert the Lead to a Customer.
2. Raise a Sales Order from its lines, **already approved** — the manager making
   this decision would make the same one on a Sales Order; sending it back to
   their own queue asks them to approve it twice.
3. Write back: `{ "status": "Approved", "sales_order": "…", "approval_remarks": "…" }`

Blocked until the lead has `custom_gstin`, `custom_address` **and**
`custom_sales_route`. Re-check live at the moment of approval.

Never show a credit verdict for a lead — order total only.

### 7.7 Route is mandatory before an order

An order cannot be *started* for a customer or lead with no `custom_sales_route`.
Checked before the order screen opens and again at creation. Treat `''`, `'   '`,
`null` and the string `'null'` as no route.

**258 of 620 customers currently have no route.**

---

## 11. Per-line discounts at approval

The sales manager can take a percentage off **any line** of an order they are
reviewing. This must behave identically in the web dashboard — a discount is a
price decision, and the two must not disagree about what a customer is charged.

### Where the numbers live

| | Customer order | Lead order |
|---|---|---|
| Rate before discount | `price_list_rate` | `custom_price_list_rate` |
| Discount | `discount_percentage` | `custom_discount_percentage` |
| Net rate charged | `rate` | `rate` |
| Line value | `amount` | `amount` |

`rate` is **always** the net rate the customer pays, and `amount` is
`qty × rate`. On a customer order also write `discount_amount`
(`price_list_rate − rate`) so ERPNext's own recalculation lands on the same net
rate rather than a rounding step away from it.

### The rules

1. **The discount always comes off the rep's original rate**, never off an
   already-discounted one. Read `price_list_rate` first and fall back to `rate`
   only when it is absent. Discounting the discounted rate turns 10% given
   twice into 19%, and once saved the rep's quoted rate is gone for good.
2. **Write all four fields together.** There are no Server Scripts on this
   site and `Lead Order Item` is a custom table nothing calculates, so nothing
   will reconcile them for you.
3. **Round to paise at every step**, not once at the end, or the lines will not
   add up to the total shown beneath them.
4. **Cap: 50%.** Not a costing limit — a guard against a typo, since `100` in a
   percentage box is an order given away. Above that is a GM conversation.
5. **Once the order is approved, no discount can change** — not by the sales
   manager, not by the GM. `custom_rate_approved = 1`, or
   `custom_po_status = "PO Approved - Ready for SAP"` (customer orders), or
   `status ∈ {Approved, PO Approved - Ready for SAP}` (lead orders). Note a
   lead order has **no** `custom_po_status`: checking only that field reads
   every lead order as still open and would let a discount move after approval
   on exactly the orders that then become real ones.
6. **A rep re-editing a pending order must not silently lose the discount.**
   The child table is replaced, not merged, and the rep's editor rebuilds each
   line from the rate per kg they typed. Re-apply the stored *percentage* to
   the incoming line — not the old net rate, which would be a number nobody
   chose if the rep has changed what they quoted.
7. **Converting an approved lead order carries the discount across**, changing
   fields on the way (custom pair → standard pair). Dropped, the customer is
   invoiced the full rate at the exact moment the discount starts to mean
   money.

### What to show

Both totals, never one: **before discount**, **discount**, **after discount**.
The manager is deciding two things at once — whether the customer can carry
this, and what the business is giving away to win it — and a single figure
answers only the first. Keep the full price visible beside the discounted one
on each line too.

**The credit limit is checked against the discounted total**, since that is
what the customer will actually owe. Escalating on the full price would send
orders to the GM over a figure nobody is going to be billed.

Arithmetic and its tests: `lib/core/discount.dart`, `test/discount_test.dart`.

---

## 8. Completion, unchanged

`complete ⟺ custom_production_status == "Dispatched"`. Derived, never stored.
Name the state rather than only ticking it — "Ready" and "In Production" are both
"not complete" and someone chasing an order needs to know which.

---

## 9. Known-wrong, current

- **Dispatch is not built.** Batch quantities change only by hand in Desk, so
  every shelf figure is as fresh as the last manual edit.
- **99 of 164 pools read below minimum**, and 19 read zero on the shelf. Correct
  as to what ERPNext says; whether ERPNext is right is a separate question.
- **`BLACK PEARL 160 RTS 99`** batch `MSB-00030` reads 0 — known bad.
- **Production stage lists are still placeholders.** Hold them as data.
- **Credit limits and outstanding balances are all zero** on all 620 customers,
  so nothing will escalate to the GM until those are populated. Nothing in
  either app writes them.
- `Combined Order.status` is never advanced past `Draft` by the mobile app.
- Team Orders still lists grouped orders individually rather than collapsing
  them the way the rep's list does.

---

## 10. Source of truth

| Concern | File |
|---|---|
| Split arithmetic, order placing | `lib/screens/orders/order_screen.dart` (`_poolShare`) |
| Split display to the rep | `lib/screens/orders/product_row.dart` |
| Pool + run arithmetic | `lib/models/min_stock.dart` |
| Booking, claiming, receiving a run | `lib/services/stock_service.dart` |
| Stage sequences and roll-up | `lib/core/production_stages.dart`, `Api.rollUpStage` |
| Quality/pattern parsing | `lib/core/item_naming.dart` |
| GM exemptions, sign-off checks | `lib/core/order_rules.dart` |
| Per-line discounts | `lib/core/discount.dart`, `Api.setLineDiscount` |
| Production stock screen | `lib/screens/production/production_stock_screen.dart` |
| Two-track stages | `lib/screens/production/production_order_detail_screen.dart` |

The tests state the rules more plainly than the code:
`test/production_run_claim_test.dart`, `test/production_stock_test.dart`,
`test/item_naming_test.dart`, `test/gm_rules_test.dart`,
`test/production_stages_test.dart`, `test/widget_test.dart`,
`test/discount_test.dart`.
