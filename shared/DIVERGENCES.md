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
