# Sales Manager & Production Manager dashboards — screen-by-screen spec

What to build, screen by screen: every field shown, every control, when each
control is live and when it is dead, and what each one writes.

Companion documents:
- `PWA_HANDOFF.md` — foundations: auth, products, weights, minimum stock, the
  booking compare-and-swap.
- `PWA_HANDOFF_MANAGERS.md` — the data model and business rules behind all of
  this, with field names and allowed values.

**This document is the interface.** Where it says a control is hidden, hide it —
do not disable it and leave it visible unless it says so.

Current to commit `HEAD` on branch `dev`, 7 Aug 2026.

---

## The rule that governs the whole build

**There are no Server Scripts.** ERPNext will not stop you writing a state the
mobile app would have refused. Every gate below has to exist in your dashboard
too, or a manager will do something on the web that the phone would have
prevented, and the two will disagree about the same order.

---

# PART A — SALES MANAGER

Four screens. Orders are decided in **one** of them and nowhere else.

---

## A1. Team Orders — the order list

**This is the only place an order is approved.** It must not appear in the
approvals inbox. Approving fixes a price permanently, commits stock, and for a
lead converts the party — that decision needs the lines, the stock position and
the credit picture in front of it, which an inbox row cannot carry.

### Data

`GET /api/resource/Sales Order` filtered by:
- `custom_sales_person in <team>` — the reps reporting to this manager
- `transaction_date` between the selected week's Monday and Sunday

Plus `Lead Order` on the same date range with `sales_person in <team>`, mapped
onto the same shape (`lead_name` → customer, `order_date` → transaction_date,
`total_amount` → grand_total, `status` → the status field).

Fields to request:
```
name, customer, custom_sales_person, grand_total, transaction_date,
delivery_date, custom_po_status, custom_rate_approved,
custom_production_status, custom_production_finish_date,
custom_proforma_status, custom_combined_order
```

### Controls

| Control | Behaviour |
|---|---|
| Week selector | This week and the 12 before it. Each entry is a Monday→Sunday pair. **Build the list from the server clock**, not the browser's. |
| Refresh | Reload the list |

### Header line above the list

`"{n} orders · {w} waiting on you"` when any are undecided, otherwise
`"{n} orders · all decided"`. Orange when waiting, green when not.

"Waiting" means `custom_po_status != "PO Approved - Ready for SAP"`.

### Each order row

Top line: **customer name**, a `LEAD` chip if it is a lead order, and the
amount right-aligned.

Second line, small grey: `{order id} · {rep} · {transaction_date}`

Third line: a status pill. Text is the **rep-facing label**, uppercased — never
the raw stored value:

| Stored `custom_po_status` | Pill text | Colour |
|---|---|---|
| `PO Approved - Ready for SAP` | APPROVED | green |
| `Pending Approval`, `PO Uploaded - Pending Approval` | WAITING FOR MANAGER APPROVAL | orange |
| `Pending Rate Approval` | WAITING FOR RATE APPROVAL | orange |
| `Pending GM Approval` | ESCALATED TO GM | orange |
| `Rejected` | REJECTED | red |
| `No PO Yet`, empty, null | NOT SENT FOR APPROVAL | orange |

Right of the pill, when undecided: the words "Tap to review" (or your web
equivalent).

**Production line — only when the order is approved.** Before approval,
production has never seen the order and the line must not appear at all.

- If `custom_production_status == "Dispatched"` → green, bold, with a ticked
  checkbox: **"Order complete — dispatched"**
- Otherwise → grey with a factory icon:
  `"Production: {status or 'Not started'}"`, plus
  `" · est. finish {custom_production_finish_date}"` when that is set.

Do **not** write "Production: Dispatched". A finished order is said plainly;
everything short of finished keeps its stage name, because "not complete" is
nothing to chase with.

**Combined order line — only when `custom_combined_order` is set:**
brown, with a merge icon: `"Week order: {COMB-xxxxx}"`.

Treat `''`, `'   '`, `null` and the string `'null'` all as not set.

### Clicking a row

Opens A2. Reload the list if a decision was made.

---

## A2. Order review — where the decision is made

The most important screen in the app. Everything the approval decision rests on,
in this order, top to bottom. **Keep the order** — each block is placed where it
is for a reason given below.

### Data

- The order (`Sales Order` or `Lead Order`, full document with `items`)
- The party (`Customer` or `Lead`, full document)
- Minimum stock (all `Manna Minimum Stock Item` + batches + reservations)
- The item master, for packing figures

### Block 1 — Header

- Party name, large and bold. For a lead: `company_name`, falling back to
  `lead_name`. A `Lead` chip beside it.
- `"Raised by {rep} · delivery {delivery_date}"`
- The status label (same mapping as A1), green when approved, orange otherwise.

### Block 2 — "Cannot approve yet" (leads only, conditional)

Shown **only** for a lead order missing any of `custom_gstin`,
`custom_address`, `custom_sales_route`. Red card, at the top, **above the credit
card and the lines**, because it is the one thing that will stop the approval
and the manager should see it before they have read the lines and made up their
mind.

> **Cannot approve yet**
> This lead becomes a customer on approval and is invoiced from there, so it
> needs: *GST number, Address, Sales route*.
> Ask the rep to add them on the lead, or edit the lead yourself.

While this card is showing, **Approve must refuse**. Re-check against the live
lead at the moment of approval, not against whatever the page was loaded with.

### Block 3 — Credit

**For a customer:**

- `outstanding = custom_outstanding_balance`
- `orderTotal = Σ line amounts`
- `projected = outstanding + orderTotal`
- Over limit when `custom_credit_limit > 0 && projected > custom_credit_limit`

Show: "Within credit limit" (green) or "Over credit limit" (red), then
outstanding, order total, projected, and the limit.

If the customer has **no limit set**, do not show a green tick. Say:
*"New party — no trading history or credit limit to check against."*

**For a lead — never show a credit verdict.** A lead has no trading history and
no limit, so there is nothing to be within. A green "Within credit limit"
against a party who has never been invoiced is a reassurance nobody earned, and
a manager may read it as a check that passed rather than one that was never run.
Show the **order total alone**, in a neutral grey box.

### Block 4 — Lines

Heading `Lines`, then the sub-heading:

> Choose per line whether it comes out of minimum stock or waits for a
> production run. Changes take effect immediately.

Per line, show:

- Item name, and the packing note (`custom_packing_note`)
- Quantity in the family's units (rolls / loose belts / boxes / tins) and the
  derived weight
- Rate, and the line amount
- **Minimum-stock position** for that item:
  - what *this order* is holding — `Σ reservations where sales_order == this`
  - what **other** orders are holding — `reservedQty − heldHere`. Without this
    split the manager reads "1 booked" with no way to tell whether it is
    somebody else competing for the stock or the very order in front of them.
  - what is available
  - if older stock of the same item exists, an amber note:
    *"in stock {n} days (since {date})"*

**Line amount fallback:** if `amount` is missing or zero, use `qty × rate`. Lead
order lines written before the app started sending `amount` have it as zero —
nothing on a custom child table derives it — and a manager must never be shown a
nil order against rates the rep entered correctly.

#### Block 4a — the fulfilment toggle (per line)

Two chips: **Minimum stock** / **New production**. One is selected.

**Which is selected when nothing is stored:** the rep's own booking is the
status quo. If this order holds any of that item (qty or belts), it reads
`From Minimum Stock`; otherwise `New Production`.

Clicking a chip writes immediately (no save button) and reloads.

- → Minimum stock: books the line against the pool. Toast:
  *"Booked against minimum stock."*
- → New production: **releases** whatever the line was holding, so the pool
  goes back to whoever needs it sooner. Toast:
  *"Released — this line waits for production."*

Under the chips, while they are live, in small grey text:

> Fixed once you approve this order.

Said **before** the decision. A manager who only learns the choice was final
once it is final has been told nothing useful.

#### Block 4b — when the toggle is locked

Replace both chips with a padlock icon and one grey line:

> Served from **{minimum stock | new production}** — {reason}.

Check the reasons in this order and use the first that matches:

| # | Condition | Reason text |
|---|---|---|
| 1 | line's `custom_production_stage == "Dispatched"` | `this line has been dispatched` |
| 2 | order `custom_production_status == "Dispatched"` | `the order is complete` |
| 3 | `custom_po_status == "PO Approved - Ready for SAP"` | `the order is approved and production is working to it` |
| 4 | past 13:00 on `delivery_date` | `changes closed at 1 pm on the delivery date` |

**Approval is the real lock.** Where a line is served from only matters at the
moment production receives the order, and that moment is approval. The other
three are backstops for states that should not be reachable without it — each
would otherwise mean releasing a reservation against goods the floor has already
acted on, at worst stock that is physically on a van.

**An edited order reopens the choice.** When a rep edits an approved order the
status returns to pending, and the toggle becomes live again. That is correct:
the manager is approving it afresh and the lines may not be the ones they
originally decided on.

Your API call must refuse a locked change too, judged against the order **as
stored**, not as the page last saw it.

### Block 5 — Order total

Right-aligned, bold: `Order total    Rs {total}`

### Block 6 — Edit the line-up

If editing is open (see the 1 pm rule below): a button
**"Add / Remove / Requantify"**.

If closed: no button, just the reason in grey — e.g.
*"Changes closed at 1 pm on 08/08/2026, the required delivery date."* or
*"Only {rep} or their manager can change this order."*

**The 1 pm rule.** An order freezes at **13:00 on its `delivery_date`**.

- No delivery date → **permanently open**, not shut. An order without a date is
  a data problem and refusing to let anyone fix it makes it worse.
- Judged against the **server clock** (`Date` HTTP response header), never the
  browser's.
- Who may edit before then: the rep who raised it, **or** their manager. A
  manager needs it because a customer who rings the office should not have to
  wait for their rep to come back into signal.

### Block 7 — The decision

**If already approved**, show only a green panel:

> ✓ Approved. Rates on this order are final.

No buttons.

**If not yet approved:**

- If this approval escalates (rep over their outstanding limit), an amber
  warning first:
  > The rep is over their outstanding limit. Approving sends this to the
  > General Manager rather than finalising it.
- Grey line: *"Approving fixes every rate on this order permanently."*
- Two buttons side by side: **Approve** (or **Send to GM** when escalating) and
  **Reject**.

#### What Approve writes — Sales Order

```json
{ "custom_po_status": "PO Approved - Ready for SAP",
  "custom_rate_approved": 1 }
```

**And stamps `custom_rate_approved = 1` on every line.** The per-line stamp is
the only way the app can later tell an approved price from one the rep typed
afterwards. Do not skip it.

#### What Reject writes

```json
{ "custom_po_status": "Rejected", "custom_rate_approved": 0 }
```

#### What Send to GM writes

```json
{ "custom_po_status": "Pending GM Approval" }
```

Lead Order equivalent: `{ "status": "Pending GM Approval" }`.

#### What Approve does for a **lead order** — three steps

1. **Convert the Lead to a Customer.**
2. **Raise a Sales Order** from the lead order's lines against the new customer,
   created **already approved** — the manager approving the lead order is making
   the same decision they would make on a Sales Order, and sending it back to
   their own queue would ask them to approve the same order twice.
3. **Write back** to the Lead Order:
   ```json
   { "status": "Approved",
     "sales_order": "SAL-ORD-…",
     "approval_remarks": "Converted to customer X, raised as Y" }
   ```

Reject is just `{ "status": "Rejected" }` — no conversion.

Note: a lead order carries no roll/belt breakdown and no bookings
(`Lead Order Item` holds only `item_code`, `qty`, `rate`), so the Sales Order it
raises always reads as **new production**.

---

## A3. Approvals inbox

**Everything the manager owes a decision on except orders.** Two queues in one
list. Two places to look was two places to miss one — so orders are *not* here,
and these two are *only* here.

| Card title | Source | Filter |
|---|---|---|
| Proforma credit release | `Sales Order` | `custom_proforma_status = "Pending Release Approval"`, team |
| Site: {site name} ({owner}) | `Customer Site` | pending, team |

Each card carries: title, document id, the rep, the party, an amount (proforma
only), and for a site **the captured photo and a map link** to the coordinates.
The manager is verifying that a photograph matches a place — they need both.

### Customer and lead locations are NOT approved

They used to be, and were removed. Capturing a location no longer takes a photo,
so there is nothing for a manager to judge — and a queue nobody can act on is
worse than no queue: the record sits `Pending Verification` for ever and the
verified coordinates are never written.

**A capture now verifies itself.** One write, both pairs of coordinates:

```json
{ "custom_latitude": <lat>, "custom_longitude": <lng>,
  "custom_verified_latitude": <lat>, "custom_verified_longitude": <lng>,
  "custom_location_status": "Verified",
  "custom_location_captured_by": "<Sales Person>" }
```

Do not build a location-verification queue in the dashboard. Do not require a
photo to capture a location.

Records still sitting at `Pending Verification` are legacy — from when a manager
did check them. Treat them as captured; nothing will move them on.

For a site card, the owner is the customer if set, otherwise the lead. Heading
the card with a blank customer tells the manager nothing about what they are
approving.

### Actions

| Type | Approve writes | Reject writes |
|---|---|---|
| `proforma` | `custom_proforma_status: "Released"` | `custom_proforma_status: "Blocked - Credit"` |
| `site` | verified + verified coordinates | back to not captured |

Rejecting a site must set its status back to not-captured so the rep captures
again.

---

## A4. Combined orders (weekly)

The sales manager sees, but does not create, combined orders. Creation is the
production manager's job (B3).

Read `Combined Order`, and its contents via
`Sales Order` where `custom_combined_order = {name}`.

**Two display rules:**

- **Never list a group and its members side by side.** The same money would be
  counted once in the group and again underneath it.
- **Take the totals from the `Combined Order` header**, not from the members you
  happen to have loaded. A customer served by two reps in one week should show
  the whole week to both, not each rep's share.
- If a header cannot be read, **leave its orders showing individually**. A user
  seeing an order ungrouped is a worse list; a user seeing neither has lost work
  off their screen.

A group row shows: customer, `{week_start} to {week_end}`, `{n} orders
combined`, total. Opening it lists each Sales Order with its date, rep, amount
and completion tick, each openable in full.

---

# PART B — PRODUCTION MANAGER

---

## B0. The rule that overrides everything on these screens

**Production must never see the customer.**

The API resolves customer → route server-side and then **deletes** the customer
field before the payload reaches the screen. `getOrderForProduction` also strips
`customer_name` and `company_address_display`.

Do not send customer identity to the production dashboard and hide it in CSS.
The search box must match **only the order number and the route** — a search
that quietly matched a hidden field would let someone confirm a customer by
guessing.

---

## B1. Production dashboard — the queue

### Data

`Sales Order` where:
- `custom_company = <this production unit>`
- `custom_po_status = "PO Approved - Ready for SAP"`

Fields: `name, grand_total, transaction_date, delivery_date,
custom_sales_person, custom_production_status, custom_production_finish_date,
custom_changed_after_approval` — then resolve each order's customer to a route
and drop the customer.

### Each row

- **Title: the route** (`destination`), or the literal `"No route set"`.
  Not the customer. Not the territory — see below.
- Icon: red priority icon when `custom_changed_after_approval == 1`, otherwise a
  receipt icon.
- A red **CHANGED** chip when `custom_changed_after_approval == 1`. Surface this
  prominently: it means the floor may be building the wrong thing.
- `{order id} · raised {transaction_date}` / `Deliver by {delivery_date or 'not set'}`
- The completion tick (same component as A1).
- Amount, right-aligned.

**"No route set" is correct and must not be improved on.** This used to fall
back to `territory`, and since every customer sits in the single territory
"India", the floor was shown **"India (no route set)"** — a string that reads
like a destination, sorts like one, and is nowhere you can drive. A blank cannot
be mistaken for an answer; a plausible wrong answer can.

### Controls

| Control | Behaviour |
|---|---|
| Search | Matches order number and route **only** |
| Close the week | Opens B3 |
| Refresh | Reload |

---

## B2. Production order detail

### Header card

- **Destination route**, large and bold, with the caption "Destination route".
- `Order` — the id
- `Raised` — transaction date
- `Order value` — grand total
- **Delivery: {date}** in amber, bold.
- If the date has been moved, an amber panel:
  > **Postponed** / **Brought forward** by production — customer asked for
  > {custom_original_delivery_date}, now {delivery_date}.
- Button **Move delivery date**, with the caption:
  > Postpone or bring forward to a date the floor can actually meet. The rep
  > sees the new date on their order.

**Moving the date writes `delivery_date` only.**

- The first time it moves, capture the previous value into
  `custom_original_delivery_date` and **never overwrite it after that**. Without
  it the new date is just a number and nobody — including whoever moved it — can
  see that it moved, or from what.
- **Never send `custom_order_placed_at`.** The moment the order was raised is not
  production's to move, and every deadline is measured from it.

### The CHANGED alert

When `custom_changed_after_approval == 1`, a red panel at the top saying the
order was edited after approval, with an **acknowledge** button that clears the
flag.

### Per-line card

- Item name and packing note
- A chip: **FROM MINIMUM STOCK** (blue) or **NEW PRODUCTION** (purple). Where it
  is coming from decides whether the floor makes it at all, so it sits next to
  the quantity, not in a footnote.
- Rate
- `Stage {i+1} of {n} · {current stage}` — green once dispatched
- A progress bar
- The stage control: let the manager set the line's
  `custom_production_stage`

**The stage list depends on the line, not just the product:**

| Condition | Sequence |
|---|---|
| `custom_fulfilment_mode == "From Minimum Stock"` | Not Started → **Packed** → **Dispatched** |
| PCTR (`Precured`) | Not Started → Compound Mixing → Extrusion → Curing → Trimming → Quality Check → Packed → Dispatched |
| CTR (`Hot Rubber`) | Not Started → Compound Mixing → Calendering → Cutting to Length → Quality Check → Packed → Dispatched |
| Bonding Gum | Not Started → Compound Mixing → Sheeting → Rolling → Packed → Dispatched |
| Vulcanizing Solution | Not Started → Blending → Filling → Sealing → Packed → Dispatched |
| anything else | Not Started → In Production → Packed → Dispatched |

**A minimum-stock line skips the making stages entirely.** The goods already
exist on a shelf — that is the whole point of the pool. Showing a stock line as
"stage 3 of 8, Curing" describes work nobody is doing and leaves the floor
looking permanently behind on orders that were finished before they were placed.
Where the goods come from outranks what they are made of.

If the stored stage is **not in the line's sequence**, show
`Stage "{x}" is not in this product's cycle` in red rather than silently showing
stage 1. This happens when the stage lists are revised under a running order, and
when a line is switched to minimum stock after the floor started it.

> ⚠ **The stage lists above are placeholders.** The real factory sequences are
> still coming. Hold them as data, not as logic.

### Setting a stage — what it writes

Two fields, and they are different types:

- `Sales Order Item.custom_production_stage` — **Data** (free text), the fine
  stage.
- `Sales Order.custom_production_status` — **Select**, and it accepts **only**
  `Not Started`, `In Production`, `Ready`, `Dispatched`. Writing `"Curing"` here
  is rejected outright and the whole update fails.

So after setting any line's stage, **roll up** to the order:

```
all lines Dispatched               → "Dispatched"
all lines Packed-or-later          → "Ready"
any line past Not Started          → "In Production"
otherwise                          → "Not Started"
```

Three things that are load-bearing:

- **Ready and Dispatched are decided by the slowest line.** An order is not ready
  because one line is packed.
- **Started is decided by the fastest.** Once the floor has touched anything,
  work is under way.
- **An unrecognised stage counts as rank 0**, never as finished. Errors must
  always round *down* — an unrecognised stage must never make an order look
  shippable.

---

## B3. Close the week — creating combined orders

Reached from the production dashboard.

### Week selector

- Defaults to the **most recently closed** week — i.e. the Monday **before** this
  week's Monday.
- Arrows step back and forward one week.
- **Forward is disabled once it would reach a week that has not finished.** A
  week still running would keep taking orders after its combined order was made,
  and nothing goes back to add them.
- Label: `"{d} {Mon} – {d} {Mon} {yyyy}"` with the caption "Monday to Sunday".

**Week boundaries are Monday → Sunday, on the date only, never the time.** An
order taken at 23:55 on Sunday and one at 00:05 on Monday belong to different
weeks.

### The list

`Sales Order` where **all four**:

1. `transaction_date` between week start and week end, inclusive
2. `custom_production_status = "Dispatched"`
3. `custom_combined_order` is empty (`''` **or** `null` — Frappe writes both)
4. `docstatus < 2`

Displayed **grouped by customer**, exactly as they will be combined, so the
manager sees the outcome before agreeing to it rather than after. Each customer
card: name, `"{n} orders → 1 combined order"`, then each order with its
completion tick, id, date and amount.

Empty state:

> Nothing left to group for this week.
> Only completed orders are grouped, and anything already grouped is not offered
> again.

### The button

`"Group {n} into combined orders"`, disabled when nothing is groupable.

Confirmation dialog first:

> **Close this week?**
> {n} completed orders from {week} will be grouped into {m} combined orders, one
> per customer.
> Everyone will see the combined order against these orders.

### What it writes

For each customer with eligible orders:

1. Create a `Combined Order`:
   ```json
   { "customer": "...", "week_start": "YYYY-MM-DD", "week_end": "YYYY-MM-DD",
     "status": "Draft", "order_count": n, "total_amount": 1234.00,
     "grouped_by": "<Sales Person or omit>" }
   ```
   `grouped_by` is often **null** — a production manager is usually not a Sales
   Person. Do not require it.
2. Set `custom_combined_order` on each member Sales Order.

**Membership lives only on the Sales Order.** There is no child table on
`Combined Order`. With no server scripts, two records of the same fact drift the
first time a save half-fails.

**The run is repeatable, never unwound.** Because already-grouped orders are
excluded, a run that fails halfway is finished by running it again. Do not
implement a rollback — you would risk pointing orders at a combined order you
had just deleted. On failure, say so and tell them to run it again.

---

# PART C — shared components

## C1. The completion tick

Used on every order row in both dashboards. **Derived, never stored.**

```
complete  ⟺  custom_production_status == "Dispatched"
```

There is deliberately **no** `custom_order_complete` field. A stored flag is one
more thing that can disagree with the floor — ticked on an order still being
made, or left unticked on one long gone.

| State | Icon | Colour | Text |
|---|---|---|---|
| Dispatched | filled checked box | green `#1B7F3B` | **Complete** |
| Ready | indeterminate box | amber `#8A6100` | Ready |
| In Production | indeterminate box | grey | In Production |
| Not Started / blank | empty box | grey | Not Started |

**Name the state, don't just tick or not.** "Ready" and "In Production" are both
"not complete", and someone chasing an order needs to know which.

Never show a tick against a **lead order** — it is not a Sales Order yet and has
no production status. An empty box would read as "not finished" rather than "not
applicable".

## C2. The server clock

Every deadline and every week boundary is judged against the **server's** clock,
read from the `Date` HTTP response header. Never the browser's. A user controls
their own clock, and these decide whether a change is allowed.

## C3. Error handling

- Use `validateStatus: status < 500`. Frappe returns useful bodies on **417** and
  **403**; treating them as transport failures loses the message.
- Unwrap `_server_messages` for the human-readable text.
- An unset Link reads back as `null` on one path and `''` on another, plus the
  string `'null'` from naive interpolation. Check all three, everywhere.

---

# PART D — what to check before you call it done

- [ ] Order approval appears **only** in Team Orders, never in the approvals inbox
- [ ] Approving stamps `custom_rate_approved = 1` on the order **and every line**
- [ ] A lead order with missing GST/address/route cannot be approved, re-checked
      live at the moment of approval
- [ ] A lead shows **no** credit verdict, only the order total
- [ ] Approving a lead order converts the lead, raises the Sales Order already
      approved, and writes back the linkage
- [ ] The fulfilment toggle is **hidden and replaced by a reason** once approved
- [ ] "Fixed once you approve this order" shows **before** the decision
- [ ] Production never receives the customer name, and search matches only order
      id and route
- [ ] "No route set" is shown as-is; territory is never substituted
- [ ] Minimum-stock lines show the 3-stage cycle, not the family's
- [ ] The order status roll-up only ever writes the four Select values
- [ ] An unrecognised stage rounds **down**, never to Ready or Dispatched
- [ ] Moving a delivery date captures the original once and never overwrites it
- [ ] `custom_order_placed_at` is never written by production
- [ ] Only closed weeks can be grouped; forward is disabled on a running week
- [ ] Combined rows and their members are never listed together
- [ ] Every deadline uses the server clock
