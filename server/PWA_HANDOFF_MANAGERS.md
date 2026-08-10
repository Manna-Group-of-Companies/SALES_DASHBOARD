# Manna — Sales Manager & Production Manager dashboards

Handoff for the web/PWA build. Written 7 Aug 2026, current to commit `5056c2e`.

**Read `PWA_HANDOFF.md` first.** It covers the shared foundations: connecting,
auth, business units, product families, the weight fields, minimum-stock
arithmetic, and the compare-and-swap booking protocol. This document does not
repeat them. What follows is (a) the two manager roles end to end, and (b)
everything that changed after that document was written, which is a lot.

---

## 0. The constraint that shapes everything

**There are no Server Scripts.** The site's plan does not allow them. Every rule
below is enforced by the client, which means:

- Your dashboard must re-implement each rule. Nothing in ERPNext will stop you
  writing a state the mobile app would have refused.
- Where the mobile app and your dashboard both write the same field, they must
  agree exactly, or a manager will see one answer on their phone and another on
  their screen.
- Anything safety-critical (stock booking) uses optimistic concurrency on
  Frappe's `modified` timestamp. See §4 of `PWA_HANDOFF.md`. Do not skip it.

Assume the mobile app is the reference implementation. When this document and
the Flutter source disagree, the source is right — file paths are given
throughout.

---

## 1. What changed since `PWA_HANDOFF.md`

Ten commits. Each is expanded later; this is the index.

| # | Change | Affects |
|---|---|---|
| 1 | Leads have sites, with route tagging and deletion | Sales mgr |
| 2 | `custom_assigned_reps` is a **Link to Sales Person**, not text | Both |
| 3 | Incomplete-lead warning; trips read Sales Route not Territory | Sales mgr |
| 4 | Reps can fill in missing Item packing details, write-once | Both |
| 5 | Duplicate-place block within 1 km | Sales mgr |
| 6 | Minimum-stock lines skip the making stages | Production |
| 7 | **Combined Order** — weekly grouping per customer | Both |
| 8 | Route is mandatory before an order can be taken | Both |
| 9 | Fulfilment mode locks at 1 pm; grouping shown to managers | Both |
| 10 | A closed week shows as one row that opens into its orders | Both |

---

## 2. Roles

There is no ERPNext role called "Sales Manager" in the app's sense, and none
called "Production Manager". Identify them like this:

| Role | How the app decides |
|---|---|
| Sales rep | `Sales Person` linked from `User.custom_user`; holds ERPNext role `Sales User` |
| Sales manager | A `Sales Person` with reports under them → `Session.teamReps` |
| Production manager | `User.custom_is_production_manager = 1` |
| HR manager | `User.custom_is_hr_manager = 1` |
| General manager | `User.custom_is_general_manager = 1` |

A production manager is **not** a Sales Person and usually has no
`custom_sales_person`. Do not assume one exists — the `grouped_by` field on
`Combined Order` comes back null for exactly this reason.

Every rep currently holds exactly one ERPNext role, `Sales User`, plus (as of
this session) `Item Packing Editor`.

### `Item Packing Editor`

A custom role created this session. Grants `read` + `write` on `Item` and
nothing else — no create, no delete, no export, no import. Assigned to all 15
active reps. It exists so a rep can fill in missing packing details (§7).

Note for whoever maintains ERPNext: adding it required copying all 9 standard
`Item` DocPerms into `Custom DocPerm`, because Frappe *replaces* rather than
merges permissions once any Custom DocPerm row exists for a doctype. If you ever
need to undo it, delete every `Custom DocPerm` where `parent = "Item"` and the
standard permissions return.

---

## 3. Sales manager — every approval

There are **six** distinct approvals. They do not all live in the same place,
and that split is deliberate.

### 3.1 Where each one lives

| Approval | Screen | Why |
|---|---|---|
| Order / rate approval | **Team Orders only** | Deciding an order needs the lines, the stock position and the credit picture. An inbox row cannot carry that. |
| Proforma release | Approvals inbox | |
| Customer location verification | Approvals inbox | |
| Customer **site** verification | Approvals inbox | |
| Lead location verification | Approvals inbox | |
| Lead order approval | **Team Orders only** | Same reason as orders — and it also converts the lead. |

**Order approvals must not appear in the approvals inbox.** This was explicitly
changed. The inbox is for one-tap yes/no decisions; an order decision is not one.

Source: `lib/screens/manager/manager_approvals_screen.dart`,
`lib/screens/manager/manager_orders_screen.dart`.

### 3.2 Order approval (Sales Order)

Queue: `custom_po_status = "Pending Approval"` and
`custom_sales_person in <team>`.

`custom_po_status` allowed values — this is a Select, anything else is rejected:

```
No PO Yet
Pending Approval
Pending Rate Approval
PO Uploaded - Pending Approval
Pending GM Approval
PO Approved - Ready for SAP
Rejected
```

The stored strings still say "PO" for historical reasons; nobody scans a
purchase order any more. Show the rep-facing label instead
(`lib/core/order_rules.dart::approvalLabel`):

| Stored | Shown |
|---|---|
| `PO Approved - Ready for SAP` | Approved |
| `Pending Approval`, `PO Uploaded - Pending Approval` | Waiting for manager approval |
| `Pending Rate Approval` | Waiting for rate approval |
| `Pending GM Approval` | Escalated to GM |
| `Rejected` | Rejected |
| `No PO Yet`, empty, `null` | Not sent for approval |

**Approving writes two things**, not one:

```json
{ "custom_po_status": "PO Approved - Ready for SAP", "custom_rate_approved": 1 }
```

…and stamps `custom_rate_approved = 1` on **every line** as well. The per-line
stamp is the only way the app can later tell an approved price from one the rep
typed afterwards. Do not skip it.

Rejecting writes `custom_po_status: "Rejected"`, `custom_rate_approved: 0`.

### 3.3 The two rate-approved flags

There are two, they are different, and confusing them causes real bugs.

- `Sales Order.custom_rate_approved` — "the prices on this order were signed off
  at some point". Locks manual pricing.
- `Sales Order.custom_po_status` — "there is nothing left to decide".

Use `orderApproved()` (reads the **status**) for "is this decided". Use
`ratesLocked()` (reads the **flag**) for "can the rep still type a price".

A rep editing an approved order sends it back to the queue — the status reverts,
but the rates it already had stay locked. A newly added line is allowed and is
unpriced, which is why it must go back for review.

### 3.4 GM escalation

The manager can escalate instead of deciding:

- Sales Order → `custom_po_status: "Pending GM Approval"`
- Lead Order → `status: "Pending GM Approval"`

GM queue is anything sitting at that value. There is no automatic threshold —
escalation is a manual choice by the sales manager.

### 3.5 Proforma release

- Queue: `custom_proforma_status = "Pending Release Approval"`, team-filtered.
- Release → `custom_proforma_status: "Released"`
- Refuse → `custom_proforma_status: "Blocked - Credit"`

Other values seen: `Ready`, `Sent`.

### 3.6 Credit limit

Read from the customer:

- `custom_credit_limit`
- `custom_outstanding_balance`

Over limit when `outstanding + order total > limit`. Show it as a warning, not a
block — the manager decides.

**Never show a credit verdict for a lead.** A lead has no trading history and no
limit; a green "Within credit limit" against a party you know nothing about is
worse than silence. For leads, show the order total alone. This was an explicit
correction.

For a customer with no limit set, say "New party — no trading history or credit
limit to check against" rather than showing a green tick.

### 3.7 Location and site verification

Three separate queues, same shape:

| Queue | Doctype | Status field |
|---|---|---|
| Customer location | `Customer` | `custom_location_status` |
| Lead location | `Lead` | `custom_location_status` |
| Customer/lead site | `Customer Site` | its own status field |

`custom_location_status` values: `Not Captured`, `Pending Verification`,
`Verified`, `Rejected`.

Approving copies the captured coordinates into the **verified** fields:

```json
{ "custom_location_status": "Verified",
  "custom_verified_latitude": <lat>,
  "custom_verified_longitude": <lng> }
```

Rejecting sets `custom_location_status: "Not Captured"` so the rep re-captures.
The verified coordinates are what the 100 m punch-in check runs against.

Lead queue is filtered by `custom_location_captured_by in <team>`.

---

## 4. Lead orders and conversion

A `Lead Order` is a separate custom doctype, with `Lead Order Item` children.

### 4.1 What approval actually does

`Api.approveLeadOrder` (`lib/services/api.dart:661`) does **three** things in
order. Replicate all three:

1. **Converts the Lead to a Customer** (`convertLeadToCustomer`).
2. **Raises a Sales Order** from the lead order's lines, against the new
   customer — created **already approved**, because the manager approving the
   lead order is making the same decision they'd make on a Sales Order. Sending
   it back to their own queue would ask them to approve it twice.
3. **Writes back** to the Lead Order:
   ```json
   { "status": "Approved",
     "sales_order": "<SAL-ORD-…>",
     "approval_remarks": "Converted to customer X, raised as Y" }
   ```

Rejecting is just `{ "status": "Rejected" }` — no conversion.

### 4.2 The completeness gate

A lead order **cannot be approved** until the lead has all of:

- `custom_gstin` — you cannot invoice without it
- `custom_address` — same
- `custom_sales_route` — production is shown a route and nothing else

`lib/core/order_rules.dart::missingLeadDetails`. The manager must be told
exactly what is missing, so they can chase the rep for the right thing.

These are collected at *approval*, not at lead creation, on purpose: a rep
meeting somebody for the first time should be able to record them in thirty
seconds. The paperwork is owed once there is an order worth invoicing.

**Exception, new this session:** the sales route is now required *earlier* — see
§9. A lead with no route cannot have an order taken from it at all.

### 4.3 Lead orders carry less than Sales Orders

`Lead Order Item` holds only `item_code`, `qty`, `rate`. It has no roll/belt
breakdown and no minimum-stock booking. So:

- A lead order always reads as **new production**.
- `Lead Order Item.amount` is **not** derived by ERPNext. Send it explicitly, or
  fall back to `qty × rate`. Getting this wrong made lead order totals show as
  zero to the manager while looking correct to the rep.

### 4.4 Bookings point at one order or the other

`Manna Stock Reservation` has both `sales_order` and `lead_order`. Exactly one
is set. On approval the reservations are **re-pointed**, not released and
re-taken — releasing would put the stock back on offer at the very moment the
order was approved.

---

## 5. Production manager

### 5.1 Production must never see the customer

This is a hard rule, not a preference. The production dashboard is given a
**route** and nothing else. `Api.getApprovedPOsForProduction` resolves customer
→ route server-side, then **deletes** the customer field from the payload before
the screen ever sees it:

```dart
o['destination'] = routes['${o['customer']}'] ?? 'No route set';
o.remove('customer');
```

`getOrderForProduction` additionally strips `customer_name` and
`company_address_display`.

The production search box deliberately matches only the order number and route —
a search that quietly matched a hidden field would let someone confirm a
customer by guessing.

**Replicate this in the web dashboard.** Do not send customer identity to the
production view and hide it in CSS.

### 5.2 The destination, and a fix you must copy

Queue: `custom_company = <unit>` AND
`custom_po_status = "PO Approved - Ready for SAP"`.

`destinationOf()` returns the `custom_sales_route`, or the literal string
`"No route set"`.

**It used to fall back to `territory`.** Every customer sits in the single
territory "India", so the floor was shown **"India (no route set)"** — a string
that reads like a destination, sorts like one, and is nowhere you can drive.
That fallback is removed. A blank cannot be mistaken for an answer; a plausible
wrong answer can.

### 5.3 Stages are per item; the order status is a Select

Two different fields, and this trips people up:

- `Sales Order Item.custom_production_stage` — **Data** (free text). The fine
  stage the floor works in.
- `Sales Order.custom_production_status` — **Select**. Only four values are
  accepted: `Not Started`, `In Production`, `Ready`, `Dispatched`. Writing
  `"Curing"` here is rejected outright and the whole update fails.

So the per-item stage **cannot** be copied to the order. It must be rolled up.

### 5.4 The stage sequences

`lib/core/production_stages.dart`. **These are placeholders** — the real factory
sequences are still coming. Structure your code so the list is data, not logic.

| Family | Sequence |
|---|---|
| PCTR (`Precured`) | Not Started → Compound Mixing → Extrusion → Curing → Trimming → Quality Check → Packed → Dispatched |
| CTR (`Hot Rubber`) | Not Started → Compound Mixing → Calendering → Cutting to Length → Quality Check → Packed → Dispatched |
| Bonding Gum | Not Started → Compound Mixing → Sheeting → Rolling → Packed → Dispatched |
| Vulcanizing Solution | Not Started → Blending → Filling → Sealing → Packed → Dispatched |
| Anything else | Not Started → In Production → Packed → Dispatched |

### 5.5 NEW — minimum-stock lines skip the making stages

If `Sales Order Item.custom_fulfilment_mode = "From Minimum Stock"`, the
sequence is **not** the family's. It is:

```
Not Started → Packed → Dispatched
```

The goods already exist on a shelf — that is the whole point of the pool. A
stock line shown as "stage 3 of 8, Curing" describes work nobody is doing, and
leaves the floor looking permanently behind on orders that were finished before
they were placed.

**Where the goods come from outranks what they are made of.** Use one function
for this so the screen and the roll-up cannot disagree
(`stagesForItem(item)`).

### 5.6 The roll-up rule

```
allDispatched            → "Dispatched"
all lines Packed-or-past → "Ready"
any line started         → "In Production"
otherwise                → "Not Started"
```

Two subtleties that are load-bearing:

- **Ready and Dispatched are decided by the slowest line.** An order is not
  ready because one line is packed.
- **Started is decided by the fastest.** Once the floor has touched anything,
  work is under way.
- A stage **not in the sequence** counts as rank 0 (unknown), never as finished.
  This matters when the real stage lists land under running orders, and when a
  line is switched to minimum stock mid-production — its old making stage becomes
  off-sequence, and the order correctly reads `Not Started` again, because
  nothing has been *picked* yet whatever was done to the batch.

Errors must always round **down**. An unrecognised stage must never make an
order look shippable.

### 5.7 Moving the delivery date

The production manager can move `delivery_date` forwards or back.

- The first time it moves, the original is captured into
  `custom_original_delivery_date` and **never overwritten after that**. Without
  it, nobody — including the person who moved it — can see that it moved or
  from what.
- `custom_order_placed_at` is **never** sent. The moment an order was raised is
  not production's to move, and every deadline is measured from it.

### 5.8 `custom_changed_after_approval`

A Check field. Set when a rep edits an order after approval. The production
dashboard shows a red **CHANGED** flag. Surface it prominently — it means the
floor may be building the wrong thing.

---

## 6. NEW — Combined Orders (weekly grouping)

**This lives in ERPNext, not in the app.** Your dashboard can read it directly.

### 6.1 Schema

**DocType `Combined Order`** — custom, module `Selling`, autoname `COMB-.#####`.

| Field | Type | Notes |
|---|---|---|
| `customer` | Link → Customer | required |
| `customer_name` | Data | fetched from customer, read-only |
| `week_start` | Date | required, always a **Monday** |
| `week_end` | Date | required, always a **Sunday** |
| `status` | Select | `Draft` / `Confirmed` / `Dispatched`, default Draft |
| `order_count` | Int | read-only |
| `total_amount` | Currency | read-only |
| `grouped_by` | Link → Sales Person | read-only, often **null** (production managers are not Sales Persons) |
| `notes` | Small Text | |

Permissions: Sales Manager full; Sales User read/write/create; Accounts User
read; Stock User read.

**Field on Sales Order:** `custom_combined_order`, Link → Combined Order,
`allow_on_submit = 1` (orders are submitted by the time they are grouped).

### 6.2 Membership lives in exactly one place

There is **no child table** on `Combined Order` listing its orders. Membership is
`Sales Order.custom_combined_order` and nothing else.

This is deliberate. With no server scripts, two records of the same fact drift
the first time a save half-fails. Reading the group as a query means a combined
order can never claim to hold an order that doesn't point back at it.

**To list a group's contents:** query Sales Orders where
`custom_combined_order = <name>`.

### 6.3 The grouping rules

Run by the production manager, once a week has finished.

**Eligible orders** — all four conditions:

1. `transaction_date` between `week_start` and `week_end` inclusive
2. `custom_production_status = "Dispatched"` (i.e. complete)
3. `custom_combined_order` is empty (`''` **or** `null` — Frappe writes both)
4. `docstatus < 2` (not cancelled)

Then group by `customer`, and create one `Combined Order` per customer with
`order_count` and summed `total_amount`, then set `custom_combined_order` on
each member.

**Week boundaries are Monday → Sunday.** An order taken late on Sunday and one
taken early on Monday belong to different weeks. Use the date only, never the
time.

**Only closed weeks can be grouped.** A week still running would keep taking
orders after its combined order was made, and nothing goes back to add them. On
any day, the most recent groupable week is the one ending last Sunday.

**The run is repeatable.** Because already-grouped orders are excluded, a run
that fails halfway is finished by running it again — never unwound. Do not
implement a rollback; you would risk pointing orders at a combined order you had
just deleted.

### 6.4 How it must be displayed

Everyone in the loop sees it. In the rep's own order list, a closed week is
collapsed to **one row** — customer, week, order count, total — which opens into
the individual orders, each still openable in full.

Two rules for your dashboard:

- **Do not list a group and its members side by side.** The same money would be
  counted once in the group and again underneath it.
- **Take the totals from the `Combined Order` header, not from the members you
  happen to have loaded.** A customer served by two reps in one week should show
  the whole week to both, not each rep's share.
- If the header cannot be read, **leave the individual orders showing**. A user
  seeing an order ungrouped is a worse list; a user seeing neither has lost work
  off their screen.

Currently in ERPNext: `COMB-00001` (A M Logistics, 2 orders, ₹4,734),
`COMB-00002` (Aaliya Trans, 1, ₹7,070), `COMB-00003` (Abhishek Tyres-Edayar, 2,
₹8,498), all for week 2026-07-27 → 2026-08-02.

---

## 7. NEW — Item packing details, write-once

An Item imported without its packing figures cannot be priced, because price is
per kilogram and quantity is in rolls.

The fields (`Item`):

| Field | Meaning |
|---|---|
| `custom_weight_per_roll` | Weight of one **roll** |
| `custom_avg_weight_per_roll` | **Despite the name, this is the weight of one BELT.** Verified: 10.1 × 4 belts = 40.4 kg/roll |
| `custom_belts_per_roll` | Belts cut from one roll |
| `custom_pack_litres` | Litres per tin (solution only) |

An item is **misconfigured** when:

- PCTR: `weightPerRoll <= 0` or `beltsPerRoll <= 0`
- CTR: `weightPerRoll <= 0`
- Solution: `packLitres <= 0`

Reps can now fill in what is missing, from the order row. The rule:

- **Only fields that are currently empty are written.** The save re-reads the
  Item first; if another user filled it in meanwhile, theirs stands and the
  second user is told so.
- **Once set, a figure cannot be changed from the app.** It decides what
  customers are charged, and a number that can be revised after orders have been
  priced against it is one nobody can reconcile. Corrections go through Desk.

If you offer the same capability in the dashboard, keep both halves of that rule.

A misconfigured item must **never price at zero**. Refuse the line.

---

## 8. NEW — duplicate place block (1 km)

When a lead's location is captured, or a rep punches in on a lead, the app looks
for any Lead or Customer already on record within **1 km** and refuses if it
finds one.

- The search is across **other** reps in the caller's own business unit, taken
  from `Sales Person.custom_company` (`Manna Treads`, `Manna Tyre Retreads`,
  `Manna Tyres UAE`). The caller's **own** leads and customers never block them:
  a rep who has placed one shop and walks next door is working, not duplicating
  themselves. Other units do not block either: the two sell different
  things to the same trade, so one tyre shop is legitimately a customer of both
  and neither record is a duplicate of the other. A record whose rep has no unit
  blocks nobody.
- The record being captured is excluded from its own check.
- Records with no coordinates are invisible to it. `(0, 0)` is open ocean and
  means "never captured", not a place.
- **It fails closed.** If the lookup cannot run, the capture is refused. A guard
  that opens when the network is down is one that gets bypassed with flight mode.
- Clearing a genuine clash means a **sales manager** deletes the duplicate. Reps
  hold `delete = 0` on both Lead and Customer.

Implementation note if you replicate it: narrow with a lat/long bounding box in
SQL, then trim with an exact haversine distance. Size the box off the **smallest**
real metres-per-degree (~110,540) and widen it a further 2%. Using the equatorial
111,320 makes the box ~1 m short of 1 km, and a duplicate at 999 m due north is
silently filtered out before anything measures it.

**Reality check:** of 3,001 leads and 620 customers, exactly **one** has
coordinates. The check has almost nothing to compare against until locations are
captured in the field.

---

## 9. NEW — route is mandatory before an order

An order **cannot be started** for a customer or lead with no
`custom_sales_route`. Enforced before the order screen opens (not at save —
refusing a full basket at the counter wastes everyone's time), and again in the
order-creation calls as a backstop.

Rationale: production is told the route and nothing else. An order without one
reaches the floor with nowhere to send it, and it is only noticed when somebody
tries to load a van. Everything *else* a lead is missing can be fixed before
approval; a route cannot, because by then the order exists, has reserved stock,
and has already reached production.

Treat `''`, `'   '`, `null` and the string `'null'` all as "no route".

**Impact on live data:**

```
Customers: 620 total | with route: 362 | WITHOUT: 258
Leads:    3001 total | with route: 2994 | WITHOUT:   7
```

258 customers — 42% — cannot be ordered from until routes are assigned.

### Routes themselves

- Doctype `Sales Route`, autoname `field:route_name`. 98 exist.
- Naming convention is **`<Rep Name> - <Place>`**, e.g. `Amjad Pr - Kozhikode`.
  When a rep creates one, the app pre-fills the non-deletable prefix.
- Reps can create and delete their own routes in the app.
- **Territory is not a route.** Every customer is in territory "India". Do not
  use Territory anywhere a route is meant — trips used to and it was wrong.

---

## 10. The 1 pm rule, and what it now covers

An order freezes at **13:00 on its required delivery date**
(`kOrderEditCutoffHour = 13`, `lib/core/order_rules.dart`).

- No delivery date → treated as permanently **open**, not shut. An order without
  a date is a data problem, and refusing to let anyone fix it makes it worse.
- Judged against the **server clock**, read from the HTTP `Date` response header.
  A rep controls the phone's clock; this deadline decides whether a change is
  allowed, so it cannot be trusted to the device.

Who may edit before the deadline: the rep who raised it, **or** their manager. A
manager needs it because a customer who rings the office should not have to wait
for their rep to come back into signal.

**NEW: the fulfilment mode now locks at 1 pm too.** Switching a line between
`From Minimum Stock` and `New Production` is a change to the order like any
other. After the deadline the goods are already being picked or made against
whatever was decided, so moving it would overwrite a decision the floor has acted
on. The API refuses it as well, judged against the order **as stored**, not as
the screen last saw it.

---

## 11. Fulfilment mode

`Sales Order.custom_fulfilment_mode` and `Sales Order Item.custom_fulfilment_mode`
— Select, values: `` (empty), `From Minimum Stock`, `New Production`.

The sales manager sets it **per line**. It is a priority call, not a logistics
one: an important customer is served out of minimum stock and gets their order
quickly; everyone else waits for a production run.

Switching a line to `New Production` **releases** whatever it was holding, so the
pool goes back to whoever needs it sooner.

When nothing is recorded, the rep's own booking is the status quo: a line the rep
booked is "from minimum stock" until the manager says otherwise; a line with no
booking is "new production".

---

## 12. NEW — the completion tick

Every order shows whether it is complete, the same way to everyone.

**Derived, never stored.** An order is complete when
`custom_production_status == "Dispatched"`. There is deliberately **no**
`custom_order_complete` field — a stored flag is one more thing that can disagree
with the floor: ticked on an order still being made, or left unticked on one long
gone.

Show the state by name, not just ticked/unticked. "Ready" and "In Production" are
both "not complete", and someone chasing an order needs to know which.

In the manager's order list, a dispatched order should read **"Order complete —
dispatched"** rather than "Production: Dispatched" — one less stage name to know
the order of.

---

## 13. Assigned reps — a schema change that broke five things

`Customer.custom_assigned_reps` **was** free text holding pipe-wrapped values.
It is now a **Link to Sales Person**.

If you filter customers by rep, filter on the Link. The old text-matching
(`like %|rep|%`) returns nothing and the customer list silently comes back empty.
This broke five separate call sites in the app: the customer list query, the rep
outstanding figures, the day map, and two write paths.

---

## 14. Gotchas that cost real time

- **`validateStatus: s < 500`.** Frappe returns useful bodies on 417 and 403.
  Treating them as transport failures loses the message.
- **Frappe races itself creating Custom Fields in parallel** —
  `IndexError: list index out of range`. Add a few at a time and retry the loser.
- **New permission rows default to `write: 1`.** Explicitly zero write/create/
  delete for read-only roles.
- **Frappe rejects the `All` role on custom doctypes for non-admins.** Use
  concrete roles.
- **An unset Link reads back as `null` on one path and `''` on another.** Check
  both, plus the string `'null'` from naive interpolation.
- **`DocPerm` and `Has Role` are Administrator-only to read**, even for a System
  Manager. Read the `User` doc or the DocType meta instead.
- **Empty batch rows.** A minimum-stock item whose batch rows exist but total
  zero must read as "no usable stock", not fall back to the pool figure. Getting
  this wrong showed "only 0 left" against a screen saying 10.

---

## 15. Still not built / known wrong

- **Dispatch is not built.** Batches only change through Desk. Nothing decrements
  stock on dispatch.
- **157 items are still on the `Nos` UOM.** `server/item_uom_fix.csv` awaits a
  Data Import.
- **Six items carry invented roll weights.** They are load-bearing — zeroing them
  prices those items at zero.
- No Hot Rubber item has `custom_weight_per_roll`; solution has no
  `custom_pack_litres`.
- `BLACK PEARL 160 RTS 99` batch `MSB-00030` reads 0 rolls; the real figure is
  unknown.
- **The production stage lists are placeholders** (§5.4).
- **Combined Order `status` is never advanced** past `Draft` by the app. If your
  dashboard is where a manager confirms or dispatches a week, you own that
  transition.
- **Team Orders still lists grouped orders individually** with a "Week order:"
  line, rather than collapsing them the way the rep's list does.

---

## 16. Test data currently in ERPNext

Seven dummy Sales Orders, all tagged `custom_po_number = "DUMMY-TEST"`, all
`docstatus = 0` (draft), all `custom_sales_person = "Sirajudheen Kasim"`.

| Order | Customer | Date | Status | Group |
|---|---|---|---|---|
| `SAL-ORD-2026-00097` | Abhishek Tyres-Edayar | 27 Jul | Dispatched | COMB-00003 |
| `SAL-ORD-2026-00098` | Abhishek Tyres-Edayar | 30 Jul | Dispatched | COMB-00003 |
| `SAL-ORD-2026-00099` | A M Logistics | 29 Jul | Dispatched | COMB-00001 |
| `SAL-ORD-2026-00100` | A M Logistics | 1 Aug | Dispatched | COMB-00001 |
| `SAL-ORD-2026-00101` | Aaliya Trans | 2 Aug | Dispatched | COMB-00002 |
| `SAL-ORD-2026-00102` | Abhishek Tyres-Edayar | 28 Jul | In Production | — (not complete) |
| `SAL-ORD-2026-00103` | Aaliya Trans | 5 Aug | Dispatched | — (week still open) |

The last two exist specifically to prove the grouping filters work. Delete them
all with a query on `custom_po_number = "DUMMY-TEST"` when you're done.

`SAL-ORD-2026-00098` has one stock line and one new-production line, so it shows
the 3-stage and 8-stage displays side by side.

---

## 17. Where to read the source

| Concern | File |
|---|---|
| Every backend call | `lib/services/api.dart` (~3,400 lines) |
| Approval labels, 1 pm rule, lead completeness | `lib/core/order_rules.dart` |
| Stage sequences and the roll-up | `lib/core/production_stages.dart` |
| Week boundaries | `lib/core/week.dart` |
| Duplicate-place arithmetic | `lib/core/proximity.dart` |
| Stock booking / compare-and-swap | `lib/services/stock_service.dart` |
| Minimum-stock arithmetic | `lib/models/min_stock.dart` |
| Product families and weights | `lib/models/product_category.dart` |
| Sales manager order review | `lib/screens/manager/manager_order_review_screen.dart` |
| Sales manager order list | `lib/screens/manager/manager_orders_screen.dart` |
| Approvals inbox | `lib/screens/manager/manager_approvals_screen.dart` |
| Production dashboard | `lib/screens/production/production_dashboard_screen.dart` |
| Production order detail | `lib/screens/production/production_order_detail_screen.dart` |
| Week close / grouping | `lib/screens/production/combine_week_screen.dart` |
| Combined order detail | `lib/screens/orders/combined_order_screen.dart` |

The tests are worth reading before the implementation — they state the rules more
plainly than the code does: `test/production_stages_test.dart`,
`test/week_test.dart`, `test/combined_rows_test.dart`,
`test/route_required_test.dart`, `test/proximity_test.dart`.
