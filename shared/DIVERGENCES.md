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
