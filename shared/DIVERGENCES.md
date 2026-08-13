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
