# Production: the two flows

Written 18 August 2026, before building. Records the decisions taken so the
schema work is one paste and the code is not designed twice.

## The rule that separates them

Goods produced go to **one of two places**, and which one is decided when the
production order is raised, never afterwards:

| | Raised for | Ends up | Who closes it |
|---|---|---|---|
| **A — replenishment** | the minimum-stock pool | **company stock** | the stock person marks it *received* |
| **B — against an order** | one customer's order | **the customer** | dispatch |

Stock produced for an order **never enters company stock**. That is the point of
the split: a roll made for Royal Tyres is Royal Tyres', not the shelf's, and
counting it as shelf stock would let a second customer be promised it.

**One exception, and it is the join between the flows.** If an order is
cancelled *after* its goods were produced, those goods divert to company stock —
they exist, nobody is waiting for them, and the alternative is a roll nobody
owns.

## Flow A — replenishment

1. The production manager opens a list of minimum-stock items showing **live
   stock against the minimum**. No trend column: he decides from the shortfall
   and his own knowledge of the market (decided 18 Aug).
2. He selects items and raises a production order.
   **Nothing is automatic.** Falling below the minimum does not raise anything;
   it only makes the row worth looking at. The decision is his alone.
3. The goods are made.
4. The **stock person** (`stock_manager`) sees the replenishment orders on a
   list of their own and marks one **received**.
5. Receiving **adds a batch** to `Manna Minimum Stock Batch` and the pool is
   replenished. It is an intake like any other, dated today, so it ages from
   the day it reached the shelf.

Reps see none of this. Removed 18 Aug — see the commit "Stop telling reps about
replenishment runs". A run is not sellable stock and carries no date, so
showing it only invited a promise nobody could keep.

## Flow B — against an order

1. An approved order needs goods that are not on the shelf.
2. Production is raised **attached to that order**, and the order's line carries
   its stage (already built — `custom_production_stage`).
3. When it is finished it is **dispatched** to the customer. It never touches
   `Manna Minimum Stock Batch`.
4. **If the order is cancelled after production**, the goods divert to company
   stock: the same receive step as flow A, adding a batch.

## What the schema needs

**Unverified: `Production Order Request` may not exist at all.**
`client/docs/ERPNEXT_DOCTYPES.md` is a *what-to-create* spec, not a record of
the site, and it lists `Sales Notification` the same way — which was proven
absent on 13 Aug, having silently swallowed every notification the dashboard
ever raised. Check before assuming.

`raiseReplenishment` in `client/src/api/client.ts` also writes **camelCase**
keys (`itemCode`, `raisedAt`, `raisedBy`, `sourceOrderId`). Those are not Frappe
fieldnames and would not match even if the doctype existed.

Fields the two flows need, whatever the doctype ends up being called:

| Field | Type | Why |
|---|---|---|
| `item_code` | Link → Item | |
| `qty` / `loose_belts` | Float / Int | belts matter for PCTR |
| `purpose` | Select: `Stock` / `Order` | **the flow selector.** Set once, at creation |
| `sales_order` | Link → Sales Order | required when `purpose = Order`, empty otherwise |
| `status` | Select: `Open` / `In Production` / `Made` / `Received` / `Dispatched` / `Cancelled` | `Received` is flow A's close; `Dispatched` is flow B's |
| `received_on` / `received_by` | Datetime / Link → User | who put it on the shelf |
| `batch` | Link → Manna Minimum Stock Batch | the batch receiving created, so the trail is followable |
| `raised_on` / `raised_by` | Datetime / Link → User | |

`purpose` is the field everything hangs off. It must be **set at creation and
never editable**, because changing it after the goods exist moves them between
two owners — the shelf and a customer — with nothing to reconcile against.

## Open, and worth settling before the code

- **Who is the stock person?** Taken as `stock_manager`, which already exists as
  a role flag. Confirm nobody separate is meant.
- **Does receiving create one batch per production order, or add to an open
  one?** One per order is simpler and keeps the trail; it also means the aging
  bands see the real arrival date. Assumed unless told otherwise.
- **Dispatch is still not built** for flow B, and is the larger gap. Until it
  exists, a delivered order's stock is never released and the shelf figure
  never falls — see the note in `app/CLAUDE.md` §7.
