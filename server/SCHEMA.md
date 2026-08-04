# ERPNext schema for Phase 1 — order taking

**Status: built on the live site** (`mannarubber.m.frappe.cloud`) on 31 Jul 2026
via the `integration@mannarubber.com` account. This file records what exists,
not what someone still has to create — except for the two open items at the
bottom, which do need you.

## 0. Read this first — no server scripts

The site's plan does not run Frappe Server Scripts. The seven that were
installed have been **disabled** and their source removed from this repo; every
rule they held now lives in the app. See [README.md](README.md) for what that
costs and how the oversell race is closed without them.

`trip_single_active` is still on the site and still disabled at the platform
level — it has never run.

## 1. Item groups

The order screen picks a rep's row from the Item's `item_group`. Matching is
case-insensitive, and any other group still sells through a plain
quantity-and-rate row.

| Item Group | Status | Row the rep gets |
| --- | --- | --- |
| `Precured` | already existed, 130 items | rolls + loose belts, average weight |
| `Hot Rubber` | already existed, 88 items | rolls only, exact weight |
| `Bonding Gum` | **created** | boxes + loose rolls, fixed 5 kg steps |
| `Vulcanizing Solution` | **created** | number of cans |

`Precured` and `Hot Rubber` are PCTR and CTR under the names your item master
already uses. Renaming them would have meant re-tagging 218 live items to gain
nothing, so [lib/core/constants.dart](../lib/core/constants.dart) points at the
real names instead.

## 2. Units, and why `qty` is not kilograms

A `Roll` UOM was **created** and is the stock UOM for tread rubber.

Tread rubber is counted in rolls but *priced* by the kilogram. ERPNext has one
`qty` and one `rate` and multiplies them, so both cannot be stored as typed.
What is stored:

```
qty   = rolls                        (fractional when loose belts are involved)
rate  = ratePerKg x weightPerRoll    (so qty x rate is the real amount)

custom_rate_per_kg   = what the rep actually quoted
custom_total_weight  = the kilograms the customer is billed on
```

A loose belt is a known fraction of a roll, so 2 rolls + 3 belts on a 4-belt
roll is `qty = 2.75`, and the amount comes out identical to pricing those belts
by weight. The `Roll` UOM is deliberately **not** whole-number-only for this
reason. Bonding gum stays in kilograms and solution in tins, where the rep's
rate already matches the quantity unit.

## 3. Custom fields on `Item` — created

| Fieldname | Type | Used by | Meaning |
| --- | --- | --- | --- |
| `custom_avg_weight_per_roll` | Float(3) | PCTR | Average kg a roll weighs. |
| `custom_belts_per_roll` | Int | PCTR | Belts per roll. |
| `custom_weight_per_roll` | Float(3) | CTR | Exact kg a roll weighs. |
| `custom_pack_litres` | Float(2) | Solution | Tin size, 10 or 30. |

**These are empty and are yours to fill.** A PCTR item with no average weight or
belt count, or a CTR item with no roll weight, is shown to the rep as
misconfigured rather than silently priced at zero.

## 4. Custom fields on `Customer` — created

| Fieldname | Type | Meaning |
| --- | --- | --- |
| `custom_gstin` | Data | Customer GSTIN. Empty everywhere today. |
| `custom_billing_address` | Small Text | Print-specific override. |
| `custom_state` | Data | Place-of-supply line. |

The proforma reads `custom_billing_address`, then falls back to the existing
**`custom_address`**, which is already populated on most customers — so
addresses print today without any import.

## 5. Custom fields on `Sales Order` — created

| Fieldname | Type | Meaning |
| --- | --- | --- |
| `custom_proforma_required` | Check, default 1 | Clear means the order went for approval without a proforma. |
| `custom_order_placed_at` | Datetime, read-only | When the order was raised. Audit trail. |
| `custom_rate_approved` | Check | Set when the manager approves. Order-level marker that rates are final. |
| `custom_fulfilment_mode` | Select | Blank / `From Minimum Stock` / `New Production`. The manager's priority call. |

And on **`Sales Order Item`**:

| Fieldname | Type | Meaning |
| --- | --- | --- |
| `custom_rate_approved` | Check | This line's price is final. Locked for everyone, permanently. |

Rate finalisation is **per line**, not per order. That is what lets a rep add a
product to an approved order and price it, while every rate the manager already
signed off stays frozen — including for the manager. Nothing in the app clears
a line's flag once set; rejecting an order does not clear it either, because a
rejection is not a finalisation and the flag is only ever set on approval.

`custom_fulfilment_mode` is a priority decision, not a logistics one: an
important customer is served out of minimum stock and gets their order sooner,
everyone else waits for a run. Choosing **New Production** also **releases the
order's minimum-stock bookings**, since the order will not draw on the pool and
leaving stock held against it would starve whoever needs it next.

`custom_proforma_status` already existed; `Not Required` was **appended**.

`custom_po_status` was relabelled **Approval Status**, its default changed to
`Pending Approval`, and two values appended:

```
No PO Yet
Pending Approval            <- new, and the default
Pending Rate Approval       <- new
PO Uploaded - Pending Approval
Pending GM Approval
PO Approved - Ready for SAP
Rejected
```

**The stored values were not renamed.** `PO Approved - Ready for SAP` is what
the production dashboard, `getMonthSales` and every existing record key off, so
it stays; only the label reps see changed. `approvalLabel()` in
[lib/core/order_rules.dart](../lib/core/order_rules.dart) does that mapping, and
a test asserts no PO wording leaks to a rep.

### The order lifecycle now

Reps no longer scan a signed purchase order — that step and its camera flow are
gone. An order goes straight into the manager's queue when it is raised.

```
raised ──> Pending Approval ──> manager approves ──> PO Approved - Ready for SAP
                 │                                    + custom_rate_approved = 1
                 │                                      (rates lock on the phone)
                 └── rep adds a product after approval
                        └──> Pending Rate Approval  (rates unlock for that line)
```

**Editing window:** everything about an order — products added, removed,
requantified — stays open until **1 pm on the required delivery date**, for the
rep who raised it and for their manager. After that it is frozen. The rule is
in [lib/core/order_rules.dart](../lib/core/order_rules.dart) and is judged
against the server's clock.

Note this is enforced in the app only. Without server scripts nothing re-checks
the deadline on write, so it stops an honest mistake, not a determined one.

Two consequences worth knowing:

- A rep can move the **required delivery date** forward, which moves their own
  deadline with it. That is a real loophole, but changing the date is also a
  legitimate customer request, and the manager sees the order either way.
- Editing an order **adjusts its minimum-stock bookings by difference** rather
  than releasing and re-taking them — otherwise a rep changing one line would
  put the rest of their stock back on offer and could lose it mid-edit.

### `custom_avg_weight_per_roll` is the weight of a **belt**

The field name is wrong and the app corrects for it. Two rows from the master
settle it beyond doubt:

| Item | `custom_avg_weight_per_roll` | `custom_belts_per_roll` | `custom_weight_per_roll` |
| --- | --- | --- | --- |
| TREAD RUBBER 174 MLG 120 ''LW | 10.1 | 4 | **40.4** |
| ...BLACK PEARL 102 AJAX 60 | 2.4 | 14 | **33.6** |

`field x belts = roll weight` in both. So `custom_avg_weight_per_roll` holds the
per-belt weight and `custom_weight_per_roll` holds the per-roll weight — for
PCTR **and** CTR, which now read the same field.

Read as a roll weight, it priced a whole roll at one belt's worth: a 40.4 kg
roll quoted at 10.1 kg, about a quarter of the money.

The name is left alone on the backend because every import sheet already uses
it. `Product.weightPerBelt` / `Product.weightPerRoll` in
[lib/models/product_category.dart](../lib/models/product_category.dart) are the
only place the correction lives, and each derives the other from the belt count
when only one is filled in.

## 6. Custom fields on `Sales Order Item` — created

| Fieldname | Type | Meaning |
| --- | --- | --- |
| `custom_product_category` | Data | `PCTR` / `CTR` / `Bonding Gum` / `Vulcanizing Solution`. |
| `custom_rolls` | Int | Whole rolls. |
| `custom_loose_belts` | Int | PCTR only. |
| `custom_boxes` | Int | Bonding gum only. |
| `custom_cans` | Int | Solution only. |
| `custom_total_weight` | Float(3) | Derived kg. Zero for solution. |
| `custom_rate_per_kg` | Currency | What the rep quoted. |
| `custom_packing_note` | Small Text | "12 rolls + 3 loose belts · 274.50 kg (avg)". |
| `custom_aged_batch` | Link → Manna Minimum Stock Batch | Pins a line to one batch. **Nothing sets this** — see below. |

### Old stock is a sales prompt, not a substitution

An earlier version let a rep pick an older batch and asked them to confirm the
swap with the customer. That was wrong. The oldest stock of a product goes out
first regardless — the drawdown is oldest-first — and the shelf life is long
enough that age is not a quality question anyone needs to agree to.

Ages are surfaced for a different reason: stock that has been sitting is stock
to **push harder in the market** before it becomes dead. So the app ranks and
highlights it and offers nothing to decide. `custom_aged_batch` and the
batch-pinning path in `StockService` remain because the reservation model
supports them, but no screen writes to them.

## 7. New doctypes — created

Named with a `Manna` prefix because ERPNext ships its own `Stock Reservation
Entry`, and two things called "Stock Reservation" in one Desk is a trap.

### `Manna Minimum Stock Item` — the pool

`item_code` (Link Item, autoname `field:item_code`), `qty` (Float — rolls, kg or
cans depending on the family), `loose_belts` (Int, PCTR only), `disabled`
(Check).

An Item with no row here reads as "No minimum stock", which is deliberately
different from "none left".

### The batches are the stock record; `qty` is only the threshold

`Manna Minimum Stock Item.qty` is the **minimum to keep on the shelf** and
nothing else. Availability — on screen and in the booking guard — is summed
from the open batch rows.

That follows from how restocking already works: it **adds a batch row** and
never edits the pool upward, so the two diverge the moment stock arrives.
Reading availability off the pool pinned it near the minimum while the batch
list showed the real, larger figure.

Three numbers, three questions:

| Shown as | Source | Answers |
| --- | --- | --- |
| Minimum stock | pool `qty` | what *should* be here |
| Actual stock | sum of batches | what *is* here, undispatched |
| Available to sell | batches − `custom_reserved_qty` | what can be promised |

**A booking does not touch the batches.** Booked stock is still on the floor
until it ships, so "actual stock" means *not yet dispatched* — which is the
figure a rep quotes when asking the manager to have some of it reallocated to
them. Only availability moves when somebody books.

That is why the booking guard subtracts `custom_reserved_qty` itself. It used to
get that subtraction for free because batches were drawn down at booking time;
they are not any more, and a test pins that a second order cannot take what the
first one booked.

**An item with no batch rows falls back to `qty − reserved`.** A threshold
declared with no stock recorded is not the same as "none left", and reading it
as zero would take every un-batched item off the market overnight. The fallback
is the lower number, so it can only ever be cautious.

**Dispatch is not built.** Nothing in the app reduces a batch, so today `Actual
stock` falls only when the office edits the batch rows in Desk. That is the
missing half of this model and it is the next thing worth building — see the
open list.

### Belts are cut from whole rolls

A rep can book belts with no loose ones on the shelf, provided there is a roll
to cut: the belt ceiling is `loose + (rolls × belts_per_roll)`, and any roll
needed for belts counts against the roll headroom. So an order for two rolls
plus one belt needs **three** rolls available and is refused with two.

The pack size is `custom_belts_per_roll` on the Item, read only when a belt
order actually needs a roll opened. An item without it set cannot have belts cut
and the order is refused with that reason, rather than a pack size being guessed.

**Nothing is actually cut at booking time.** The roll is opened when the order
is dispatched, which is also when the remainder — nine belts from a twelve-belt
roll on a three-belt order — becomes loose stock. Since dispatch is not built,
that step is currently manual.

### `Manna Minimum Stock Batch` — the aging list

`item_code`, `batch_date` (Date), `qty`, `loose_belts`, `original_qty`,
`original_loose_belts`. Naming `MSB-.#####`.

Restocking **adds a row**; it does not edit `qty` upward. That is what makes
"8 of the original 10 from March, plus 2 restocked last week" two rows rather
than one number.

### `Manna Stock Reservation` — one booking

`item_code`, `qty`, `loose_belts`, `sales_order`, `sales_person`, `batch`
(Link → batch), `status` (`Active`/`Released`/`Consumed`, default `Active`),
`reserved_on`. Naming `MSR-.#####`.

Only `Active` rows count against a pool. Releasing sets the status rather than
deleting, so a stranded booking leaves a trail. Sales User has create+write.

Rolls and belts are checked **independently**. Nothing cuts a whole roll into
belts to cover a belt shortfall — whether that is allowed is a shop-floor
decision, not one for a script. Say the word if it should.

## 8. Server scripts — all disabled

Seven were installed and are now disabled; the plan cannot run them. They are
left in place rather than deleted so there is a record of what they did, and so
they can be re-enabled unchanged if scripting ever comes back. Nothing in the
app calls them.

| Name | Replaced by |
| --- | --- |
| `manna_stock_reservation_rules` | `StockService.book` compare-and-swap |
| `manna_sales_order_timestamp` | `Api.createSalesOrder` writing `nowStamp()` |
| `manna_place_order` | `Api.placeOrder` — create, book, unwind on refusal |
| `manna_minimum_stock` | `StockService.load` |
| `manna_reserve_min_stock` | `StockService.book` |
| `manna_release_reservations` | `StockService.release` |
| `manna_aging_stock` | `Api.getAgingStock`, sorted client-side |

## 8a. Business units on `Item` — created

| Fieldname | Type | Meaning |
| --- | --- | --- |
| `custom_units` | Small Text | Pipe-wrapped list of units that sell this item, e.g. `\|Manna Treads\|Manna Tyres UAE\|` |

Matches the convention `Customer.custom_assigned_reps` already uses. **Empty
means every unit sees the item**, which is the state all 218 existing items are
in — so an incomplete import degrades to the old behaviour rather than to an
empty product list.

The unit a rep belongs to is `Sales Person.custom_company`, which the app
already reads into `Session.I.company`. The valid values are the three options
on `Sales Order.custom_company`: **Manna Tyre Retreads**, **Manna Treads**,
**Manna Tyres UAE**. Note these are business units, not ERPNext Companies — the
Company doctype only has *Manna Rubber Products Private Limited* and *Manna
Rubber UAE*.

## 8b. Dead-stock tracking on `Manna Minimum Stock Item` — created

| Fieldname | Type | Meaning |
| --- | --- | --- |
| `custom_reserved_qty` | Float(3) | Running total booked by all reps. Machine-owned — do not hand-edit while reps are ordering. |
| `custom_reserved_loose_belts` | Int | Same, for belts. |
| `custom_last_sold_on` | Date | Last time the item went on an order. |

The minimum-stock list is a **high-demand, high-lead-time** list — items
management wants permanently on the shelf. It is not a list of old stock. What
needs watching is an item on that list that has *stopped* selling, because the
rule that put it there will keep stock sitting against its name until someone
notices. `custom_last_sold_on` is what the app measures that from; the
thresholds are `kSlowMovingDays` (60) and `kDeadStockDays` (120) in
[lib/core/constants.dart](../lib/core/constants.dart).

## 8c. `Manna App Settings` — created

A Single doctype holding `minimum_app_version` (Data) and `update_message`
(Small Text). The app reads it at sign-in and refuses to go further on a build
older than the minimum — see [lib/core/app_version.dart](../lib/core/app_version.dart)
for why that gate exists and what it cannot do.

Set to `1.1.0`, the first build that carries the check. Permissions are
deliberately lopsided: System Manager writes, Sales User / Sales Manager /
Employee only read. Frappe defaults new roles to full write, so those three
were explicitly set back to read-only — a version gate the reps being gated can
switch off is not a gate.

Clearing `minimum_app_version` turns the gate off entirely. That is the intended
escape hatch if a bad minimum ever locks the field team out.

## 8e. Leads order exactly as customers do — created

`Lead Order Item` gained the same per-family fields `Sales Order Item` has:
`custom_product_category`, `custom_rolls`, `custom_loose_belts`, `custom_boxes`,
`custom_cans`, `custom_total_weight`, `custom_rate_per_kg`,
`custom_packing_note`, `custom_rate_approved`, `custom_fulfilment_mode`
(Select: blank / `From Minimum Stock` / `New Production`) and
`custom_aged_batch`.

`Lead Order` gained `delivery_date`, `custom_order_placed_at` (read-only) and
`custom_rate_approved`.

`Manna Stock Reservation` gained `lead_order` (Link → Lead Order).
**Exactly one of `sales_order` / `lead_order` is set on any row.** The two are
separate doctypes so one Link field could not serve both; `OrderRef` in
[lib/models/order_ref.dart](../lib/models/order_ref.dart) is what stops that
choice being re-derived at each call site.

### Approval moves the bookings, it does not re-take them

When a lead order is approved the lead converts, a Sales Order is raised, and
the live reservations are **re-pointed** from `lead_order` to `sales_order`.
The pool counters are not touched at all.

Releasing and re-booking would be the obvious implementation and it is wrong:
handing the stock back even for an instant puts it on offer, and a customer
could lose at the exact moment of approval the rolls they were promised days
ago. There is a test pinning that the pool sees zero writes during a move.

### One field-creation gotcha

Creating several Custom Fields on the same child table in parallel makes Frappe
race itself — an `IndexError: list index out of range` in its column lookup.
Add them a few at a time and retry the loser; nothing is corrupted, the field
simply is not created.

## 8d. `sales_order` on `Lead Order` — created

Link → Sales Order, read-only. Approving a lead order now raises a real Sales
Order, because the production dashboard reads Sales Orders and nothing else;
before this an approved lead order was a dead end that never reached the floor.
This field records which order it became.

## 9. What is still open

1. **Finish the UOM migration.** 218 tread-rubber items: 50 were already on
   `Roll`, 11 were corrected by API, and **157 are still on `Nos`**.
   [server/item_uom_fix.csv](item_uom_fix.csv) covers all 168 that needed it and
   is safe to re-run — Data Import > Item > Update Existing Records. Doing it by
   API is possible but pointless: each write returns the whole item document,
   and there are 157 of them.

   These are all `is_stock_item: 0`, which is why the UOM change is allowed at
   all — Frappe refuses it once an item has stock ledger entries.

2. **Product data.** `custom_avg_weight_per_roll` + `custom_belts_per_roll` for
   PCTR, `custom_weight_per_roll` for CTR, `custom_pack_litres` for solution,
   `custom_units` for every item, and the Bonding Gum and Vulcanizing Solution
   items themselves, which do not exist yet — both groups are empty.

4. **Fabricated data still in place, and it is load-bearing.** Six real items
   carry **invented** weights — 120 IR 66 (22.5 kg / 4 belts), 124 ZT 67 (24.8 /
   4), 130 AJAX 99 (31.2 / 5), 145 DR 87 (28.4 / 4), PLATINUM 120 AJAX 69 (21.6 /
   4), PLATINUM 150 SL 96 (33.5 / 5) — alongside 12 `Manna Minimum Stock Item`
   rows, 14 batches (`MSB-00001`–`MSB-00014`) and 12 reservations
   (`MSR-00001`–`MSR-00012`, all against test order `SAL-ORD-2026-00096`).

   The weights cannot simply be zeroed. A PCTR line prices as
   `ratePerKg × rollWeight`, so an item with weight 0 prices at **zero** — the
   fabricated numbers are wrong, but deleting them without replacing them is
   worse than leaving them. Replace them with the real weights in the same
   product import as item 2; the pools, batches and reservations can go
   independently once minimum stock is loaded with real figures.

5. **Consuming a reservation.** Nothing moves a booking from `Active` to
   `Consumed` on delivery, because delivery is not in Phase 1.

6. **Restock entry.** Adding a dated batch is a Desk task; there is no app
   screen for it.
