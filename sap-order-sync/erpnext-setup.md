# ERPNext side — `SAP Order Sync Control` single + trigger button

Mirrors the credit sync's **SAP Sync Control** single and the Hitech stock
sync's **Hitech Stock Fetch Control**. Create this in the ERPNext site
(`https://mannarubber.m.frappe.cloud`). None of it is created yet.

The **write-back custom fields on Sales Order are assumed to already exist** —
the human's brief lists all nine as present, `allow_on_submit`, read-only in
Desk. This file does **not** re-create them; it only adds the control single and
the button that asks the poller to run. Confirm the nine field names against
`shared/SAP_ORDER_SYNC.md` before the first real run.

---

## 1. DocType: `SAP Order Sync Control`  (Single)

| Setting | Value |
| --- | --- |
| Module | (whatever the credit sync's control uses) |
| Single | ✅ |
| Track Changes | optional |

### Fields

| Label | Fieldname | Type | Notes |
| --- | --- | --- | --- |
| Status | `status` | Select | options: `Idle`\n`Running`\n`Success`\n`Failed` — default `Idle`. Read-only. |
| Sync requested | `sync_requested` | Check | the button sets this to 1; the poller clears it when it claims the run. |
| Sync requested by | `sync_requested_by` | Data | read-only; the button writes `frappe.session.user`. |
| Run limit | `run_limit` | Int | 0 = all. First real runs: set to `2`. Passed to `Sync-SapOrders.ps1 -Limit`. |
| Dry run | `dry_run` | Check | when 1, the poller adds `-DryRun` (reads, writes nothing). Leave **on** until the first clean dry run is reviewed. |
| Cooldown minutes | `cooldown_minutes` | Int | admin-tunable; default 5. Poller will not log in to SAP again until `cooldown_until`. |
| Cooldown until | `cooldown_until` | Datetime | read-only; poller-managed. |
| Last run started at | `last_run_started_at` | Datetime | read-only; poller-managed. Staleness = crashed run. |
| Last sync at | `last_sync_at` | Datetime | read-only; set only on a successful run. |
| Last rows changed | `last_rows_changed` | Int | read-only; `result.changed` from the last run. |
| Last result message | `last_result_message` | Small Text | read-only; the one-line SUMMARY (or `FATAL: …`). |

Everything except `sync_requested`, `run_limit`, `dry_run`, `cooldown_minutes`
is written by the poller. Make those four editable, the rest read-only.

---

## 2. Client Script (Form, `SAP Order Sync Control`) — the button

```javascript
frappe.ui.form.on('SAP Order Sync Control', {
    refresh(frm) {
        frm.add_custom_button(__('Push orders to SAP now'), () => {
            frappe.call({
                method: 'frappe.client.set_value',
                args: {
                    doctype: 'SAP Order Sync Control',
                    name: 'SAP Order Sync Control',
                    fieldname: {
                        sync_requested: 1,
                        sync_requested_by: frappe.session.user
                    }
                },
                callback: () => {
                    frappe.show_alert({ message: __('Requested. The poller runs within ~2 minutes.'), indicator: 'blue' });
                    frm.reload_doc();
                }
            });
        });
    }
});
```

If you want the button on the **Sales Order list** instead (like the stock
sync's "Fetch stock from SAP"), use the same server-script pattern the Hitech
sync documents — a whitelisted `sap_order_push_request` that sets
`sync_requested = 1` with a per-user throttle. Not required for v1.

---

## 2a. Server Script — fire automatically on approval (no button needed)

**This is what makes the sync "run on click of approval."** The button above
is a manual fallback; this is what actually removes the extra step. Server
Scripts execute now (since 7 Sep 2026) — see `CLAUDE.md`'s two traps before
writing one: `safe_exec` doesn't whitelist `frappe.get_roles` / `get_single` /
`has_permission` / `hasattr`, and a Single must be read with
`frappe.get_doc("<name>")` (or `frappe.db.get_value`, used below), never
`frappe.get_single`.

Fires for **every** approval, from either app or Desk — a client-script hook
would only cover the app that has it wired in, and per `CLAUDE.md`'s own
rule ("a check that exists in `client/` and not in `app/` is not a check"),
one app quietly not triggering it is worse than no automation at all.

Desk → **Setup → Server Script → New**:

| Setting | Value |
| --- | --- |
| Script Type | `DocType Event` |
| Document Type | `Sales Order` |
| Event | `After Save` |
| Name | `manna_sap_order_sync_trigger` |

```python
# Auto-request the SAP order push the moment an order is approved. Cheap on
# every other save (one field read, no-op unless the gate just closed).
if (
    doc.get("custom_po_status") == "PO Approved - Ready for SAP"
    and not doc.get("custom_sap_sales_order")
    and doc.docstatus < 2
):
    already_requested = frappe.db.get_value(
        "SAP Order Sync Control", "SAP Order Sync Control", "sync_requested"
    )
    if not already_requested:
        frappe.db.set_value(
            "SAP Order Sync Control",
            "SAP Order Sync Control",
            {"sync_requested": 1, "sync_requested_by": frappe.session.user},
        )
```

That's the whole trigger. No cooldown logic here — the poller enforces that
(the SAP licence pool is the scarce resource, and the refusal has to live
somewhere a browser console can't reach, same reasoning as the credit sync's
`manna_sap_request_sync`).

---

## 3. Scheduled Task (on the SAP box)

Two triggers, same as the credit sync — **run `Register-OrderSyncTasks.ps1`**
(in this folder) yourself. The agent's session is blocked by its own safety
classifier from registering scheduled tasks directly (persistence actions are
treated like the ERPNext role-grant case earlier — it can prepare the script,
not execute it). The script:

- `SAP-Hitech-OrderSync-Poll` — every 2 min, honours `sync_requested`.
- `SAP-Hitech-OrderSync-Force` — every 15 min (offset 5 min from Poll), runs
  regardless so PASS B keeps moving even when nobody approves anything new.
- Registers to run as you, only while logged on (simplest for now). For an
  unattended 24/7 account, the script has a commented-out block using a
  service account + `-LogonType Password` (will prompt for that account's
  password interactively).

The credit sync and this one must never log in to SAP in the same minute —
the 5-minute offset above keeps the `-Force` triggers apart; check the credit
sync's own schedule before finalising and adjust if they'd ever land in the
same minute.
