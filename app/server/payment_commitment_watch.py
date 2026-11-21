# Frappe Server Script
#   Name            : manna_payment_commitment_watch
#   Script Type     : Scheduler Event
#   Event Frequency : Cron
#   Cron Format     : 15 * * * *          (every hour at :15, site time)
#
# Tracks every running 10-day payment commitment against the SAP figures the
# credit sync copies into ERPNext (17 Nov 2026, the user's spec): kept when
# nothing is overdue past terms on figures synced after the approval, by the
# end of the payment due date; missed when figures synced after that day still
# show something overdue. Never missed on stale figures: with nothing synced
# since the due date it is 'Unchecked', the credit sync is asked for, and the
# order still shows Payment Pending.
#
# A miss sends the customer's next orders to the GM, bypassing the Manager,
# until synced figures show nothing overdue (cleared_on) - the user's choice.
# The Manager and the GM are notified of each miss and each clearance, once.
#
# Freshness is SAP Sync Control.last_sync_at, which the credit sync's poller
# stamps on a successful run: the sync writes a customer's figures only when
# they change, so an unchanged figure is current as of that stamp.
#
# shared/fixtures/payment_commitment.json ('track') pins the rule;
# app/server/test_payment_commitment.py runs it. safe_exec: a def may not call
# another def or see the script's names.

# ---- rule: shared/fixtures/payment_commitment.json ----


def track(status, approved_on, commitment, today, overdue_now, synced_at):
    if status not in ("Running", "Unchecked"):
        return "none"
    synced = str(synced_at or "")[:19]
    fresh = synced != "" and synced > str(approved_on or "")[:19]
    synced_day = synced[:10]
    day = str(commitment or "")[:10]
    clear = float(overdue_now or 0) <= 1
    if fresh and clear and synced_day <= day:
        return "kept"
    if str(today)[:10] <= day:
        return "running"
    if fresh and synced_day > day:
        return "missed_cleared" if clear else "missed"
    return "unchecked"

# ---- end rule ----


DT = "Manna Payment Commitment"
now = frappe.utils.now()
today = frappe.utils.today()
synced = ""
try:
    synced = str(frappe.db.get_single_value("SAP Sync Control", "last_sync_at") or "")
except Exception:
    synced = ""
gms = [u.name for u in frappe.get_all("User", filters={"custom_is_general_manager": 1, "enabled": 1}, fields=["name"])]

counts = {"kept": 0, "missed": 0, "unchecked": 0, "cleared": 0}
need_sync = False

for r in frappe.get_all(DT, filters={"status": ["in", ["Running", "Unchecked"]]},
                        fields=["name", "customer", "status", "approved_on", "commitment_date"], limit_page_length=0):
    overdue = frappe.utils.flt(frappe.db.get_value("Customer", r.customer, "custom_overdue_past_terms"))
    t = track(r.status, str(r.approved_on or ""), str(r.commitment_date or ""), today, overdue, synced)
    if t in ("none", "running"):
        continue
    if t == "unchecked":
        need_sync = True
        if r.status == "Unchecked":
            continue
    doc = frappe.get_doc(DT, r.name)
    doc.overdue_last = overdue
    doc.last_checked = synced or None
    who = doc.customer_name or doc.customer
    managers = []
    if doc.team:
        managers = [u.name for u in frappe.get_all("User", filters={"custom_managed_team": doc.team, "enabled": 1}, fields=["name"])]
    subject = ""
    if t == "kept":
        doc.status = "Kept"
        doc.kept_on = synced
        doc.append("log", {"action": "Kept: nothing overdue in SAP", "actor_role": "tracker", "by_user": "Administrator",
                           "at": now, "remarks": "Figures synced " + synced[:16]})
        subject = "Payment commitment kept: " + who + " (" + doc.name + ")"
        counts["kept"] = counts["kept"] + 1
    elif t in ("missed", "missed_cleared"):
        doc.status = "Missed"
        doc.missed_on = now
        doc.append("log", {"action": "Missed: still overdue after " + str(doc.commitment_date), "actor_role": "tracker",
                           "by_user": "Administrator", "at": now,
                           "remarks": "Overdue " + str(overdue) + " on figures synced " + synced[:16]})
        if t == "missed_cleared":
            doc.cleared_on = synced
            doc.append("log", {"action": "Overdue cleared (paid after the due date)", "actor_role": "tracker",
                               "by_user": "Administrator", "at": now, "remarks": "Figures synced " + synced[:16]})
            subject = "Payment commitment missed, paid late: " + who + " (" + doc.name + ")"
        else:
            subject = ("Payment commitment missed: " + who + " (" + doc.name + ") - their next orders go to the GM until "
                       + "the overdue is cleared")
        counts["missed"] = counts["missed"] + 1
    else:
        doc.status = "Unchecked"
        doc.append("log", {"action": "Due date passed; waiting for fresh SAP figures", "actor_role": "tracker",
                           "by_user": "Administrator", "at": now,
                           "remarks": "Last sync " + (synced[:16] or "never")})
        counts["unchecked"] = counts["unchecked"] + 1
    doc.save(ignore_permissions=True)
    if subject:
        for u in managers + gms:
            frappe.get_doc({"doctype": "Notification Log", "for_user": u, "type": "Alert", "subject": subject,
                            "document_type": DT, "document_name": doc.name}).insert(ignore_permissions=True)

# A miss holds the customer's orders with the GM until the overdue is cleared
# on figures synced after the miss.
for r in frappe.get_all(DT, filters={"status": "Missed", "cleared_on": ["is", "not set"]},
                        fields=["name", "customer", "missed_on"], limit_page_length=0):
    overdue = frappe.utils.flt(frappe.db.get_value("Customer", r.customer, "custom_overdue_past_terms"))
    if synced and synced[:19] > str(r.missed_on or "")[:19] and overdue <= 1:
        doc = frappe.get_doc(DT, r.name)
        doc.cleared_on = synced
        doc.append("log", {"action": "Overdue cleared: orders follow the normal ladder again", "actor_role": "tracker",
                           "by_user": "Administrator", "at": now, "remarks": "Figures synced " + synced[:16]})
        doc.save(ignore_permissions=True)
        counts["cleared"] = counts["cleared"] + 1
        managers = []
        if doc.team:
            managers = [u.name for u in frappe.get_all("User", filters={"custom_managed_team": doc.team, "enabled": 1}, fields=["name"])]
        for u in managers + gms:
            frappe.get_doc({"doctype": "Notification Log", "for_user": u, "type": "Alert",
                            "subject": "Overdue cleared: " + (doc.customer_name or doc.customer) + " - orders go to the Manager again",
                            "document_type": DT, "document_name": doc.name}).insert(ignore_permissions=True)

if need_sync:
    # The credit sync's own flag; the office server's poller answers it.
    try:
        ctl = frappe.get_doc("SAP Sync Control")
        if not ctl.sync_requested:
            ctl.sync_requested = 1
            ctl.sync_requested_by = "manna_payment_commitment_watch"
            ctl.sync_requested_at = now
            ctl.save(ignore_permissions=True)
    except Exception:
        frappe.log_error(title="manna_payment_commitment_watch: could not ask for the credit sync")
