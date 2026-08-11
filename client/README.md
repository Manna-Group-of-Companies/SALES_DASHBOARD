# Manna Treads — Sales module

Order lifecycle for the Manna Treads team, picking up where the field-sales app
leaves off: approval by the Sales Manager, execution by the Production Manager,
replenishment by the Stock Manager — plus people, attendance and leave for HR.
Reps take orders in the field-sales app and have no login here.

React 18 · TypeScript · Redux Toolkit · Axios · Vite. Backend is ERPNext
(Frappe REST). **UI only** — the ERPNext doctypes this expects are specified in
[`docs/ERPNEXT_DOCTYPES.md`](docs/ERPNEXT_DOCTYPES.md).

## Running it

```bash
npm install
npm run dev          # http://localhost:5174
```

Ships with `VITE_USE_MOCK=true`, so it runs entirely on in-memory fixtures with
no ERPNext needed. Sign in with email and password — the same form that will
talk to Frappe once the backend is live.

### Development sign-in

> ⚠️ **These are fixture credentials.** They only work while
> `VITE_USE_MOCK=true` and they unlock nothing but fake data. The moment
> `VITE_USE_MOCK=false`, this map is never consulted and authentication goes to
> Frappe. **Never create real ERPNext accounts with these passwords.** They live
> in `MOCK_CREDENTIALS` in [`src/api/mock/fixtures.ts`](src/api/mock/fixtures.ts).

| Role | Email | Password |
|---|---|---|
| Sales Manager | `rajesh@mannarubber.com` | `Rajesh@2026` |
| Production Manager | `anil@mannarubber.com` | `Anil@2026` |
| Stock Manager | `fahad@mannarubber.com` | `Fahad@2026` |
| HR | `meera@mannarubber.com` | `Meera@2026` |

**There is no Sales Rep login.** Reps raise orders in the field-sales app; this
module picks those orders up off the same ERPNext site and runs them from
approval through to dispatch. Rep names still appear on orders and timelines —
as data that arrives with the order, never as an account here. A Frappe user who
is only a `Sales Person` is refused at sign-in rather than defaulted into a role.

To see the live minimum-stock booking, sign in as Rajesh in one browser and
Fahad in another (or a private window) — the shared ledger syncs between them.

```bash
npm run typecheck
npm run build
```

## File structure

```
src/
  domain/          Pure business rules. No React, no Redux, no Axios.
    types.ts           Domain vocabulary
    productRules.ts    Per-category quantity/weight/money maths (1.2–1.5)
    orderRules.ts      Rate lock (2.2), edit freeze (3.3), permissions
    processStages.ts   Per-category production cycles (3.2)  ← provisional
    aging.ts           Dated batches and age bands (1.6)
    hrRules.ts         Headcount, attendance, leave clashes and balances

  api/
    client.ts        THE API CLIENT — everything that talks to ERPNext, one file
    config.ts        Env switches
    endpoints.ts     Every doctype + fieldname in one place
    mock/            In-memory backend (fixtures + localStorage + cross-tab sync)

  store/           Redux Toolkit slices + memoised selectors
  components/      ui/ (primitives) · common/ (domain-flavoured) · layout/
  features/        auth · dashboard · customers · orders · approvals ·
                   production · stock · hr · import · notifications
```

The rule of thumb: **`domain/` holds every decision, `features/` only renders
them.** If a screen needs to know whether something is editable, it asks
`orderRules`, so the answer cannot differ between two screens.

### The API client

Every call lives in [`src/api/client.ts`](src/api/client.ts), one file, the same
shape as `services/api.dart` in the field-sales app — one `Api` object, one place
to look when an endpoint changes:

```ts
import { Api } from '@/api/client';

Api.auth.login(email, password)
Api.catalog.listProducts()
Api.orders.approve({ orderId, user, finalRates, sources })
Api.stock.reserve({ itemCode, qty, user })
Api.notify.acknowledge(id)
Api.importer.parseProducts(buffer)
Api.hr.decideLeave({ request, approve, decidedBy })
```

It is laid out in nine numbered sections: auth plumbing, Frappe REST helpers,
then `auth · catalog · notify · stock · orders · importer · hr`. Every method
works against the real site or the fixture backend, switched by `USE_MOCK` — the
mock branch is a working implementation, not a stub.

`xlsx` is `import()`ed on demand inside the importer section, so the largest
dependency in the project stays out of the main bundle (400 kB main, 430 kB
spreadsheet chunk loaded only when someone opens `/import`).

## The two invariants

Everything else is workflow; these two are load-bearing.

**Rates lock at approval (2.2).** `isRateLocked()` is deliberately not
role-aware — nobody outranks it. `Api.orders.updateItems` re-applies stored rates on
every item update even if the caller passes different ones.

**Orders freeze at 1:00 PM on the delivery date (3.3).** `canEditItems()` is the
only gate; every editable surface goes through it. A countdown chip sits on every
order row so the deadline is visible before it bites.

> **Judgement call, flagged:** when production moves the delivery date (3.2), the
> freeze deadline follows the *revised* date, not the original. Preponing would
> otherwise leave edits open past dispatch, and postponing would freeze an order
> that still has a fortnight to run. Change `effectiveDeliveryDate()` in
> `orderRules.ts` if you want it pinned to the originally requested date.

## Where the spec lives in the code

| Spec | Code |
|---|---|
| 1.2 PCTR rows, min-stock display, live booking | `ProductRow.tsx`, `StockChip.tsx`, `client.ts` → `Api.stock` |
| 1.3 CTR derived weight, optional proforma | `productRules.ts`, `TakeOrderPage.tsx`, `ProformaDocument.tsx` |
| 1.4 Bonding gum 5 kg multiples | `productRules.ts` → `validateLine`, `snapBgKg` |
| 1.5 Vulcanizing solution 10L / 30L | `productRules.ts`, seeded as two products |
| 1.6 Aging list, dated batches | `aging.ts`, `AgingPanel.tsx`, `AgingListPage.tsx` |
| 1.7 Delivery date + immutable timestamp | `client.ts` → `Api.orders.create` |
| 2.1 Manager edit + credit check | `ApprovalReviewModal.tsx`, `client.ts` → `checkCredit` |
| 2.2 Rate finalisation and lock | `orderRules.ts` → `isRateLocked` |
| 2.3 Min stock vs new production | `ApprovalReviewModal.tsx`, per-line `Segmented` |
| 3.1 Customer identity hidden from production | `orderRules.ts` → `customerLabelFor` |
| 3.2 Process stages, date moves | `processStages.ts`, `ProductionOrderModal.tsx` |
| 3.3 Post-approval edits + must-ack alerts | `EditItemsModal.tsx`, `NotificationPanel.tsx` |
| 3.4 Weekly grouping | `client.ts` → `bucketForGrouping`, `WeeklyCompilePage.tsx` |
| 3.5 Min stock monitoring + replenishment | `MinStockPage.tsx`, `ReplenishmentPage.tsx` |

## Notification design

Two tiers, on purpose:

- **Ordinary** — read-and-forget. Order approved, stage advanced, dispatched.
- **Must-acknowledge** — a post-approval item change (3.3). It pins to the top of
  the Production Manager's notification panel, shows a red banner across their
  screen, and stays until they press Acknowledge. Scrolling past it is not
  possible. That is what makes "no order change is ever missed on the floor"
  actually hold when the floor is busy.

Every order also carries an append-only timeline that all four roles read, so
"what happened to this order" never needs a phone call.

## Known gaps

- **Process stages are provisional.** `STAGE_CYCLES` in `processStages.ts` is a
  sensible guess pending the process document. Replacing that one object is the
  entire migration — no screen or reducer references a stage name.
- **Products and customers are fixtures** until the Excel sheets arrive. The
  importer is built and validated; drop the sheets on `/import`.
- **Minimum-stock booking is a soft reservation** (poll + optimistic hold), per
  the agreed trade-off. `Api.stock.reserve` is shaped so swapping its body for
  the whitelisted `reserve_stock` method closes the remaining race without
  touching a single caller.
