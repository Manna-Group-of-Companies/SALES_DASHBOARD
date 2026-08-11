# ERPNext setup for the Sales module

What to create on the ERPNext site so `VITE_USE_MOCK=false` works. Field names
here match `src/api/endpoints.ts` exactly — if you rename anything, rename it
there too and nowhere else.

The existing field-sales app already uses `Sales Order` with
`custom_sales_person` / `custom_po_status` / `custom_production_status`, so this
module **extends that same doctype** rather than introducing a parallel one.

---

## 1. Custom fields on existing doctypes

### `Item`

| Fieldname | Label | Type | Notes |
|---|---|---|---|
| `custom_product_category` | Product Category | Select | Options: `PCTR`, `CTR`, `BG`, `VS` |
| `custom_avg_weight_per_roll` | Avg Weight Per Roll (kg) | Float | PCTR only. Drives quantity maths. |
| `custom_belts_per_roll` | Belts Per Roll | Int | PCTR only. |
| `custom_exact_weight_per_roll` | Exact Weight Per Roll (kg) | Float | CTR only. |
| `custom_tin_size` | Tin Size (L) | Select | VS only. Options: `10`, `30` |
| `custom_size` | Size | Data | e.g. `140 x 8` |

> PCTR rows without both `custom_avg_weight_per_roll` and `custom_belts_per_roll`
> cannot be priced. The Excel importer rejects them rather than importing a
> product that will break the order screen.

### `Customer`

| Fieldname | Label | Type | Notes |
|---|---|---|---|
| `custom_destination` | Destination | Data | Shown to production **in place of** the customer name (3.1) |
| `custom_credit_limit` | Credit Limit | Currency | Used by the manager's credit check (2.1) |
| `custom_outstanding_balance` | Outstanding Balance | Currency | Already exists in the field-sales app |
| `custom_assigned_reps` | Assigned Reps | Data | Pipe-delimited, e.g. `\|Subhash\|Vineeth\|` — matches the existing convention |

`gstin` is ERPNext's own field and is reused as-is.

### `Sales Order`

| Fieldname | Label | Type | Notes |
|---|---|---|---|
| `custom_sales_status` | Sales Status | Select | `draft`, `pending_approval`, `approved`, `in_production`, `dispatched`, `grouped`, `rejected` |
| `custom_destination` | Destination | Data | Copied from the customer at creation |
| `custom_approved_at` | Approved At | Datetime | **Sets the rate lock.** See §4. |
| `custom_approved_by` | Approved By | Data | |
| `custom_rate_locked` | Rate Locked | Check | |
| `custom_revised_delivery_date` | Revised Delivery Date | Date | Set by production (3.2) |
| `custom_proforma_generated` | Proforma Generated | Check | |
| `custom_proforma_no` | Proforma No | Data | |
| `custom_weekly_group` | Weekly Group | Link → Weekly Order Group | |
| `custom_dispatched_at` | Dispatched At | Datetime | |
| `custom_rejection_reason` | Rejection Reason | Small Text | |

### `Sales Order Item`

| Fieldname | Label | Type |
|---|---|---|
| `custom_category` | Category | Select (`PCTR`/`CTR`/`BG`/`VS`) |
| `custom_rolls` | Rolls | Int |
| `custom_loose_belts` | Loose Belts | Int |
| `custom_tins` | Tins | Int |
| `custom_tin_size` | Tin Size | Select (`10`/`30`) |
| `custom_quoted_rate` | Quoted Rate | Currency |
| `custom_final_rate` | Final Rate | Currency |
| `custom_rate_locked` | Rate Locked | Check |
| `custom_source` | Fulfilment Source | Select (`min_stock`/`new_production`) |
| `custom_aged_batch` | Aged Batch | Link → Min Stock Batch |
| `custom_stage` | Process Stage | Data |
| `custom_stage_updated_at` | Stage Updated | Datetime |

---

## 2. New doctypes

### `Min Stock Item`

Naming: by `item_code`.

| Fieldname | Type | Notes |
|---|---|---|
| `item_code` | Link → Item | Primary key |
| `item_name` | Data | |
| `category` | Select | `PCTR`/`CTR`/`BG`/`VS` |
| `uom` | Data | `Kg` or `L` |
| `threshold` | Float | The minimum to hold (3.5) |
| `on_hand` | Float | Physically on the shelf |
| `last_restocked_on` | Date | |
| `replenishment_raised` | Check | True while a run is open |
| `batches` | Table → Min Stock Batch | |

**An item's *absence* from this table is meaningful**: the order screen shows
"No minimum stock" for products not listed here (1.2). Do not create rows with a
zero threshold to represent "not tracked".

### `Min Stock Batch` (child table)

| Fieldname | Type | Notes |
|---|---|---|
| `stocked_on` | Date | Drives the aging bands |
| `remaining` | Float | |
| `original` | Float | |

Aging bands are defined in `src/domain/aging.ts`: aged at 60 days, stale at 120.

### `Stock Reservation`

| Fieldname | Type | Notes |
|---|---|---|
| `item_code` | Link → Item | |
| `qty` | Float | |
| `order_id` | Link → Sales Order | Null while the order is an unsaved draft |
| `rep_id` | Link → User | |
| `rep_name` | Data | |
| `held_at` | Datetime | Holds with a null `order_id` expire after 30 minutes |

### `Weekly Order Group`

| Fieldname | Type |
|---|---|
| `customer` | Link → Customer |
| `week_start` / `week_end` | Date |
| `order_ids` | Table (Link → Sales Order) |
| `compiled_at` | Datetime |
| `compiled_by` | Data |
| `total_value` | Currency |

### `Production Order Request`

| Fieldname | Type | Notes |
|---|---|---|
| `item_code` | Link → Item | |
| `qty` | Float | |
| `status` | Select | `open` / `completed` |
| `reason` | Select | `replenishment` / `order` |
| `raised_at` / `raised_by` | Datetime / Data | |
| `completed_at` | Datetime | |

### `Sales Notification`

| Fieldname | Type | Notes |
|---|---|---|
| `kind` | Data | See `NotificationKind` in `src/domain/types.ts` |
| `severity` | Select | `info` / `warning` / `critical` |
| `title` / `body` | Data / Small Text | |
| `audience` | Data | Comma-joined roles |
| `audience_user_id` | Link → User | Optional narrowing |
| `order_id` | Link → Sales Order | |
| `item_code` | Link → Item | |
| `read_at` / `acked_at` | Datetime | |
| `requires_ack` | Check | Post-approval order changes (3.3) |

---

## 2b. HR — no new doctypes

The HR screens run on the stock ERPNext HR doctypes. Install the **HR** app and
there is nothing to create; only three custom fields are new.

| Doctype | Used for | App type |
|---|---|---|
| `Employee` | Directory, headcount, tenure | `Employee` |
| `Attendance` | Daily roster — one doc per employee per day | `AttendanceRecord` |
| `Leave Application` | The leave queue | `LeaveRequest` |

Custom fields to add:

| Doctype | Fieldname | Type | Notes |
|---|---|---|---|
| `Employee` | `custom_leave_balance` | Float | Rolled-up paid balance in days. The authoritative per-type balance lives in `Leave Ledger Entry`; this is the number the dashboard shows. |
| `Attendance` | `custom_note` | Small Text | Why someone was marked as they were |
| `Leave Application` | `custom_decision_note` | Small Text | Shown back to the employee on a rejection |

Value translation happens in `client.ts` only:

- `Attendance.status`: `Present` / `Absent` / `On Leave` / `Half Day` / `Holiday`
  ⇄ `present` / `absent` / `on_leave` / `half_day` / `holiday`
- `Leave Application.status`: `Open` ⇄ `pending`, then `Approved` / `Rejected` / `Cancelled`
- `Employee.department` is free text with a company abbreviation (`Production - MT`);
  the part before the ` - ` is matched against `Department` in `src/domain/types.ts`,
  and anything unrecognised falls back to `Administration`.
- An employee counts as relieved when `Employee.status` is not `Active`.

---

## 3. Roles

Create these ERPNext roles and assign them; `client.ts` → `fetchCurrentUser` maps them
onto the app's four roles:

- `Sales Manager` (`User.custom_managed_team` set) → sales_manager
- `Production Manager` (`User.custom_is_production_manager = 1`) → production_manager
- `Stock Manager` (`User.custom_is_stock_manager = 1`) → stock_manager
- `HR` (`User.custom_is_hr = 1`) → hr
- anything else → **rejected at sign-in**

`custom_is_hr` is checked first: an HR login never falls through to a sales role.

There is deliberately no `sales_rep` fallback. A user who is only a `Sales
Person` is a field rep, and field reps work in the field-sales app — the two
apps share this site, so a default here would hand a rep the production board.
`fetchCurrentUser` throws instead. Reps' names still reach this app on
`Sales Order.custom_sales_person` and on timeline entries, as data.

---

## 4. Server-side methods (important)

The UI enforces every rule in `src/domain/orderRules.ts`, but a browser can be
bypassed with a raw REST call. These three rules are worth enforcing server-side
too, in a small custom app (`manna_sales`):

```python
# manna_sales/api.py

@frappe.whitelist()
def reserve_stock(item_code, qty, order_id=None):
    """Atomic check-and-hold. Closes the race the UI's polling leaves open."""

@frappe.whitelist()
def release_stock(reservation): ...

@frappe.whitelist()
def approve_order(order, final_rates, sources):
    """Set custom_final_rate + custom_rate_locked in one transaction."""

@frappe.whitelist()
def compile_weekly_group(customer, week_start): ...
```

Plus two `before_save` hooks on `Sales Order`:

1. **Rate lock (2.2)** — if `custom_approved_at` is set, reject any change to
   `custom_final_rate` on any row. This is the invariant the whole workflow rests
   on; it should not be defensible only in JavaScript.
2. **Edit freeze (3.3)** — reject item changes after 1:00 PM local on
   `custom_revised_delivery_date or delivery_date`.
3. **Immutable creation timestamp (1.7, 3.2)** — reject any write to `creation`.

Until these exist, the app is safe through its own UI but not against a
hand-crafted API call.

---

## 5. Switching over

```bash
cp .env.example .env.local
# set VITE_USE_MOCK=false and VITE_ERP_URL=https://your-erp-site
npm run dev
```

The Vite dev proxy forwards `/api` to the ERPNext site so the browser sees
same-origin requests and Frappe's `sid` cookie sticks. For production, serve the
built `dist/` from the same origin as ERPNext, or add CORS headers there.
