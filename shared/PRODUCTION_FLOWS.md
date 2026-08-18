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

## Settled, and built — 18 August 2026

- **`Production Order Request` did not exist**, confirmed by
  `ERPNEXT_LIST_DOCTYPES` — same as `Sales Notification`. `Manna Production
  Order` was created instead, following the site's `Manna <Thing>` naming
  convention, with exactly the fields listed above. `purpose`/`sales_order`/
  `status` etc. are the real fieldnames now; `raised_by`/`received_by` are
  `Data` (a display name), matching `custom_approved_by` and
  `custom_in_production_updated_by` rather than `Link → User`.
- **`raiseReplenishment`'s camelCase bug is fixed.** `client/src/api/client.ts`
  now writes through `PRODUCTION_ORDER_FIELD` (endpoints.ts), and
  `listProductionOrders` fetches explicit fields instead of sorting by a
  nonexistent `raisedAt` column.
- **Who is the stock person: a new user**, gated by a new `custom_is_stock_manager`
  Check field on `User` (did not exist — the other three role flags did).
  **Receiving happens on the stock manager's tablet, in `app/`** — new screen
  `ReplenishmentReceivingScreen` — not on the dashboard. The dashboard's own
  `ReplenishmentPage` ("Book in") was already built for the same role and has
  been fixed to work against the real schema too, so either surface works;
  the phone is the one the stock manager is meant to actually use.
- **One batch per production order — confirmed.** Both `recordReplenishment`
  (client) and `Api.receiveProductionOrder` (app) always `createDoc` a new
  `Manna Minimum Stock Batch`, dated today, never top up an existing one.
- **The cancel-after-production exception (flow B's join to flow A) is only
  partly wired.** `needsStockDiversion` / `alreadyDiverted`
  (`client/src/domain/productionOrders.ts`, `app/lib/core/production_order.dart`,
  pinned by `shared/fixtures/production_order.json`) and the `divertToStock`
  API primitive (`client/src/api/client.ts`) are built and tested. **No screen
  calls `divertToStock` yet** — neither app has a "cancel this order" action at
  all today (Sales Order cancellation is Frappe's own submit-cancel, docstatus
  2, done in Desk), and `client`'s own `Order`/`listOrders` plumbing was not
  audited far enough this round to trust wiring a button to it. Whoever adds a
  cancel action, or a screen that reads `docstatus`, should call
  `needsStockDiversion` on each line and `divertToStock` for the ones that
  qualify — the logic is there, only the trigger is missing.
- **Dispatch has a working screen** for flow B — `ProductionBoard.tsx` →
  `dispatchOrder`, gated on every line reaching Ready — so the `app/CLAUDE.md`
  §7 note that dispatch "is not built" is at least partly stale. Not confirmed
  working end-to-end against the live site, though: `listOrders`/`getOrder`
  in `client/src/api/client.ts` call `listDocs<Order>(DOCTYPE.salesOrder,
  {filters, orderBy, limit: 0})` with **no `fields` param and no mapper** —
  the same shape of bug `raiseReplenishment` had (camelCase `Order`/`OrderItem`
  asserted onto whatever ERPNext actually returns for an unfielded list call).
  Not touched this round; it is wider than production orders and needs its
  own look before anyone trusts the production board's live data.
