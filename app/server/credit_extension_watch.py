# Frappe Server Script
#   Name            : manna_credit_extension_watch
#   Script Type     : Scheduler Event
#   Event Frequency : Cron
#   Cron Format     : 0 9 * * *          (every morning at 09:00, site time)
#
# The escalation of a missed payment commitment must not depend on the office
# server's SAP job running (17 Nov 2026, the user's default). The job decides
# Paid or Payment Commitment Overdue from SAP's payments every few minutes; if
# it has stopped, nothing would ever escalate and SAP's raised credit limit
# would stay raised. So every morning this takes each 'Active' extension
# whose commitment date is before today to 'Payment Commitment Overdue',
# escalates it to the GM and notifies the manager and the GM, once.
#
# It errs toward escalating, and marks what it cannot know: overdue_unchecked
# says SAP's payments were not counted, and the commitment is NOT marked
# missed - only SAP can say that. The SAP restore is set Pending, so when the
# job runs again it puts the limit back and counts the payments, and
# manna_credit_extension's late_check settles it (Paid after all, or missed).
# 09:00 gives the job the whole night after the commitment day to get there
# first, so on a normal day this finds nothing.
#
# Also says once a morning, to the GM, when the SAP job has not run for six
# hours while extensions wait on it: nothing raises, counts or restores then.
#
# shared/fixtures/credit_extension.json ('watchdog', 'transitions') pins the
# rule; app/server/test_credit_extension.py runs it. safe_exec: a def may not
# call another def or see the script's names.

# ---- rule: shared/fixtures/credit_extension.json ----


def watch_due(status, commitment, today):
    c = str(commitment or "")[:10]
    return status == "Active" and len(c) == 10 and c < str(today)[:10]

# ---- end rule ----


DT = "Manna Credit Extension"
SETTINGS = "Manna Credit Extension Settings"
today = frappe.utils.today()
now = frappe.utils.now()
gms = [u.name for u in frappe.get_all("User", filters={"custom_is_general_manager": 1, "enabled": 1}, fields=["name"])]

done = []
for r in frappe.get_all(DT, filters={"status": "Active", "commitment_date": ["<", today]},
                        fields=["name", "commitment_date"], limit_page_length=0):
    if not watch_due("Active", str(r.commitment_date), today):
        continue
    doc = frappe.get_doc(DT, r.name)
    # Re-read: the job may have decided it between the list and here.
    if doc.status != "Active":
        continue
    doc.status = "Payment Commitment Overdue"
    doc.overdue_unchecked = 1
    doc.restore_status = "Pending"
    doc.escalated_on = now
    last = str(doc.last_payment_check or "never")[:16]
    doc.escalation_reason = ("Payment commitment date " + str(doc.commitment_date) + " has passed; SAP's payments "
                             + "not yet checked (last check " + last + ")")
    doc.append("log", {"action": "Payment Commitment Overdue (not yet checked against SAP)", "actor_role": "watchdog",
                       "by_user": "Administrator", "at": now, "remarks": doc.escalation_reason,
                       "amount": doc.paid_amount or 0})
    doc.save(ignore_permissions=True)
    managers = []
    if doc.team:
        managers = [u.name for u in frappe.get_all("User", filters={"custom_managed_team": doc.team, "enabled": 1}, fields=["name"])]
    for u in managers + gms:
        frappe.get_doc({"doctype": "Notification Log", "for_user": u, "type": "Alert",
                        "subject": "Payment commitment overdue: " + (doc.customer_name or doc.customer) + " (" + doc.name
                                   + ") - escalated to the GM; payments not yet checked in SAP",
                        "document_type": DT, "document_name": doc.name}).insert(ignore_permissions=True)
    done.append(doc.name)

waiting = frappe.get_all(DT, filters={"status": ["in", ["Sending to SAP", "Active"]]}, fields=["name"], limit_page_length=0)
waiting = waiting + frappe.get_all(DT, filters={"restore_status": "Pending"}, fields=["name"], limit_page_length=0)
last_run = frappe.db.get_single_value(SETTINGS, "last_job_run")
stale = (not last_run) or frappe.utils.time_diff_in_hours(now, last_run) > 6
if waiting and stale:
    for u in gms:
        frappe.get_doc({"doctype": "Notification Log", "for_user": u, "type": "Alert",
                        "subject": "The SAP credit extension job has not run since " + (str(last_run)[:16] if last_run else "it was installed")
                                   + ": " + str(len(set([w.name for w in waiting]))) + " extension(s) wait on it. Tell IT.",
                        "document_type": DT, "document_name": waiting[0].name}).insert(ignore_permissions=True)

frappe.db.set_value(SETTINGS, SETTINGS, {"last_watch_run": now,
                                         "last_watch_result": ("escalated " + ", ".join(done)) if done else "nothing past its date"})
