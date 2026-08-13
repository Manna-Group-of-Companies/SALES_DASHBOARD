# Where the two apps disagree

Found on 13 August 2026, when the Flutter app and the dashboard were brought
into one repository and their per-line discount features — written the same
afternoon, independently — were compared.

**This file is the queue.** A row leaves it by being decided and turned into a
fixture in `fixtures/`, not by being forgotten.

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

## 1. How much may be taken off — **open**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| Ceiling | **50%** | **100%** |
| Out of range | **refused**, with a message | **clamped** — 150 becomes 100 |

Both positions have something right in them.

The dashboard is right that **100% has to be reachable**: a free replacement
roll is a real thing in this trade, and it is the one case where a line
legitimately reaches zero. The Flutter cap of 50% would refuse it. That cap was
invented without knowing the trade and is the weaker half of this argument.

The Flutter app is right that **an out-of-range number should be refused, not
clamped**. Clamping reads "150 means as much as possible", but the likelier
cause of 150 in a percentage box is a slip — and clamping turns that slip into
a free order, silently, which is the exact outcome a limit is there to prevent.

**Suggested resolution:** ceiling of 100%, and refuse anything outside 0–100
rather than clamping. Takes the trade knowledge from the dashboard and the
caution from the app.

*Needs a decision before it becomes a fixture.*

---

## 2. Can the GM change a discount after approval — **open**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| After approval | **nobody**, GM included | **GM may still override** |

This one is a genuine ambiguity in what was asked for, not a mistake by either
side.

- "For changing the rate, only the general manager can change the rate" — which
  is where the dashboard's GM override comes from, and it already existed for
  rates before discounts did.
- "Once the order is approved, there can be no change of the discount" — which
  is what the Flutter app implements literally.

A discount **is** a rate, so the two statements point opposite ways once the
order is approved. Whichever is chosen, both apps must do the same thing:
right now a GM can move a signed price from the web and not from a phone.

*Needs a decision. This is a question about who is allowed to do what, not a
technical one.*

---

## 3. Discounts on lead orders — **gap, not a conflict**

| | `app/` (Flutter) | `client/` (React) |
|---|---|---|
| Lead orders | supported | not implemented |

`Lead Order Item` is a custom child table with no standard pricing fields, so
the Flutter app added `custom_price_list_rate` and `custom_discount_percentage`
to carry the same two numbers, and the lead→customer conversion translates them
into the standard pair.

Nothing is wrong on the dashboard side — the feature simply is not there. It
matters only if managers review lead orders on the web. If they do, the fields
are already on the site and the conversion already handles them.

*Decide whether the dashboard needs it. No conflict either way.*

---

## 4. `discount_and_margin` is hidden in Desk — **known, no action**

A Property Setter hides the `discount_and_margin` section on `Sales Order Item`
(and `additional_discount_section` on `Sales Order`). Both predate this work.

They are cosmetic — they hide fields from the Desk form and change nothing
about what the REST API accepts or stores. Worth knowing for one practical
reason: **opening a discounted order in Desk will not show the discount**, so
Desk is not the place to verify one. Read it back over the API, or from either
app.
