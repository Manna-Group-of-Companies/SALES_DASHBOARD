# Where the two apps disagree

Found on 13 August 2026, when the Flutter app and the dashboard were brought
into one repository and their per-line discount features — written the same
afternoon, independently — were compared.

**This file is the queue.** A row leaves it by being decided and turned into a
fixture in `fixtures/`, not by being forgotten.

**Decided 13 August 2026: where the two disagreed, the phone wins.** The reps'
app is the older implementation, it is what is installed in the field, and it is
what the trade has been using — so it is the reference and the dashboard was
brought to it, not the other way round. Items 1, 2 and 3 below are closed on
that basis and now live in `fixtures/discount.json`.

---

## What already agrees

Worth stating, because it is the expensive half and it landed identically on
both sides without coordination:

- The discount is stored in ERPNext's **own** pricing fields on
  `Sales Order Item` — `price_list_rate`, `discount_percentage`,
  `discount_amount`, `rate`, `amount` — and not in new custom fields. So the
  proforma, the GST computation and the eventual Sales Invoice all carry it.
- `rate` is per unit **after** the discount; `amount` is `qty × rate`.
- The percentage comes off the **rate**, and the amount is rebuilt from it.
- `custom_rate_per_kg` keeps what the rep quoted, before the discount.
- The order-level percentage is `given ÷ before`, never the mean of the line
  percentages.
- A discount already granted survives a later edit by the rep.
- Approval uses the **same** gate as the rate. A discount is a price.

---

## 1. How much may be taken off — **closed, 13 Aug 2026**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| Ceiling | **50%** | ~~100%~~ → **50%** |
| Out of range | **refused**, with a message | ~~clamped~~ → **refused** |

**Resolved to the phone, whole.** The dashboard now stops at 50% and refuses
anything outside 0–100 rather than clamping it, with the same three messages
word for word.

The argument that 100% has to be reachable — a free replacement roll is a real
thing in this trade — was not accepted here, and is worth recording rather than
losing: **it is still reachable, through the general manager**, which is what
the refusal message says. If the trade turns out to need it at the counter, that
is a change to `kMaxDiscountPercent` and `MAX_DISCOUNT_PERCENT` together, in one
pull request, with `fixtures/discount.json` updated in the same commit.

Clamping is simply gone. There is no longer any function on either side that
takes a percentage and hands back a different one.

*Pinned in `fixtures/discount.json` → `ceiling`.*

---

## 2. Can the GM change a discount after approval — **closed, 13 Aug 2026**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| After approval | **nobody**, GM included | ~~GM may still override~~ → **nobody** |

**Resolved to the phone.** The dashboard gates discounts on `orderSignedOff`,
which has no GM exemption, rather than on `rateEditable`, which has one.

The two statements that pointed opposite ways are both still true, and they are
reconciled by *which* thing is being changed:

- the **rate** lock keeps its GM override, on both sides, unchanged;
- the **discount** does not have one, on either side.

A GM who needs to move a signed price still can — by moving the rate. What has
gone is the state where a signed price could be moved from a desk and not from a
counter.

*Pinned in `fixtures/discount.json` → `locked`.*

---

## 3. Discounts on lead orders — **closed, 13 Aug 2026**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| Lead orders | supported | ~~not implemented~~ → **supported** |

The dashboard's lead-order screen now carries the same control, the same
ceiling, the same refusals and the same before/after totals as a customer order.
`domain/discount.ts` is the only module that knows the two doctypes spell the
fields differently, exactly as `core/discount.dart` is on the phone.

*Pinned in `fixtures/discount.json` → `lead_fields`.*

---

## 4. `discount_and_margin` is hidden in Desk — **known, no action**

A Property Setter hides the `discount_and_margin` section on `Sales Order Item`
(and `additional_discount_section` on `Sales Order`). Both predate this work.

They are cosmetic — they hide fields from the Desk form and change nothing
about what the REST API accepts or stores. Worth knowing for one practical
reason: **opening a discounted order in Desk will not show the discount**, so
Desk is not the place to verify one. Read it back over the API, or from either
app.

---

## 5. Where the discount is set — **closed, 13 Aug 2026**

Not in the original list, and found while closing the others.

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| When it is written | **immediately**, per line | ~~queued until approval~~ → **immediately** |

The dashboard used to collect discounts into the approve action. A manager who
set one and walked away without approving had given nothing, while believing
otherwise — and the two apps disagreed about what a saved order contained.

Both now write per line, through one function that re-reads the order first and
refuses on two conditions only answerable against the stored document: that it
has not been signed off since the screen loaded, and that the line is still on
it. A row that has vanished means a rep edited the order at the same moment, and
writing the array back anyway would save a discount onto nothing while reporting
success.

---

## 6. Outstanding, in SAP's four age buckets — **built together, 13 Aug 2026**

Not a divergence: recorded because it is the first rule written on both sides
*at the same time*, against a fixture, instead of twice and compared afterwards.

`Customer` gained four `Currency` fields on the live site:

    custom_outstanding_0_30       custom_outstanding_60_90
    custom_outstanding_30_60      custom_outstanding_90_plus

`custom_outstanding_balance` stays the **total** and stays what the credit
limit is checked against. `custom_credit_limit` stays a single figure, because
SAP sends one — only the outstanding is aged.

Two states neither app may blur, and the reason each exists:

- **Not synced.** Every one of the 620 customers has zero in all four buckets
  until the SAP job is changed to send them. Four zeros beside a real balance
  would read as "nothing is overdue", which is a claim nobody has the data to
  make, so both apps say the breakdown has not arrived instead.
- **Doesn't add up.** If the buckets and the balance disagree by more than a
  rupee, both say so. The stored balance still wins — it is the figure the
  credit decision has always been made on — but a sync that wrote one and not
  the other must not stay hidden for months.

The 90+ bucket is **shown, not enforced**: it is styled as a warning and
changes nothing about who may order. Making it escalate would have started
stopping orders the day it shipped, on customers nobody had warned. That is a
decision to take deliberately, not a side effect of displaying a number.

*Pinned in `fixtures/credit.json`. `client/src/domain/credit.ts` and
`app/lib/core/credit.dart` are the only two modules that know any of this.*

**Still outstanding, and not something either app can do:** the SAP → ERPNext
sync must be changed to populate the four new fields. Until it is, both apps
correctly show "not synced" and every credit check behaves exactly as before.

---

## 7. Telling a rep that production moved an item — **partly built, 13 Aug 2026**

The ask: a rep sees each item's status in My Orders and is **notified** when the
production manager changes one; the sales manager sees the same for their reps,
on both the phone and the dashboard.

Two thirds of that is built and identical on both sides. The notification is
not, and cannot be, without one of the decisions below.

### What was missing, and is now there

- **The dashboard showed the sales manager no per-item stage at all.** It now
  has a Stage column carrying both halves of a split line.
- **The phone's order detail showed no line items at all** — it counted them
  and summed the amount. It now lists every item with the stage each half is on.
- Both mark the lines production moved and lead with a summary of what changed.

### Why the "notification" is a stored diff, not a push

Two hard constraints, both verified on the live site:

- **No Server Scripts on this plan.** Nothing can fire when production saves.
- **`Notification Log`** — Frappe's own per-user store, otherwise exactly right
  (`for_user`, `subject`, `document_type`, `document_name`, `read`) — grants
  role `All` **read but not create**. A rep's or production manager's login
  cannot write one over the REST API.

Worth recording plainly: **`Sales Notification`, the doctype the dashboard has
been writing notifications to since it was built, does not exist on this site.**
The write is fire-and-forget with a swallowed error, so every notification the
dashboard has ever raised has silently gone nowhere.

So each device remembers the stages it last displayed for an order and reports
the difference on the next open. It is honest — it can only report a real change
between two things the same reader saw — and needs no schema, no permission
change and no server support. `changesSince` is pinned by
`fixtures/stage_watch.json` and both suites read it.

What it cannot do is reach a phone that never opens the order.

### To get a real notification — **needs a decision**

| Option | What it takes | Cost |
|---|---|---|
| `Custom DocPerm` on `Notification Log` granting `create` | one permission change | Frappe **replaces** rather than merges permissions — every standard row must be copied across in the same transaction, or the doctype's existing access changes underneath everybody |
| A `Sales Notification` custom doctype | one doctype + fields | the dashboard already assumes it exists, so its notification code starts working the moment it does |
| Push to the phone | the above, plus a delivery mechanism | nothing on this site does push today |

Whichever is chosen, the write still has to be made by whoever moves the stage —
there is no server to do it — so it belongs in `setProductionStage` on the
dashboard and `Api.setStage` on the phone, in the same commit.

### The two apps watched different fields — **found and closed 24 Sep 2026**

`changesSince` itself always agreed on both sides. What it was *fed* did not:
the dashboard fed the "made" portion SAP's view of the line, the phone fed it
the in-app `custom_production_stage`, which nothing has written since the floor
moved to SAP on 11 Sep 2026. So a manager on the dashboard was told when a line
was invoiced, and a rep on the phone was told nothing.

Both now feed the line's SAP status from `lineStatusFromSap` (Pushed to SAP →
Dispatched, per line) under the watcher's old key, so `stage_watch` itself did
not change. This follows the release decision of 24 Sep 2026 — once approved,
SAP reports the order. The stored snapshot key moved to `stageSeen2:` on both
sides at the same time, so the first look after the update sets a fresh
baseline instead of reporting every line of every previously-opened order as
moved.

### Which orders a list calls Dispatched — **found and closed 24 Sep 2026**

Not a phone-against-dashboard difference but both against the release rule:
the phone's manager order list, the dashboard's orders list and combined-orders
tick, and the phone's duplicate-order check all read "Dispatched" from the
in-app `custom_production_status`. An invoiced order therefore never showed as
complete there. Both apps now use `orderProgress` — SAP's status once SAP has
the order, the stored status only before — pinned by the `order_progress`
cases in `fixtures/sap_order_state.json`. The rep's My Orders already did this
inline; it now calls the same function.

---

## 8. UAE shares its customers; everywhere else does not — **built, 16 Aug 2026**

The UAE unit is four reps and a manager covering a whole country. When one
takes leave another has to serve their customers that week, and reassigning
records by hand — then putting them back — is not something that happens on the
morning somebody calls in sick.

So `Manna Tyres UAE` is a **pooled unit**: every rep in it sees every other's
customers, leads and routes. `Manna Treads` and `Manna Tyre Retreads` are
unchanged — a rep there sees only their own.

Keyed on `Sales Person.custom_company`, not on the team token or a list of
names, because the unit is what actually differs and a name list goes stale the
first time somebody joins.

**Pooling widens visibility only. Ownership is untouched.** Every record still
names one rep, and a pooled list shows the owner on the row — a shared list with
no owner on it is a list nobody is responsible for.

**Routes are pooled too.** Without that a rep on cover can see the customer and
then cannot set the round it belongs to, and the order goes out against the
wrong route. Half a cover is worse than none.

It fails closed: a login matching no Sales Person, or a rep with no unit
recorded, sees nothing rather than everything.

The dashboard needed no change — a manager's scope was already their whole
team, which for Renjith is the whole UAE unit, and the customer list already
carries a Representative column. The gap was the phone, where every query was
`= me`.

*Pinned in `fixtures/visibility.json`; both suites read the same 24 cases.*

---

## 9. Shared trips: with the manager, and whose expense — **built, 18 Aug 2026**

Two things about trips several people take together.

### "Shop visit with manager" read zero because of a token

The rule existed and was right. The caller passed `person.teamManager`, which
is a short TOKEN — `Pareeth` — while a trip tags the Sales Person RECORD NAME,
`Pareeth Kb`. Nothing ever matched.

It looked exactly like missing data. It was not: on 18 Aug TRP-00258 (Jaimon D)
and TRP-00301 (Test Rep) both carried `|Pareeth Kb|` and neither was ever
counted. `travelledWithManager` now names its parameter `managerName` and says
in its own doc comment that a token will silently count nothing;
`managerNameFor` resolves it.

Both directions count, as asked: the rep tagging the manager along, and the
manager taking the rep out.

### Whose expense is it

`Trip Expense.custom_for_person` (Link to Sales Person) created on the live
site. **Empty means COMMON** — the journey's own cost, a toll or a tank of
fuel, belonging to everyone who travelled.

Common is the default deliberately. Attributing a shared cost to whoever
happened to key it in would quietly load their sheet with the team's spending,
and nobody would notice until a claim was queried.

**The common pot is reported, never divided.** Nobody asked for it to be split
between travellers, and inventing a division would put money on somebody's
sheet that was never agreed with them.

An expense tagged to somebody who is not on the trip still counts, and still
shows against them: the tag is a statement about whose money it was, and
dropping it would lose the amount entirely.

The phone offers the choice only when somebody else is on the trip, shows whose
each expense is, and breaks the money down by traveller. The dashboard adds a
"Whose" column to the trip's expenses and an "Own expenses on shared trips"
figure to the range summary — a lunch a rep bought on a colleague's trip is
their money and belongs on their row, not on the trip owner's.

*Pinned in `fixtures/trip_sharing.json`; both suites read the same 20 cases.*

---

## Combining orders lives on the dashboard only — **decided 20 Aug 2026**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| Who may combine | ~~"Close the week", production dashboard~~ → **nothing** | **Dispatch Planning**, when the van is sent |
| Trigger | ~~a closed week~~ | one dispatch |
| Reads groups | yes — My Orders collapses them | yes — Combined Orders |

**This is a deliberate one-sided rule, not drift. Do not "fix" the phone by
giving it a way to combine again.**

Both apps used to implement the identical weekly grouping, independently — the
exact duplication this file exists to catch. Combining is now something a
**dispatch** does: a week was what the office closed, a van is what the
customer received, and two of a customer's orders arriving together are one
delivery to them. There is one place a van is sent from, so there is now one
place that combines, and nothing left to drift against.

The phone keeps the whole **reading** half — a group still collapses into a
single row in My Orders — and lost only the ability to create one.

**Only orders the dispatch finishes are grouped.** `Sales Order
.custom_combined_order` holds a single Link, so an order carried by two
dispatches could point at only one of them; whichever wrote second would move
it out of a group whose count and total then said something untrue. A
part-loaded order therefore waits for the van that clears its remainder. And a
customer with fewer than two finished orders gets no group at all — one order
is not a combination, and the weekly close's groups of one only ever gave the
rep a second name for something that already had one.

*Pinned in `fixtures/combined_order.json`. Unusually, `client/` alone reads it;
the `about` field says so, and says why.*

---

## The minimum held back is a dashboard figure — **decided 21 Aug 2026**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| Units available | **shown** | **shown** |
| The minimum to hold | ~~shown~~ → **hidden** | **shown** (Minimum column) |
| Batch dates / ages / dead-stock risk | ~~shown~~ → **gone** | ~~shown~~ → **gone** |

**Deliberate, on both counts. Do not "fix" the phone by putting the minimum
back.**

A rep quoting the held-back level to a customer is describing how the company
runs its shelf rather than what they can sell. Reps get the available number
and nothing else; the sales, production and stock screens on the dashboard keep
the minimum, because deciding it is their job.

**The dead-stock feature was removed from both sides**, not hidden on one:
batch-age columns, aging filters, "clear this first" badges, substitution
panels, and the sorts that ranked lists by staleness. The dated
`Manna Minimum Stock Batch` records are untouched in ERPNext and still add up
to what is on the shelf — nobody is asked to make a decision about how old they
are.

Oldest-batch-first allocation **stays**. Rubber is better sold in the order it
was made, and that never needed anyone to see a date.

The rule itself survives unshown in `app/lib/models/min_stock.dart`
(`isDeadStockRisk`, `isSlowMoving`) with its tests, so turning it back on is a
decision rather than a re-derivation. The dashboard's `domain/aging.ts` was
stripped to what is still load-bearing and renamed `domain/stockLevels.ts`.

---

## The duplicate-order warning is phone-only — **decided 21 Aug 2026**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| Warns on a duplicate | **yes**, in My Orders | not yet |
| Dismissing it | **yes**, writes to the order | — |
| Times edited | **shown** to rep, sales manager, production | **shown** on the production queue |

**Not drift — a gap with a reason.** The warning exists because a rep in a shop
with bad signal raises the same order twice; My Orders is where they would
notice, and the dashboard has no equivalent list of *my* orders. The dashboard
takes orders too and could adopt the same rule, which is why the rule lives in
`fixtures/duplicate_order.json` as data rather than buried in a Dart file.

**It is worked out when an order is SAVED, never while a list renders.**
`Sales Order Item` cannot be listed directly on this site — it answers 403, see
`app/CLAUDE.md` §4 — so there is no way to ask "which open orders contain this
item". The app computes the overlap while it still holds the lines and stores
the answer on `custom_duplicate_of`. Capped at the customer's ten most recent
open orders, because each one costs a document read.

**Only open orders count.** A customer who buys the same tread every month is
not making a mistake, and warning on their history would train reps to dismiss
the thing blind — which is worse than never showing it.

Dismissal is stored on the order (`custom_duplicate_ignored`), not on the
phone, so it stays dismissed on every device and after a reinstall.

---

## GM credit conditions — **phone-only 22 Aug 2026, closed 7 Sep 2026**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| GM attaches a condition on approval | yes | yes |
| Rep responds | yes — customer screen **and** My Conditions | n/a, reps have no login here |
| GM closes or sends back | yes | yes, on the GM queue |

**This divergence is closed.** Both apps now read and write
`Manna Credit Condition`, and both enforce the same rule from
`shared/fixtures/credit_condition.json`. The section below is kept because it
records *why* the feature exists, which is still the reason to be careful with
it.

**A gap with a reason, not drift.** An over-limit order escalates to the
general manager, who usually says yes *on terms* — clear the sixty-day
outstanding by the fifteenth, collect a cheque first. None of that was recorded
anywhere: the approval went through, the terms lived in a phone call, and
nobody was accountable afterwards.

The GM now types the condition at the moment of approval and it lands on the
customer, owned by the rep who raised the order. `Manna Credit Condition` on
the live site holds it: customer, rep, order, the GM's own words, a due date
and a status of Open → Awaiting Review → Closed.

It was phone-only at first because that is where the GM approved. On
7 September 2026 the dashboard adopted the same records, because the sales
manager raises the escalation there and the GM answers it there — a GM who
could set a condition on the dashboard but only close it on the phone would
leave reps answering into silence.

**The rule lives in one place per language now**:
`app/lib/core/credit_condition.dart` and `client/src/domain/creditCondition.ts`,
both pinned by `shared/fixtures/credit_condition.json`. Change the fixture and
both, in the same commit.

**Only the GM closes one.** The rep answers and it moves to Awaiting Review.
The person under an obligation declaring it satisfied is not accountability,
so the close is the GM's alone — enforced in `Api.decideCondition` as well as
hidden in the UI, because this site has no Server Script behind the screen.

**It blocks nothing.** No order is refused because a condition is open or
overdue. A rule that stopped a rep selling in front of a customer over an
obligation somebody forgot to close would cost more than it saved. Teeth can
be added once there is evidence of how conditions behave; the options
considered were a warning to the sales manager at approval, and forcing
re-escalation to the GM.

---

## An approved Sales Order is a draft, not a submitted document — **decided 10 Sep 2026**

Not a divergence between the two apps — they agree, and always have. It is the
apps against their own contract, found when the SAP order sync was first run.

| | Written in the contracts | What both apps actually do |
|---|---|---|
| On approval | "submitted at approval" — `shared/SAP_ORDER_SYNC.md`, `app/server/PWA_HANDOFF_MANAGERS.md`, `dca0c03` | PUT `custom_po_status` + `custom_rate_approved`; **no submit**, order stays `docstatus = 0` |

Neither `app/lib/services/api.dart` (`approveSalesOrderPO`) nor
`client/src/api/client.ts` (`decideSalesOrder`) contains a submit call, and
`createSalesOrder` raises the order as a plain draft. Several handoff documents
nonetheless assumed submission, and the SAP sync's first cut gated on
`docstatus == 1` — so it matched nothing.

**Decided: the apps are right, the contract was wrong.** Approved orders stay
drafts, and there is a reason to leave it that way: after approval a rep can
reopen an order to fix a quantity and it goes back for approval
(`updateOrderLines`, `_keepDiscounts`, and `decideSalesOrder`), which
**replaces the `items` child table**. Frappe forbids that on a submitted order —
`qty`, `rate`, `discount_percentage` are not `allow_on_submit` — so submitting
at approval would break the post-approval edit flow on both sides.

**What changed:** the SAP sync now gates on `custom_po_status ==
"PO Approved - Ready for SAP"` **and `docstatus < 2`** (live order, not a Frappe
cancel). `shared/SAP_ORDER_SYNC.md` updated to match. No app code changed —
neither app filters SAP intake by `docstatus`, and no fixture pins it.

**If orders should ever really be submitted** (it would enable Frappe's own
cancel — `docstatus 2` — which `fixtures/production_order.json` already assumes),
it is its own piece of work: the post-approval edit flow must move to
cancel-and-amend or lock line edits, and submit runs India Compliance / GST /
credit validations a draft skips. Do it deliberately, in both apps plus the
fixture, not as a side effect.

---

## HR changes a leg's vehicle on the dashboard only — **decided 15 Sep 2026**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| Rep edits a leg | vehicle number, readings, photos — **not the mode** | — |
| HR changes the mode | **nothing** | **Change vehicle**, on Odometer Check and on a trip |
| Totals after the change | recomputed on the rep's next save | recomputed in the same write |

**Deliberately one-sided. Do not give the rep a way to change a leg's mode.**
The mode is the rate: a rep who could move their own leg from Bike to Own
Vehicle could double their claim on it. HR is who corrects that, and HR works
on the dashboard.

What must still agree, and does:

- **The totals.** The write goes through the same recompute as `verifyLeg`,
  which is `fixtures/trip_totals.json` — the rule both apps already test.
- **The list of modes, and which have an odometer.** `LEG_MODES` and
  `modeHasOdometer` in `client/src/domain/trips.ts` are the phone's "Start
  vehicle leg" list and its `isOdoMode`. Add a mode to one and add it to the
  other, or a leg HR sets will read as having no odometer on the phone.

The distance is carried across the change, not recomputed: a change of vehicle
is a change of rate, not of journey. A leg moved to a mode with no odometer
keeps the kilometres it had, including a reading HR had corrected. The approved
amount is left alone and the dialog says so. See `withVehicle`.

## SAP owns the booking; the minimum-stock pool is gone — **decided 17 September 2026**

**Removed from both sides in one commit**, so nothing below is a divergence —
it is recorded here because it deletes rules that several fixtures and both
`CLAUDE.md` files still pointed at, and somebody will want to know why.

### What went

`Manna Minimum Stock Item`, `Manna Minimum Stock Batch`, `Manna Stock
Reservation` and `Manna Production Order`, and with them:

- the **booking protocol** — the client-side compare-and-swap on the pool's
  `modified` that stood in for the row lock a Server Script would have given
  us (`app/lib/services/stock_service.dart`, `holdFromShelf` in
  `client/src/api/client.ts`);
- **minimums** and everything measured against one: below-minimum, shortfall,
  dead stock, replenishment urgency, the fill meters, the low-stock nav badge;
- the **production run** as a second pool with its own claim counter;
- **Flow A** of `shared/PRODUCTION_FLOWS.md`, replenishment;
- the **split of a line into two halves** — the part a reservation covered and
  the part being made — each with its own stage, its own sequence and its own
  field (`custom_stock_stage` is now written by nothing);
- four screens: the production manager's Minimum Stock, the stock manager's
  Ledger and Replenishment, and the Flutter replenishment-receiving screen.

### Why, in three findings against the live site

1. **No item had a minimum.** All 129 `Manna Minimum Stock Item` rows carried
   `qty = 0`, so every alarm built on the minimum was comparing against zero
   and could never fire. The dashboard's older `MinStockItem` path was worse:
   the doctype has no `onHand` or `threshold` field at all, so both read
   `undefined`.
2. **The batches were beating SAP.** The 129 batch rows were a hand-typed
   snapshot dated 10 September 2026, and `StockService.load()` skipped the
   warehouse fill for any item that had a pool row — so those items showed a
   week-old hand count instead of live stock.
3. **The deduction was happening twice.** SAP commits its own sales orders'
   lines when they are placed, and `Sync-HitechStockToTreads.ps1` writes back
   *available to promise* — on hand less committed. Subtracting an ERPNext
   reservation on top took the same roll off again.

### What replaced it

One figure per item, from `Bin.actual_qty` in `Finished Goods - MT`, converted
out of kilograms by `stockFromKg` and refreshed by the five-minute SAP stock
sync. `MinStock` on the phone and `MinStockLine` on the dashboard carry it, and
neither app writes anything.

### What is weaker, and was accepted

**The window.** The apps see SAP on a five-minute delay, so two reps can be
shown the same eight rolls inside one cycle. Nothing closes that: the order is
accepted, pushed to SAP, and SAP refuses or short-ships it. That is a worse
experience than the old local refusal and a better answer, because the old one
was confidently wrong about stock it could not see — it knew nothing of orders
placed in SAP directly.

### What deliberately survives

- **`custom_fulfilment_mode`** ("From Minimum Stock" / "From Production Run" /
  "New Production"). It is a note for the floor and moves no stock; it still
  picks the shorter three-step cycle for a line served off the shelf, and
  `fixtures/production_order.json` still keys the cancel-after-production
  diversion off it.
- **`allocateFromPool`** and `fixtures/belt_from_roll.json`. A belt still comes
  out of a roll; the rule now governs a *display* — how much of a line the
  shelf covers — rather than what gets reserved.
- **Oldest-batch-first allocation** is not affected: it never needed the pool.

### The open one

**Items with no weights report nothing available**, on instruction — 250 of 369
stocked items today. `fixtures/stock_from_kg.json` carries both halves of that
decision: the conversion still refuses to guess (`unknown_not_zero`), and the
screens render the refusal as "weights not set", never as "none left". This is
a holding position while the weights are uploaded. **Revisit it once they are**;
if it outlives the upload it becomes a permanent blind spot over two thirds of
the catalogue.

---

## Discounts removed; the rep types the net rate — **decided 17 September 2026**

**Removed from both apps in one commit,** so this is not a divergence. It is
recorded here because items 1–3 at the top of this file — the founding
disagreement that caused the two repositories to be merged — were all about
discounts, and `fixtures/discount.json` is gone with them.

### What went

`domain/discount.ts`, `core/discount.dart`, both test suites, the fixture, the
per-line Discount control and its modal on the dashboard and the phone, the
before/after order totals, `setLineDiscount` on both sides, `_keepDiscounts`,
and the discount carry-over when a lead order converts.

### Why

The rate the rep quotes is now **the rate after discount**, typed at order
confirmation. One number on a line instead of three.

The trigger was SAP. The sync had to start sending the approved price (see the
entry above this one), and `custom_rate_per_kg` turned out to be the rate
*before* the discount — `SAL-ORD-2026-00135` carries 25/kg against a 10%
discount and a real 22.50/kg. Rather than teach a second system about a
three-number pricing model, the model was reduced to one number.

### What reaches SAP

`UnitPrice = amount / custom_total_weight`, `DiscountPercent` always **0**.
Derived from the line amount rather than the rate, which also prices the legacy
discounted lines correctly without knowing anything about discounts — the
amount was always the net figure. `Sync-SapOrders.ps1`, `New-SapOrderLine`.

### The data that already exists

Nothing was migrated. One order on the site carries a discount
(`SAL-ORD-2026-00135`, both lines at 10%) and zero lead orders do. Those lines
keep their stored `discount_percentage`; nothing displays or re-applies it, and
their `amount` was always net, so every figure derived from them stays right.

New writes zero `price_list_rate` to the rate and `discount_percentage` /
`discount_amount` to 0 **explicitly**, rather than leaving them alone, so
ERPNext's own pricing cannot derive a phantom discount from a stale price-list
rate left on a row.

### What is weaker

**Nothing records that a concession was given.** The business could previously
see what it had given away — per line, per order, and in a "3 of 5 lines
discounted" summary. A net rate typed by a rep looks identical to a full-price
rate typed by a rep. If someone later asks "how much are we discounting", the
answer is no longer in the system, and reconstructing it would mean comparing
every line against a price list that covers 29% of the catalogue.

That was accepted deliberately. Revisit it if margin reporting is ever wanted.

## The team-orders filter is dashboard-only — **18 September 2026**

`orderBucket` and `ORDER_BUCKETS` exist in `client/src/domain/sapOrderState.ts`
and have **no Dart twin**. That is deliberate and is not a rule divergence.

The rule it composes — **cancellation outranks the approval status** — is
already implemented on both sides, as `orderPill` in the dashboard and
`orderApprovalLabel` in the phone, and the two agree. `orderBucket` only sorts
orders into the four piles a *sales manager* filters by, on a list screen the
phone does not have. A filter control is the cosmetic kind of difference this
file's header says is fine.

**If you ever add that filter to the phone**, do not write the precedence
again. Take it from `orderApprovalLabel`, which already has it, and keep this
order:

1. cancelled in SAP
2. rejected
3. approved
4. everything else, which is what the manager owes a decision on

Getting 3 before 1 is the trap: a cancelled order still carries
`custom_po_status = "PO Approved - Ready for SAP"`, so testing approval first
files it under Approved while its own pill reads CANCELLED IN SAP — two answers
to the same question on one screen. `sapOrderState.test.ts` pins it.

Also note `to_approve` is **not** `awaitingManager`. That predicate counts
`Rejected` as still owing a decision, which is right for the header count
because the rep will resubmit, and wrong for a filter a manager uses to find
what they can act on now.

## Stock without weights: kilograms on the dashboard, absent on the phone — **decided 24 September 2026**

An item whose SAP master lacks belts-per-roll or weight-per-roll cannot be
converted from kilograms (`stockFromKg` refuses, and still does). Until today
both apps listed those items and said "weights not set" / "stock not set up".
On 24 September 2026 that was 265 of 443 stocked items, about 34,760 kg —
most of the list, and all of it unreadable.

The instruction, and how each side carries it out:

| Who | Item with both UDFs | Item missing either |
|---|---|---|
| Sales manager, dashboard Stock page | rolls + belts | **shown, in kilograms** (or its own unit if not Kg) |
| Stock / production manager, dashboard | rolls + belts | not shown |
| Everyone on the phone's stock list | rolls + belts | not shown |

`client/src/domain/stockView.ts` (`stockReading`) and
`app/lib/models/min_stock.dart` (`shownAsRollsAndBelts`) are the two sides.
**This is a display rule, not a promise rule.** Neither app treats a
kilogram figure as promisable: `shelfAvailable` still reports nothing for
these items, the order screens on both sides still say "Stock not set up" on
the line, and the split still sends the whole line to production. That is
why the two apps can differ here without a fixture — nothing either one
*commits* to has changed.

**Why the phone never shows kilograms**, even to a manager holding it: a rep
reads stock to decide what to promise, and a kilogram figure beside a roll
count invites dividing it in your head and quoting the answer — the exact
guess `stockFromKg` exists to refuse. The sales manager is shown it because
they are the one who can get the two UDFs filled in on the SAP item, and the
dashboard tells them how many items their reps cannot see.

**The fix is data, not code.** Fill `U_BeltsPerRoll` and `U_WeightPerRoll` on
the SAP item; the products sync (`Sync-HitechProductsToTreads.ps1`, not the
stock sync) copies them to ERPNext, and the item appears on every screen as
rolls and belts. If that upload stalls, this rule has hidden most of the
catalogue from the field permanently — see the 17 September entry above.

### Found at the same time: the dashboard's stock page had been blank since 18 September

Not a divergence, but it is why this was noticed. The stock sync began
carrying every finished-goods item on 18 September; the warehouse went from
130 rows to 443; and the dashboard joined them to `Item` with one
`name in (...)` over every code. Frappe Cloud refuses a request line over
about 4 KB with a bare nginx 400 — measured: 240 codes pass, 250 fail — and
the read's `.catch(() => [])` turned that into "SAP has nothing available to
promise". The order pages lost their stock chips the same way. Fixed with
`listDocsIn` in `client/src/api/client.ts`, which splits the list. The phone
reads `Item` unfiltered and was never affected. **Any new `in` filter over a
list that grows with the data must go through `listDocsIn`.**

---

## The rep's credit commitment — **built on both, 24 September 2026**

An over-limit order now carries the customer's promise from the counter to the
GM, and the GM's approval turns it into the rep's credit condition. **Pinned by
`fixtures/credit_commitment.json`**, implemented in
`app/lib/core/credit_commitment.dart` and `client/src/domain/creditCommitment.ts`.

**The GM approves; the sales manager pushes to SAP** (second pass, the same
day). The flow is:

    rep raises it ─► Pending Approval ─► sales manager: Send to GM
      ─► Pending GM Approval ─► GM approves (condition made)
      ─► Pending Final Approval ("Approved by GM") ─► sales manager: Push to SAP
      ─► PO Approved - Ready for SAP ─► SAP

`Pending Final Approval` was already an option on `custom_po_status` and nothing
used it; the SAP sync's gate is an exact match on `PO Approved - Ready for SAP`,
so a GM approval cannot reach SAP by any path. Whose approval it was is in
`custom_gm_approved_by` / `custom_gm_approved_on`.

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| Rep writes the commitment when the order will escalate | yes — required, on Send for Approval, and carried by an unsent draft | n/a — see below |
| Sales manager sees it, may comment | yes — order review | yes — order review |
| Sales manager may approve an over-limit order before the GM has | **no** — Send to GM or Reject | **no** — Send to GM or Reject |
| GM sees it and every comment, may edit, comments, approves the credit | yes — GM queue and order review | yes — `/gm/orders/:id` |
| GM pushes to SAP | **never** | **never** |
| GM approval makes the condition, reworded but never dropped | yes | yes |
| Sales manager sees "Approved by GM" and pushes, at the GM's rates | yes — Push to SAP on the review | yes — Push to SAP on the review |
| GM may withdraw the approval before the push (closes the condition) | yes — Withdraw approval | yes — Withdraw approval… |
| Rep and sales manager may change an order once it is escalated (26 Sep 2026) | **no** — GM only while it is with the GM | **no** — GM only while it is with the GM |
| Anyone may change a GM-approved order (26 Sep 2026; it used to go back to the GM) | **no** — push or reject only | **no** — push or reject only |
| Rep sees the condition with the comments | yes — My Conditions | n/a, reps have no login here |

**The dashboard does not capture a commitment, and that is not drift.** Reps
raise orders on the phone. The dashboard's `TakeOrderPage` still runs on the
fixture-era Redux path: `createOrder` in `client.ts` posts a mock-shaped object
that cannot become a real Sales Order. If that page is ever wired to ERPNext it
must ask for the commitment exactly as the phone does — `commitmentRequired`
and `commitmentProblem` are already there to call.

**What changed that was not asked for, and why:**

- **The sales manager's approval gate moved into the API on both sides.**
  `Api.approveSalesOrderPO` / `escalateSalesOrderPOToGM` (phone) and
  `Api.sales.decideOrder` (dashboard) re-read the order and the customer and
  refuse a sales manager's approval of an over-limit order. Before this, only
  the button was swapped; a stale screen could still approve one.
- **Editing an escalated order keeps it with the GM.** The dashboard's
  `saveOrderLines` reset every edit to `Pending Approval`, which would have
  thrown an order the GM was editing out of their own queue and into the sales
  manager's — who may not approve it. The phone's edit already left the status
  alone unless the order had been approved.
- **The GM's condition dialog is one widget on the phone**
  (`widgets/gm_condition_dialog.dart`), used by the queue and the review, and
  backing out of it no longer counts as "approve, no condition".
- **The dashboard GM opens no team screen.** `screensForUser` gives the GM
  nothing; the sidebar and the routes both read it.

**What is weaker, and was accepted:**

- **No Server Script behind any of it.** Like every rule here it is enforced in
  both clients and nowhere else; ERPNext will accept a `Pending GM Approval →
  PO Approved` write from anyone with Sales Order write access. This is the
  obvious first candidate for a Server Script now that the plan allows one — a
  Before Save on Sales Order that refuses `PO Approved - Ready for SAP` on an
  over-limit order unless the stored status was `Pending Final Approval`, and
  refuses `Pending Final Approval` unless the user holds `Higher Management`
  (which only the GM does).
- **A condition that fails to save after an approval is offered as a retry,
  not guaranteed.** The approval stands either way — the older rule, kept
  deliberately.
- **The condition exists before the order is in SAP.** It is made at the GM's
  approval, which is the credit decision, so the rep can start on the promise
  at once. The gaps that opens are closed in code: a re-approval after an edit
  reuses the open condition rather than making a second, and a GM rejection —
  including withdrawing an approval before the push — closes it. The sales
  manager cannot reject a GM-approved order, so no other path leaves one
  orphaned.
- **Comments are not editable or deletable** by the managers who wrote them
  (`Manna Credit Comment` grants Sales Manager read + create only). A comment is
  part of the record the GM decided on.

### The GM's follow-up — **dashboard only, 25 September 2026**

After the GM approves, the order leaves "Escalated to you" and lands in a
separate **Follow-up** view (`/follow-up`, and `/follow-up/:orderId` for one
order): every order the GM approved, what SAP has made of it (SAP order number,
status, invoice), its condition, and the whole conversation. The GM closes or
sends back conditions there and may add notes at any stage. Pinned in
`fixtures/credit_commitment.json` → `follow_up`; the sorting is
`client/src/domain/followUp.ts`, tested on its own.

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| Rep's answer is written to the order's thread (`author_role` Sales Rep) as well as to the condition | yes — My Conditions and the customer screen | n/a, reps have no login here |
| GM's send-back note is written to the thread | yes | yes |
| Follow-up view | no — the GM follows up on the dashboard | yes |
| Rep reads the thread under the condition | yes, their own answers as "You" | n/a |
| Rep's own order screen shows where the follow-up stands | yes — a two-line card (status, due, message count) linking to that order's row on My Conditions, scrolled to and outlined; the conversation itself stays there | n/a |

**Why the phone has no follow-up screen, and that is not drift:** the GM's
follow-up is desk work — reading SAP numbers, invoices and a conversation —
and the GM was given the dashboard for it. The shared parts (who writes under
which role, who may add a note) are in the fixture, so if the phone gets one it
starts from the same rules.

**Schema, 25 Sep 2026:** `Manna Credit Comment.author_role` gained `Sales Rep`,
and Sales User gained **create** on the doctype (still no write or delete), so a
rep's answer can reach the order.

## Production status is SAP's; the stage picker is gone from both apps — **decided 25 September 2026**

Until today a production manager moved each order line through its
product's stage cycle by hand (a dropdown on the dashboard's production
order page and a "Move to stage" picker on the phone's), writing
`custom_production_stage` on the line and rolling `custom_production_status`
up onto the order. **Removed from both apps**, on instruction: the status
comes from SAP's own sales order → invoice loop and nobody sets it in the
app.

Both sides now read, from `sapOrderState` (pinned by `sap_order_state.json`):

| | Order | Line |
|---|---|---|
| SAP has it, not invoiced | Pushed to SAP | Pushed to SAP |
| Invoiced | Dispatched | Dispatched once *its own* invoice exists |
| SAP cancelled it | Cancelled in SAP | Cancelled in SAP |

Where: `client/src/features/production/ProductionOrderPage.tsx`,
`app/lib/screens/production/production_order_detail_screen.dart`, and the
rep's `app/lib/screens/orders/order_detail_screen.dart` item card, which had
still been printing the raw stage ("Being made: Curing") beside a SAP-fed
production section that could contradict it. The writers are deleted:
`setProductionStage` and the fixture-era `setItemStage` (dashboard, plus the
unreachable `ProductionBoard` / `ProductionOrderModal` that used it) and
`Api.setItemStage` / `Api.setProductionStatus` (phone).

**Old stage values stay in the database** and nothing displays them. The
pure stage functions (`domain/production.ts` / `core/production_stages.dart`
and `production_progress.json`, `rollUp` / `Api.rollUpStage`) are left in
place and still tested; no screen uses them for status any more. Delete them
from both sides in one commit if Dispatch Planning is not coming back — its
parked "record a dispatch" code (`client.ts`) still writes
`custom_production_stage = Dispatched` and would start again if the page were
re-enabled.

### The production queue differs between the apps — a scope difference, not a rule

- **Dashboard** (24 Sep): lists orders **SAP has** (a SAP sales-order number),
  cancelled ones kept and marked; weekly filter by the week raised.
- **Phone**: still lists orders at `PO Approved - Ready for SAP`, as before,
  now with SAP's status on each row and cancelled ones marked.

Nothing is promised or priced off either list. Bring the phone into line if
asked — use `inProductionQueue` / `queueState`'s rule (`reachedSap`), not a
new one.

## Manna Treads' SAP rates at order entry: phone only, **25 September 2026**

The user asked that reps see Manna Treads' SAP rates while taking an order,
for the test items and test dealers first.

**One implementation, on the server.** The rule is in the ERPNext Server
Script `manna_customer_rates`, not in either app, so the two can never price
an item differently. For an item, the rate is:
- the dealer's special price in Manna Treads' SAP, when SAP holds one that is
  switched on;
- otherwise the Price List 01 ("selling price") price, when that is the
  dealer's price list.

Prices are per kg and GST-inclusive, as SAP holds them. The rates come from
the copy of SAP that `sap-pricing/Sync-SapPricingSnapshot.ps1` writes into
`SAP Pricing Control`. The script answers only the customer's own rep or a
manager, only for a Manna Treads customer (`custom_bp_code` is a Treads code
only there), and for now only for Manna Treads item group `ZZ - Test`
(`ONLY_GROUP` in the script).

**Phone:** `app/lib/models/sap_rates.dart`, `Api.getSapRates`, the order
screen and `ProductRow`. **An item with an SAP rate is sold at it, and the
rep cannot change it** (the user, 26 September 2026: the rep must not edit
"the rates that are there in the list or are there from special rate of the
business partner"). The screen fills the rate in and locks the box. On
25 September the rate was only a hint with a "Use" button, and the box stayed
open.
- A line the manager already approved keeps its approved rate.
- An item SAP does not price is typed by hand and never prefilled, as before.
  Today that is every item except the 10 test items.
- The lock holds on the phone for everyone who edits there, managers
  included.

The banner above the list speaks only once an item with a rate is on the
order. While only the test items are priced, every Treads customer gets
rates, and a banner on every order screen would describe rows that are not
there.

**The dashboard does not lock them.** A manager editing lines in
`OrderLinesEditor` can still type any rate. It has never shown an SAP rate.
Whether a manager may move an SAP-priced line is for the user to decide.
Until they do, it stays as it was.

**Leads are taken at the list price** (the user, same day). A lower price for
a lead goes through Higher Management, and becomes a special price once the
lead is a customer. So `manna_customer_rates?lead=` answers Price List 01
only, with `list_only = 1`. The lock is the same as for a customer, and
only the line under the box differs. With no answer at all (no signal),
every item is priced by hand as before.

**Neither lock is enforced on the server yet.** A `Sales Order` or
`Lead Order` written straight to the API at another rate is accepted. For a
lead order a check would need the per-kg rate, and `Lead Order Item` holds
only the per-roll `rate`. Turning that back into a rate per kg repeats the
roll-weight arithmetic in `product_category.dart`, a third copy. A Sales
Order line does carry `custom_rate_per_kg`, so a `Before Save` check against
`manna_customer_rates` is possible there. It is not written yet, because it
would also refuse the dashboard's manager edits above. The dashboard does not
enter lead-order rates at all: it reviews, approves and converts.

**Who may read a dealer's special prices.** The script trusts two Customer
fields a rep can write: `custom_assigned_reps` (the phone writes it when a
rep creates a customer) and `custom_bp_code` (no app writes it). So special
prices are given only when the ERPNext customer's name is SAP's name for that
code, and no other ERPNext customer carries the code. That stops a rep from
copying a dealer's code onto a customer of their own. It does not stop a rep
from pointing a real dealer's `custom_assigned_reps` at themselves. That
closes only when `custom_bp_code` and the assignment are writable by the
office alone, which is a permission change for the user to decide. It matters
once `ONLY_GROUP` is cleared; today the answer is the 10 test items.

**Dashboard: not yet.** Its managers price orders in `OrderDetailPage`,
`GmOrderPage` and `OrderLinesEditor`, none of which shows an SAP rate. Asked
for the phone first. Showing it there is a call to the same script: the rule
must not be written again in TS.

Neither app reads ERPNext `Item Price` for this. Reps cannot read it, and its
18 rows are ERPNext copying typed order rates into its own list
(`auto_insert_price_list_rate_if_missing`), not SAP prices.
## Stage two: what only the office sync refuses — **26 September 2026**

The billing rule itself is not a divergence. What the Manna Treads order bills,
at what price, rounded how, and which state an order is in is
`fixtures/manna_treads_reorder.json`, implemented by the dashboard
(`assessOrder` in `client/src/domain/mannaTreadsReorder.ts`) and the sync
(`Get-MtReorderPlan` in `sap-order-sync/Sync-SapOrders.ps1`), both tested
against it. The two round identically (`roundTo` / `Get-RoundedHalfUp`,
checked bit for bit) and both fix GST at 18%, rate-inclusive.

**The sync refuses more than the rule does, and the dashboard does not know
in advance.** These checks exist only in the sync's PASS C:

| Refusal | Why only the sync |
|---|---|
| an item not on `manna_treads.item_allowlist` (by default the ten SYNC TEST items `I-14636`..`I-14645`) | the list is the sync's config; it exists because of what Manna Treads SAP holds |
| an item whose Manna Treads `ItemName` differs from the ERPNext line's `item_name` | only the sync can read Manna Treads SAP's items |
| an item code on two lines of the order | it follows from how PASS B attributes Hi-Tech's kilos (by item code), which only the sync does |
| a billable line with no approved price (`rate <= 0`) | the last guard before SAP would price the line from its own list |
| the customer missing, not a customer, inactive or frozen, billed outside Kerala, or **named differently there** (`CardName` against the ERPNext `customer_name`) | only the sync can read Manna Treads SAP's business partners |
| SAP refusing the POST itself | only the sync posts |
| **asked for by someone not in `manna_treads.approvers`** (`custom_mt_so_requested_by`) | the request fields are permlevel 0, so the flag can be set without `manna_mt_so_request`; the sync is the last thing before SAP. The dashboard never sets them itself — it calls the script |
| **another live ERPNext order on the same Hi-Tech SO** | a Desk *Duplicate* copies `custom_sap_sales_order`; the dashboard lists one order at a time and does not look for its twin |
| **Hi-Tech's own order not backing the recorded kilos** — not found, its `NumAtCard` naming another order, not closed now, dated before the scan windows, an item on two of its lines or on a line the ERPNext order lacks, kilos recorded for an item not on it, or kilos changed since recorded | only the sync reads Hi-Tech SAP. PASS B matches Hi-Tech's lines to rows by item code and skips what it cannot match, so those kilos are simply missing from the rows the dashboard reads — it would show the order *ready*, short |
| **delivered, and part invoiced straight from the order** | see below: a stopgap for the rule, not a second rule |

**The one row that is really a question about the rule.** The fixture's
`delivery_wins` bills an order with any delivery on its deliveries alone, and
says counting invoiced kilos too would bill them twice. It would not:
`custom_hitech_invoiced_kg` counts only invoice lines drawn **straight** from
the sales order, never one drawn from a delivery, so on a delivered order it is
always goods that left without a delivery note (a line invoiced direct, or the
rest of a part-delivered line — SAP copies only the open quantity). Both sides
implement the rule identically and would both bill such an order short. Until
the rule is decided — bill `delivered_kg + invoiced_kg` per line, or keep
refusing — the sync refuses the order and the dashboard shows it *ready*. Deciding
it means changing the fixture's `delivery_wins` and its case "delivered AND
invoiced", the dashboard's `assessOrder` and `Get-MtReorderPlan` in one commit;
the refusal (`Test-MtMixedBasis`) then goes.

The dashboard therefore offers such an order as *ready*, the accountant
approves it, and the sync refuses it. **That is the intended flow, not drift.**
The refusal is written on the order (`custom_mt_sync_error`, the request flag
left set), which is the fixture's `failed` state: the dashboard shows it under
*Failed* with the sync's own words and **Try again** (`mayRequest('failed')`).
Try again calls `manna_mt_so_request`, which clears the error, so the sync
takes the order once more; the sync never retries a failed order by itself. A
refusal does not fail the order-sync run — only a transient failure (network,
login, SAP 5xx, an ERPNext read or write) does, and that writes nothing on the
order.

If the dashboard is ever given any of these checks up front — the duplicate
lines and the price are visible to it — it must use the sync's words and must
**add to** the sync's check, never replace it: the sync is the last thing
before Manna Treads SAP, and a check that exists only on a screen is not a
check.

**The accountant has no phone twin.** `syncsFor` in
`client/src/domain/syncScope.ts` gives `role === 'accountant'` the order sync
only. `app/lib/core/sync_scope.dart`, its Dart twin, has no such branch
because the phone app has no accountant role; if an accountant login ever
reaches the phone, add the branch there in the same commit.

---

## The manager workspace on the phone — **decided 11 Oct 2026**

Managers approve from their phones, so the phone was given the dashboard's
manager screens: a summary, Team Orders with the same filters, the order
review (now with Undo rejection and a note for the GM), Location Checks,
Attendance Corrections, Customers and Leads with route setting, and Sync.

**Who sees what is now one rule.** Until today the phone offered every
manager the order pipeline while the dashboard offered it to Pareeth's team
only. Both read `fixtures/manager_scope.json` now (`core/manager_scope.dart`,
`domain/sales.ts`).

**Where the phone deliberately has more:**

- **Leave approvals.** Reps apply for leave on the phone with their sales
  manager as the approver (`approver_type = Sales Manager`). The dashboard has
  no sales-manager leave screen, so the phone is the only place those requests
  are decided. Removing it would strand them.
- **Targets and outstanding limits.** Phone-only since before the dashboard
  existed; nothing on the web replaced them.

**Where the dashboard has more:** Export to a spreadsheet, the decided /
revoke view of attendance corrections, and assigning an owner in the pooled
UAE unit. None of those decides money or approval.

**Found while doing it:** the phone read a lead order as decided only when its
status was `Approved`. The dashboard writes `Converted`, so a lead order
approved on the web was offered for approval again on the phone, which would
have raised a second Sales Order. `orderSignedOff` now accepts `Converted`,
and `Api.approveLeadOrder` refuses an order already signed off.
