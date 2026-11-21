# Frappe Server Script
#   Name          : manna_credit_extension
#   Script Type   : API
#   API Method    : manna_credit_extension
#   Args (POST)   : action =
#     eligible   : -                         orders this login may ask an extension for
#     list       : customer (optional)
#     detail     : name                      the review: customer figures, payments, history
#     history    : customer                  the customer's permanent extension history
#     submit     : sales_order, reason
#     approve    : name, amount, commitment_date, reason, remarks   (approve AND push to SAP)
#     reject     : name, remarks
#     escalate   : name, remarks (optional)  manager -> GM (past the manager's authority)
#     retry      : name                      push again after SAP refused
#     sap_event  : name, event, ...          the SAP job only (Sync-CreditExtensions.ps1)
#     settings   : [authorities, manager_max_amount, manager_cap_count, manager_cap_days]
#                                            read (managers, GM); write (the GM only)
#     alerts     : -                         this login's notifications about extensions
#     seen       : -                         marks them read
#
# 17 Nov 2026, the user's defaults: a manager may give a customer at most
# manager_cap_count extensions in manager_cap_days (2 in 90) before the GM must;
# each manager may have their own authority (the settings' authorities table),
# else the shared figure; and the escalation of a missed date no longer waits
# on the SAP job - manna_credit_extension_watch (credit_extension_watch.py)
# escalates every morning what the job has not, marked overdue_unchecked, and
# the job's later count settles it here (late_check).
#
# Temporary credit extension with a payment commitment (16 Nov 2026, the
# user's strict instruction). A SEPARATE workflow: order approval, credit
# periods, credit conditions and the credit sync are untouched. A rep (or the
# team's manager) asks on an order that takes a customer past their SAP credit
# limit. The manager approves an extra amount within their authority
# (Manna Credit Extension Settings.manager_max_amount) with a commitment of at
# most 10 days, and that approval is the push: 'Sending to SAP'. The SAP job
# raises SAP's CreditLimit by the amount ('Active'), counts confirmed SAP
# payments from the approval to the commitment date, and puts the original
# limit back when it is 'Paid' or 'Payment Commitment Overdue' - the second
# goes to the GM, who renews (a new record) or rejects. A customer who missed
# once, or has an extension running, goes to the GM from the start.
# shared/fixtures/credit_extension.json pins every rule below.
#
# safe_exec: no import (json is given), no frappe.get_roles / parse_json /
# hasattr, no tuple-unpacking assignment, no augmented assignment to an item,
# and a def may not call another def or see the script's names - the rule
# functions are leaves with their numbers inside them.

# ---- rule: shared/fixtures/credit_extension.json ----
# test_credit_extension.py runs the text between these two markers.


def route_status(missed_before, open_extension, manager_recent, cap):
    if int(missed_before or 0) > 0 or open_extension:
        return "Pending GM"
    if int(manager_recent or 0) >= int(cap or 0):
        return "Pending GM"
    return "Pending Manager"


def manager_recent(approvals, today, days):
    """How many of [approvals] ({role, on}) a manager gave in the [days]
    calendar days up to and including [today]."""
    n = []
    for s in [str(today)[:10]] + [str(a.get("on") or "")[:10] for a in approvals]:
        if len(s) != 10:
            n.append(None)
            continue
        y = int(s[0:4])
        m = int(s[5:7])
        dd = int(s[8:10])
        y2 = y - 1 if m <= 2 else y
        era = y2 // 400
        yoe = y2 - era * 400
        doy = (153 * ((m + 9) % 12) + 2) // 5 + dd - 1
        n.append(era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy)
    count = 0
    i = 0
    for a in approvals:
        i = i + 1
        if (a.get("role") or "") != "manager" or n[i] is None:
            continue
        if 0 <= n[0] - n[i] < int(days or 0):
            count = count + 1
    return count


def authority_for(manager, rows, default):
    for r in rows:
        if (r.get("manager") or "") == manager:
            return float(r.get("max_amount") or 0)
    return float(default or 0)


def late_check(status, result):
    """An overdue extension the watchdog escalated before SAP's payments were
    counted, once they are: its status and whether the commitment was missed."""
    if result == "paid":
        return {"status": "Paid" if status == "Payment Commitment Overdue" else status, "missed": 0}
    if result == "overdue":
        return {"status": status, "missed": 1}
    return {"status": status, "missed": 0}


def check_manager(amount, authority, approved_on, commitment, reason, remarks):
    """'' when a manager's approval is allowed, else what is wrong."""
    a = float(amount or 0)
    if a <= 0:
        return "amount"
    auth = float(authority or 0)
    if auth <= 0 or a > auth:
        return "authority"
    d0 = str(approved_on or "")[:10]
    c = str(commitment or "")[:10]
    if len(c) != 10 or c < d0:
        return "date_past"
    n = []
    for s in (d0, c):
        y = int(s[0:4])
        m = int(s[5:7])
        dd = int(s[8:10])
        y2 = y - 1 if m <= 2 else y
        era = y2 // 400
        yoe = y2 - era * 400
        doy = (153 * ((m + 9) % 12) + 2) // 5 + dd - 1
        n.append(era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy)
    if n[1] - n[0] > 10:
        return "too_long"
    if not str(reason or "").strip():
        return "reason"
    if not str(remarks or "").strip():
        return "remarks"
    return ""


def check_gm(amount, today, commitment, remarks):
    if float(amount or 0) <= 0:
        return "amount"
    c = str(commitment or "")[:10]
    if len(c) != 10 or c < str(today)[:10]:
        return "date_past"
    if not str(remarks or "").strip():
        return "remarks"
    return ""


def next_status(action, status, actor):
    """The status [action] by [actor] moves an extension to, or "" when refused."""
    if action == "approve":
        if status == "Pending Manager" and actor in ("manager", "gm"):
            return "Sending to SAP"
        if status == "Pending GM" and actor == "gm":
            return "Sending to SAP"
        if status == "Payment Commitment Overdue" and actor == "gm":
            return "Renewed by GM"
        return ""
    if action == "reject":
        if status == "Pending Manager" and actor == "manager":
            return "Rejected"
        if status in ("Pending Manager", "Pending GM", "Payment Commitment Overdue") and actor == "gm":
            return "Rejected by GM"
        return ""
    if action == "escalate":
        return "Pending GM" if (status == "Pending Manager" and actor == "manager") else ""
    if action == "retry":
        return "Sending to SAP" if (status == "SAP Push Failed" and actor == "approver") else ""
    if action == "date_passed":
        return "Payment Commitment Overdue" if (status == "Active" and actor == "watchdog") else ""
    if actor != "sap_job":
        return ""
    if action == "sap_raised" and status == "Sending to SAP":
        return "Active"
    if action == "sap_failed" and status == "Sending to SAP":
        return "SAP Push Failed"
    if action == "sap_paid" and status == "Active":
        return "Paid"
    if action == "sap_overdue" and status == "Active":
        return "Payment Commitment Overdue"
    return ""


def payment_status(amount, paid):
    a = round(float(amount or 0), 2)
    p = round(float(paid or 0), 2)
    rest = round(a - p, 2) if p < a else 0
    if p >= a and a > 0:
        return {"status": "Paid", "remaining": 0}
    if p > 0:
        return {"status": "Partially Paid", "remaining": rest}
    return {"status": "Not Paid", "remaining": a}


def outcome(amount, paid, today, commitment):
    if round(float(paid or 0), 2) >= round(float(amount or 0), 2):
        return "paid"
    if str(today)[:10] > str(commitment)[:10]:
        return "overdue"
    return "running"

# ---- end rule ----


def clean(v):
    s = (v or "")
    s = s.strip() if isinstance(s, str) else str(s)
    return "" if s == "null" else s


def actor_for(row_sales_person, row_team, me, managed, is_gm):
    if is_gm:
        return "gm"
    if managed and (row_team or "") == managed:
        return "manager"
    if me and row_sales_person == me:
        return "rep"
    return "other"


user = frappe.session.user
action = clean(frappe.form_dict.get("action")) or "list"
DT = "Manna Credit Extension"
SETTINGS = "Manna Credit Extension Settings"
PENDING = ["Pending Manager", "Pending GM"]
RUNNING = ["Sending to SAP", "SAP Push Failed", "Active", "Payment Commitment Overdue"]
WAITING_ORDER = ["Pending Approval", "PO Uploaded - Pending Approval", "Pending Rate Approval", "Pending GM Approval"]
MESSAGES = {
    "amount": "Enter an additional credit amount above zero.",
    "authority": "This amount is past your approval authority. Send it to the GM.",
    "date_past": "The payment commitment date cannot be in the past.",
    "too_long": "A manager may give at most 10 days from today.",
    "reason": "Enter the reason for the extension.",
    "remarks": "Enter your remarks.",
}

is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1))
is_bot = bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "SAP Sync Bot"}, limit=1))
is_gm = is_sys or frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_general_manager")) == 1
mine = frappe.get_all("Sales Person", filters={"custom_user": user, "is_group": 0},
                      fields=["name", "custom_team_manager"], limit=1)
me = mine[0].name if mine else None
my_team = (mine[0].custom_team_manager or "").strip() if mine else ""
managed = (frappe.db.get_value("User", user, "custom_managed_team") or "").strip()
if not managed and me and my_team and me.strip().lower().startswith(my_team.lower()):
    managed = my_team
today = frappe.utils.today()

FIELDS = ["name", "status", "customer", "customer_name", "bp_code", "sales_order", "parent_extension",
          "sales_person", "team", "requested_by", "requested_on", "request_reason",
          "credit_limit_at_request", "outstanding_at_request", "overdue_at_request", "order_amount", "excess_amount",
          "amount", "commitment_date", "reason", "remarks", "approved_by", "approved_on", "approver_role",
          "rejected_by", "rejected_on", "rejection_remarks", "escalated_on", "escalation_reason",
          "original_limit", "raised_limit", "original_commitment", "raised_commitment", "sap_reference", "sap_raised", "sap_raised_on", "sap_error",
          "paid_amount", "remaining_amount", "payment_status", "last_payment_check",
          "missed", "overdue_unchecked", "restore_status", "restored_on", "restore_reference"]

# Unset Int fields of a Single read back as 0, and a cap of 0 sends everything
# to the GM: the safe direction if the installer never wrote the defaults.
CAP_COUNT = frappe.utils.cint(frappe.db.get_single_value(SETTINGS, "manager_cap_count"))
CAP_DAYS = frappe.utils.cint(frappe.db.get_single_value(SETTINGS, "manager_cap_days")) or 90
DEFAULT_AUTHORITY = frappe.utils.flt(frappe.db.get_single_value(SETTINGS, "manager_max_amount"))
AUTH_ROWS = frappe.get_all("Manna Credit Extension Authority",
                           filters={"parenttype": SETTINGS, "parent": SETTINGS},
                           fields=["manager", "max_amount"], limit_page_length=0)


def notify(users, subject, name):
    for u in users:
        if not u:
            continue
        frappe.get_doc({"doctype": "Notification Log", "for_user": u, "type": "Alert",
                        "subject": subject, "document_type": "Manna Credit Extension",
                        "document_name": name}).insert(ignore_permissions=True)


def team_managers(team):
    if not team:
        return []
    return [u.name for u in frappe.get_all("User", filters={"custom_managed_team": team, "enabled": 1}, fields=["name"])]


def gm_users():
    return [u.name for u in frappe.get_all("User", filters={"custom_is_general_manager": 1, "enabled": 1}, fields=["name"])]


def outstanding_of(c):
    total = frappe.utils.flt(c.get("custom_outstanding_balance"))
    if total == 0:
        total = sum([frappe.utils.flt(c.get(k)) for k in ("custom_outstanding_0_30", "custom_outstanding_30_60",
                                                          "custom_outstanding_60_90", "custom_outstanding_90_plus")])
    return total


CUST_FIELDS = ["name", "customer_name", "custom_bp_code", "custom_credit_limit", "custom_outstanding_balance",
               "custom_outstanding_0_30", "custom_outstanding_30_60", "custom_outstanding_60_90",
               "custom_outstanding_90_plus", "custom_overdue_past_terms", "custom_payment_terms"]


def history_of(customer, fields):
    rows = frappe.get_all("Manna Credit Extension", filters={"customer": customer}, fields=fields,
                          order_by="creation asc", limit_page_length=0)
    pays = frappe.get_all("Manna Credit Extension Payment", filters={"parenttype": "Manna Credit Extension",
                          "parent": ["in", [r.name for r in rows] or ["-"]]},
                          fields=["parent", "sap_doc_entry", "doc_num", "payment_date", "amount"], order_by="payment_date asc",
                          limit_page_length=0)
    approved = [r for r in rows if r.approved_by]
    days = 0
    for r in approved:
        if r.commitment_date and r.approved_on:
            days = days + frappe.utils.date_diff(r.commitment_date, str(r.approved_on)[:10])
    return {
        "total_extensions": len(rows),
        "manager_approved": len([r for r in approved if r.approver_role == "manager"]),
        "gm_approved": len([r for r in approved if r.approver_role == "gm"]),
        "gm_rejections": len([r for r in rows if r.status == "Rejected by GM"]),
        "total_additional_credit": sum([frappe.utils.flt(r.amount) for r in approved]),
        "total_paid_against_commitments": sum([frappe.utils.flt(r.paid_amount) for r in rows]),
        "missed_commitments": len([r for r in rows if r.missed]),
        "gm_escalations": len([r for r in rows if r.escalated_on]),
        "total_extension_days": days,
        "current_status": rows[-1].status if rows else "",
        "extensions": [{"name": r.name, "status": r.status, "sales_order": r.sales_order, "amount": r.amount,
                        "approved_on": str(r.approved_on or ""), "approver_role": r.approver_role,
                        "commitment_date": str(r.commitment_date or ""), "paid_amount": r.paid_amount,
                        "payment_status": r.payment_status, "missed": r.missed, "sap_reference": r.sap_reference,
                        "sap_raised": r.sap_raised, "restore_status": r.restore_status,
                        "restore_reference": r.restore_reference} for r in rows],
        "payments": [{"extension": p.parent, "doc_num": p.doc_num, "date": str(p.payment_date or ""),
                      "amount": p.amount} for p in pays],
    }


def approvals_of(customer):
    # Every approval the customer ever had, for manager_recent's window.
    return [{"role": r.approver_role or "", "on": str(r.approved_on or "")}
            for r in frappe.get_all("Manna Credit Extension", filters={"customer": customer, "approved_on": ["is", "set"]},
                                    fields=["approver_role", "approved_on"], limit_page_length=0)]


def load(name):
    if not name or not frappe.db.exists("Manna Credit Extension", name):
        frappe.throw("Extension not found.")
    return frappe.get_doc("Manna Credit Extension", name)


def log(doc, act, role, remarks, amount, commitment):
    doc.append("log", {"action": act, "actor_role": role, "by_user": frappe.session.user,
                       "at": frappe.utils.now(), "remarks": remarks or "", "amount": amount or 0,
                       "commitment_date": commitment or None})


def ask_job(by):
    # The SAP job's flag; the job also runs on its own schedule, so a flag
    # that does not land only delays the push.
    try:
        ctl = frappe.get_doc("Manna Credit Extension Settings")
        ctl.push_requested = 1
        ctl.push_requested_by = by
        ctl.save(ignore_permissions=True)
    except Exception:
        frappe.log_error(title="manna_credit_extension: could not raise the SAP job's flag")


def ask_credit_sync(by):
    # The existing credit sync copies SAP's new limit to ERPNext; it is asked,
    # never changed.
    try:
        ctl = frappe.get_doc("SAP Sync Control")
        ctl.sync_requested = 1
        ctl.sync_requested_by = by
        ctl.sync_requested_at = frappe.utils.now()
        ctl.save(ignore_permissions=True)
    except Exception:
        frappe.log_error(title="manna_credit_extension: could not ask for the credit sync")


if action == "eligible":
    if is_gm:
        reps = None
    elif managed:
        reps = [s.name for s in frappe.get_all("Sales Person", filters={"custom_team_manager": managed}, fields=["name"])]
    elif me:
        reps = [me]
    else:
        frappe.throw("Only a rep, a manager or the GM can ask for a temporary credit extension.")
    f = {"custom_po_status": ["in", WAITING_ORDER], "docstatus": ["<", 2]}
    if reps is not None:
        f["custom_sales_person"] = ["in", reps or ["-"]]
    orders = frappe.get_all("Sales Order", filters=f, fields=["name", "customer", "total", "custom_sales_person",
                            "transaction_date", "custom_po_status"], order_by="creation desc", limit_page_length=300)
    taken = set([r.sales_order for r in frappe.get_all(DT, filters={"status": ["in", PENDING + RUNNING]},
                                                        fields=["sales_order"], limit_page_length=0)])
    out = []
    for o in orders:
        c = frappe.db.get_value("Customer", o.customer, CUST_FIELDS, as_dict=True)
        if not c:
            continue
        limit = frappe.utils.flt(c.custom_credit_limit)
        owed = outstanding_of(c)
        total = frappe.utils.flt(o.total)
        if limit <= 0 or owed + total <= limit or not (c.custom_bp_code or "").strip():
            continue
        out.append({"sales_order": o.name, "customer": o.customer, "customer_name": c.customer_name,
                    "bp_code": c.custom_bp_code, "sales_person": o.custom_sales_person,
                    "transaction_date": str(o.transaction_date or ""), "po_status": o.custom_po_status,
                    "order_amount": total, "credit_limit": limit, "outstanding": owed,
                    "overdue": frappe.utils.flt(c.custom_overdue_past_terms), "excess": round(owed + total - limit, 2),
                    "has_request": 1 if o.name in taken else 0})
    frappe.response["message"] = out

elif action == "list":
    filters = {}
    customer = clean(frappe.form_dict.get("customer"))
    if customer:
        filters["customer"] = customer
    so_filter = clean(frappe.form_dict.get("sales_order"))
    if so_filter:
        filters["sales_order"] = so_filter
    if is_gm:
        pass
    elif managed:
        filters["team"] = managed
    elif me:
        filters["sales_person"] = me
    else:
        frappe.throw("Only a rep, a manager or the GM can see temporary credit extensions.")
    rows = frappe.get_all(DT, filters=filters, fields=FIELDS, order_by="creation desc", limit_page_length=500)
    for r in rows:
        for k in ("requested_on", "approved_on", "rejected_on", "escalated_on", "sap_raised_on",
                  "last_payment_check", "restored_on", "commitment_date"):
            r[k] = str(r[k] or "")
        who = actor_for(r.sales_person, r.team, me, managed, is_gm)
        st = r.status or ""
        approver = (r.approver_role == "manager" and who in ("manager", "gm")) or (r.approver_role == "gm" and who == "gm")
        r["actor"] = who
        r["can_approve"] = 1 if next_status("approve", st, who) else 0
        r["can_reject"] = 1 if next_status("reject", st, who) else 0
        r["can_escalate"] = 1 if next_status("escalate", st, who) else 0
        r["can_retry"] = 1 if (approver and next_status("retry", st, "approver")) else 0
    frappe.response["message"] = rows

elif action == "detail":
    doc = load(clean(frappe.form_dict.get("name")))
    if not (is_gm or (managed and (doc.team or "") == managed) or (me and doc.sales_person == me)):
        frappe.throw("Not yours to see.", frappe.PermissionError)
    r = {}
    for k in FIELDS:
        v = doc.get(k)
        r[k] = str(v) if (v is not None and not isinstance(v, (int, float, str))) else v
    who = actor_for(doc.sales_person, doc.team, me, managed, is_gm)
    st = doc.status or ""
    approver = (doc.approver_role == "manager" and who in ("manager", "gm")) or (doc.approver_role == "gm" and who == "gm")
    r["actor"] = who
    r["can_approve"] = 1 if next_status("approve", st, who) else 0
    r["can_reject"] = 1 if next_status("reject", st, who) else 0
    r["can_escalate"] = 1 if next_status("escalate", st, who) else 0
    r["can_retry"] = 1 if (approver and next_status("retry", st, "approver")) else 0
    c = frappe.db.get_value("Customer", doc.customer, CUST_FIELDS, as_dict=True) or {}
    invoices = []
    if frappe.db.exists("DocType", "SAP Invoice"):
        invoices = frappe.get_all("SAP Invoice", filters={"customer": doc.customer},
                                  fields=["invoice_no", "posting_date", "due_date", "total", "paid", "balance", "status"],
                                  order_by="posting_date desc", limit_page_length=24)
        for i in invoices:
            i["posting_date"] = str(i.posting_date or "")
            i["due_date"] = str(i.due_date or "")
    frappe.response["message"] = {
        "extension": r,
        "customer": {"name": doc.customer, "customer_name": c.get("customer_name"), "bp_code": c.get("custom_bp_code"),
                     "credit_limit": frappe.utils.flt(c.get("custom_credit_limit")), "outstanding": outstanding_of(c) if c else 0,
                     "overdue": frappe.utils.flt(c.get("custom_overdue_past_terms")), "payment_terms": c.get("custom_payment_terms")},
        # The manager's own authority; to the GM, the team manager's, so the GM
        # can see why it came up.
        "manager_authority": (authority_for(user if who == "manager" else ((team_managers(doc.team) or [""])[0]),
                                            AUTH_ROWS, DEFAULT_AUTHORITY) if who in ("manager", "gm") else None),
        "manager_cap": {"count": CAP_COUNT, "days": CAP_DAYS,
                        "used": manager_recent(approvals_of(doc.customer), today, CAP_DAYS)},
        "payments": [{"doc_num": p.doc_num, "date": str(p.payment_date or ""), "amount": p.amount} for p in doc.payments],
        "log": [{"action": l.action, "role": l.actor_role, "by": l.by_user, "at": str(l.at or ""), "remarks": l.remarks,
                 "amount": l.amount, "commitment_date": str(l.commitment_date or "")} for l in doc.log],
        "sap_log": [{"at": str(s.at or ""), "operation": s.operation, "ok": s.ok, "request": s.request, "response": s.response}
                    for s in doc.sap_log] if who in ("manager", "gm") else [],
        "invoices": invoices,
        "history": history_of(doc.customer, FIELDS),
    }

elif action == "history":
    customer = clean(frappe.form_dict.get("customer"))
    if not customer:
        frappe.throw("Which customer?")
    if not (is_gm or managed or me):
        frappe.throw("Not yours to see.", frappe.PermissionError)
    frappe.response["message"] = history_of(customer, FIELDS)

elif action == "submit":
    so_name = clean(frappe.form_dict.get("sales_order"))
    if not so_name or not frappe.db.exists("Sales Order", so_name):
        frappe.throw("Order not found.")
    so = frappe.db.get_value("Sales Order", so_name, ["name", "customer", "total", "custom_sales_person",
                                                     "custom_po_status", "docstatus"], as_dict=True)
    rep_team = (frappe.db.get_value("Sales Person", so.custom_sales_person, "custom_team_manager") or "").strip() if so.custom_sales_person else ""
    if not (is_gm or (managed and rep_team == managed) or (me and so.custom_sales_person == me)):
        frappe.throw("Only the order's rep, their manager or the GM can ask for this.", frappe.PermissionError)
    if so.custom_po_status not in WAITING_ORDER or so.docstatus == 2:
        frappe.throw("Only an order still waiting for approval can have a temporary credit extension.")
    c = frappe.db.get_value("Customer", so.customer, CUST_FIELDS, as_dict=True)
    limit = frappe.utils.flt(c.custom_credit_limit)
    owed = outstanding_of(c)
    total = frappe.utils.flt(so.total)
    if not (c.custom_bp_code or "").strip():
        frappe.throw("This customer has no SAP code.")
    if limit <= 0 or owed + total <= limit:
        frappe.throw("This order does not take the customer past their credit limit.")
    if frappe.get_all(DT, filters={"customer": so.customer, "status": ["in", PENDING]}, limit=1):
        frappe.throw("This customer already has a temporary credit request waiting for a decision.")
    missed = len(frappe.get_all(DT, filters={"customer": so.customer, "missed": 1}, fields=["name"], limit_page_length=0))
    running = bool(frappe.get_all(DT, filters={"customer": so.customer, "status": ["in", RUNNING]}, limit=1))
    recent = manager_recent(approvals_of(so.customer), today, CAP_DAYS)
    status = route_status(missed, running, recent, CAP_COUNT)
    doc = frappe.get_doc({
        "doctype": DT, "status": status, "customer": so.customer, "customer_name": c.customer_name,
        "bp_code": c.custom_bp_code, "sales_order": so.name, "sales_person": so.custom_sales_person,
        "team": rep_team or None, "requested_by": user, "requested_on": frappe.utils.now(),
        "request_reason": clean(frappe.form_dict.get("reason")),
        "credit_limit_at_request": limit, "outstanding_at_request": owed,
        "overdue_at_request": frappe.utils.flt(c.custom_overdue_past_terms), "order_amount": total,
        "excess_amount": round(owed + total - limit, 2), "payment_status": "Not Paid",
    })
    if status == "Pending GM":
        doc.escalated_on = frappe.utils.now()
        if missed:
            doc.escalation_reason = "Missed a payment commitment before"
        elif running:
            doc.escalation_reason = "Another extension is still running"
        else:
            doc.escalation_reason = ("The manager's limit of " + str(CAP_COUNT) + " extensions in " + str(CAP_DAYS)
                                     + " days is reached (" + str(recent) + " given)")
    log(doc, "Requested", "rep" if me == so.custom_sales_person else ("gm" if is_gm else "manager"),
        doc.request_reason, 0, None)
    doc.insert(ignore_permissions=True)
    if status == "Pending GM":
        notify(gm_users(), "Temporary credit for " + (c.customer_name or so.customer) + " needs the GM: " + doc.escalation_reason, doc.name)
    else:
        notify(team_managers(rep_team), "Temporary credit asked for " + (c.customer_name or so.customer), doc.name)
    frappe.response["message"] = {"name": doc.name, "status": doc.status}

elif action in ("approve", "reject", "escalate", "retry"):
    doc = load(clean(frappe.form_dict.get("name")))
    who = actor_for(doc.sales_person, doc.team, me, managed, is_gm)
    st = doc.status or ""
    remarks = clean(frappe.form_dict.get("remarks"))
    now = frappe.utils.now()
    if action == "retry":
        ok = (doc.approver_role == "manager" and who in ("manager", "gm")) or (doc.approver_role == "gm" and who == "gm")
        if not (ok and next_status("retry", st, "approver")):
            frappe.throw("You cannot send this to SAP again (it is " + st + ").", frappe.PermissionError)
        doc.status = "Sending to SAP"
        doc.sap_error = ""
        log(doc, "Pushed to SAP again", who, "", 0, None)
        doc.save(ignore_permissions=True)
        ask_job(user)
        frappe.response["message"] = {"name": doc.name, "status": doc.status}
    else:
        to = next_status(action, st, who)
        if not to:
            frappe.throw("You cannot " + action + " this request now (it is " + st + ").", frappe.PermissionError)
        if action == "reject":
            if not remarks:
                frappe.throw("Enter the rejection remarks.")
            doc.status = to
            doc.rejected_by = user
            doc.rejected_on = now
            doc.rejection_remarks = remarks
            log(doc, to, who, remarks, 0, None)
            doc.save(ignore_permissions=True)
            if who == "gm":
                notify(team_managers(doc.team), "The GM rejected temporary credit for " + (doc.customer_name or doc.customer), doc.name)
            frappe.response["message"] = {"name": doc.name, "status": doc.status}
        elif action == "escalate":
            doc.status = to
            doc.escalated_on = now
            doc.escalation_reason = remarks or "Sent to the GM by the manager"
            log(doc, "Sent to GM", who, remarks, 0, None)
            doc.save(ignore_permissions=True)
            notify(gm_users(), "Temporary credit for " + (doc.customer_name or doc.customer) + " sent to the GM", doc.name)
            frappe.response["message"] = {"name": doc.name, "status": doc.status}
        else:
            amount = frappe.utils.flt(frappe.form_dict.get("amount"))
            commitment = clean(frappe.form_dict.get("commitment_date"))
            reason = clean(frappe.form_dict.get("reason")) or doc.request_reason or ""
            if who == "manager":
                problem = check_manager(amount, authority_for(user, AUTH_ROWS, DEFAULT_AUTHORITY),
                                        today, commitment, reason, remarks)
                if not problem:
                    if frappe.get_all(DT, filters={"customer": doc.customer, "missed": 1}, limit=1):
                        problem = "missed"
                    elif frappe.get_all(DT, filters={"customer": doc.customer, "status": ["in", RUNNING], "name": ["!=", doc.name]}, limit=1):
                        problem = "running"
                    elif route_status(0, False, manager_recent(approvals_of(doc.customer), today, CAP_DAYS), CAP_COUNT) == "Pending GM":
                        # Asked before the cap filled, decided after: still the GM's.
                        problem = "cap"
                if problem:
                    frappe.throw({"missed": "This customer missed a commitment before. Send it to the GM.",
                                  "running": "This customer already has a temporary extension running. Send it to the GM.",
                                  "cap": "This customer has had " + str(CAP_COUNT) + " manager extensions in " + str(CAP_DAYS)
                                         + " days. Send it to the GM."}.get(problem) or MESSAGES[problem])
            else:
                problem = check_gm(amount, today, commitment, remarks)
                if problem:
                    frappe.throw(MESSAGES[problem].replace("A manager may give at most 10 days from today.", ""))
            target = doc
            if to == "Renewed by GM":
                # Never overwrite: the overdue record stays as it was, and the
                # GM's approval is a new extension linked to it.
                target = frappe.get_doc({
                    "doctype": DT, "customer": doc.customer, "customer_name": doc.customer_name,
                    "bp_code": doc.bp_code, "sales_order": doc.sales_order, "parent_extension": doc.name,
                    "sales_person": doc.sales_person, "team": doc.team, "requested_by": user, "requested_on": now,
                    "request_reason": "Renewal of " + doc.name + " after a missed commitment",
                    "credit_limit_at_request": doc.credit_limit_at_request, "outstanding_at_request": doc.outstanding_at_request,
                    "overdue_at_request": doc.overdue_at_request, "order_amount": doc.order_amount,
                    "excess_amount": doc.excess_amount, "payment_status": "Not Paid",
                })
                doc.status = "Renewed by GM"
                log(doc, "Renewed by GM", who, remarks, amount, commitment)
                doc.save(ignore_permissions=True)
            target.status = "Sending to SAP"
            target.amount = amount
            target.commitment_date = commitment
            target.reason = reason
            target.remarks = remarks
            target.approved_by = user
            target.approved_on = now
            target.approver_role = who
            target.remaining_amount = amount
            target.payment_status = "Not Paid"
            log(target, "Approved and pushed to SAP", who, remarks, amount, commitment)
            if target.is_new():
                target.insert(ignore_permissions=True)
            else:
                target.save(ignore_permissions=True)
            ask_job(user)
            frappe.response["message"] = {"name": target.name, "status": target.status, "renewed": doc.name if target.name != doc.name else ""}

elif action == "sap_event":
    if not (is_bot or is_sys):
        frappe.throw("Only the SAP job reports to an extension.", frappe.PermissionError)
    doc = load(clean(frappe.form_dict.get("name")))
    event = clean(frappe.form_dict.get("event"))
    st = doc.status or ""
    now = frappe.utils.now()
    req = clean(frappe.form_dict.get("request"))
    resp = clean(frappe.form_dict.get("response"))
    if req or resp:
        doc.append("sap_log", {"at": now, "operation": event, "ok": 0 if event in ("failed", "review") else 1,
                               "request": req[:4000], "response": resp[:4000]})
    changed = ""
    if event == "raised":
        to = next_status("sap_raised", st, "sap_job")
        if not to:
            frappe.throw("Not waiting for SAP (it is " + st + ").")
        doc.status = to
        doc.original_limit = frappe.utils.flt(frappe.form_dict.get("original_limit"))
        doc.raised_limit = frappe.utils.flt(frappe.form_dict.get("raised_limit"))
        # SAP's commitment limit moves with the credit limit (it may not be
        # below it); kept so the restore can put it back too.
        doc.original_commitment = frappe.utils.flt(frappe.form_dict.get("original_commitment"))
        doc.raised_commitment = frappe.utils.flt(frappe.form_dict.get("raised_commitment"))
        doc.sap_reference = clean(frappe.form_dict.get("sap_reference"))
        doc.sap_raised = 1
        doc.sap_raised_on = now
        doc.sap_error = ""
        log(doc, "Credit limit raised in SAP", "sap_job", doc.sap_reference, doc.amount, doc.commitment_date)
        changed = "raised"
    elif event == "original":
        # Saved before the first PATCH, so a retry knows the limit to restore.
        if not doc.original_limit:
            doc.original_limit = frappe.utils.flt(frappe.form_dict.get("original_limit"))
        if not doc.original_commitment:
            doc.original_commitment = frappe.utils.flt(frappe.form_dict.get("original_commitment"))
    elif event == "failed":
        to = next_status("sap_failed", st, "sap_job")
        if not to:
            frappe.throw("Not waiting for SAP (it is " + st + ").")
        doc.status = to
        doc.sap_error = clean(frappe.form_dict.get("error")) or "SAP refused the change."
        log(doc, "SAP refused", "sap_job", doc.sap_error, 0, None)
        notify([doc.approved_by], "SAP refused the temporary credit for " + (doc.customer_name or doc.customer), doc.name)
    elif event == "payments" and doc.overdue_unchecked:
        # The watchdog escalated this one before the job counted its payments;
        # the count settles it now (late_check). Its escalation was notified
        # then, so only a Paid after all is news.
        rows = json.loads(frappe.form_dict.get("payments") or "[]")
        have = set([str(p.sap_doc_entry) for p in doc.payments])
        for p in rows:
            if str(p.get("doc_entry")) in have:
                continue
            have.add(str(p.get("doc_entry")))
            doc.append("payments", {"sap_doc_entry": str(p.get("doc_entry")), "doc_num": str(p.get("doc_num") or ""),
                                    "payment_date": str(p.get("date"))[:10], "amount": frappe.utils.flt(p.get("amount"))})
        paid = sum([frappe.utils.flt(p.amount) for p in doc.payments])
        ps = payment_status(doc.amount, paid)
        doc.paid_amount = paid
        doc.remaining_amount = ps["remaining"]
        doc.payment_status = ps["status"]
        doc.last_payment_check = now
        lc = late_check(st, outcome(doc.amount, paid, today, doc.commitment_date))
        doc.status = lc["status"]
        doc.missed = lc["missed"]
        doc.overdue_unchecked = 0
        if lc["missed"]:
            log(doc, "Missed commitment confirmed against SAP", "sap_job",
                "Paid " + str(paid) + " of " + str(doc.amount) + " by " + str(doc.commitment_date), paid, None)
        else:
            log(doc, "Paid in time after all (checked against SAP late)", "sap_job", "Payments " + str(paid), paid, None)
            changed = "paid_late"
    elif event == "payments":
        if st != "Active":
            frappe.throw("Payments are only counted while the extension is active (it is " + st + ").")
        rows = json.loads(frappe.form_dict.get("payments") or "[]")
        have = set([str(p.sap_doc_entry) for p in doc.payments])
        for p in rows:
            if str(p.get("doc_entry")) in have:
                continue
            have.add(str(p.get("doc_entry")))
            doc.append("payments", {"sap_doc_entry": str(p.get("doc_entry")), "doc_num": str(p.get("doc_num") or ""),
                                    "payment_date": str(p.get("date"))[:10], "amount": frappe.utils.flt(p.get("amount"))})
        paid = sum([frappe.utils.flt(p.amount) for p in doc.payments])
        ps = payment_status(doc.amount, paid)
        doc.paid_amount = paid
        doc.remaining_amount = ps["remaining"]
        doc.payment_status = ps["status"]
        doc.last_payment_check = now
        oc = outcome(doc.amount, paid, today, doc.commitment_date)
        if oc == "paid":
            doc.status = next_status("sap_paid", st, "sap_job")
            doc.restore_status = "Pending"
            log(doc, "Paid", "sap_job", "Payments " + str(paid), paid, None)
            changed = "paid"
        elif oc == "overdue":
            doc.status = next_status("sap_overdue", st, "sap_job")
            doc.missed = 1
            doc.restore_status = "Pending"
            doc.escalated_on = now
            doc.escalation_reason = "Payment commitment overdue: paid " + str(paid) + " of " + str(doc.amount)
            log(doc, "Payment Commitment Overdue", "sap_job", doc.escalation_reason, paid, None)
            changed = "overdue"
    elif event == "restored":
        doc.restore_status = "Restored"
        doc.restored_on = now
        doc.restore_reference = clean(frappe.form_dict.get("sap_reference"))
        log(doc, "Credit limit restored in SAP", "sap_job", doc.restore_reference, doc.original_limit, None)
        changed = "restored"
    elif event == "review":
        doc.restore_status = "Needs Review"
        log(doc, "Restore needs review", "sap_job", clean(frappe.form_dict.get("error")), 0, None)
        changed = "review"
    else:
        frappe.throw("Unknown event.")
    doc.save(ignore_permissions=True)
    # The notifications follow the status change, which happens once: a repeat
    # of the same event is refused above before reaching here.
    who_name = doc.customer_name or doc.customer
    if changed == "overdue":
        notify(team_managers(doc.team) + gm_users(), "Payment commitment overdue: " + who_name + " - escalated to the GM", doc.name)
    elif changed == "paid_late":
        notify(team_managers(doc.team) + gm_users(), "Paid in time after all: " + who_name + " (" + doc.name
               + ") - SAP shows the commitment met", doc.name)
    elif changed == "review":
        notify(gm_users() + [doc.approved_by], "Check SAP's credit limit for " + who_name + ": it was changed while the extension ran", doc.name)
    if changed in ("raised", "restored"):
        ask_credit_sync(user)
    frappe.response["message"] = {"name": doc.name, "status": doc.status, "restore_status": doc.restore_status}

elif action == "settings":
    if not (is_gm or managed):
        frappe.throw("Only a manager or the GM can see the approval authority.", frappe.PermissionError)
    if frappe.form_dict.get("save"):
        if not is_gm:
            frappe.throw("Only the GM sets the approval authority.", frappe.PermissionError)
        s = frappe.get_doc(SETTINGS)
        if frappe.form_dict.get("manager_max_amount") is not None:
            s.manager_max_amount = max(0, frappe.utils.flt(frappe.form_dict.get("manager_max_amount")))
        if frappe.form_dict.get("manager_authority_percent") is not None:
            s.manager_authority_percent = max(0, frappe.utils.flt(frappe.form_dict.get("manager_authority_percent")))
        if frappe.form_dict.get("manager_cap_count") is not None:
            s.manager_cap_count = max(0, frappe.utils.cint(frappe.form_dict.get("manager_cap_count")))
        if frappe.form_dict.get("manager_cap_days") is not None:
            d = frappe.utils.cint(frappe.form_dict.get("manager_cap_days"))
            if d < 1:
                frappe.throw("The window must be at least one day.")
            s.manager_cap_days = d
        if frappe.form_dict.get("authorities") is not None:
            rows = json.loads(frappe.form_dict.get("authorities") or "[]")
            s.set("authorities", [])
            for r in rows:
                m = clean(r.get("manager"))
                if m and frappe.db.exists("User", m):
                    s.append("authorities", {"manager": m, "max_amount": max(0, frappe.utils.flt(r.get("max_amount")))})
        # The Single tracks changes, so every figure the GM sets is in its
        # Version history: who, when, from what to what.
        s.save(ignore_permissions=True)
        CAP_COUNT = frappe.utils.cint(s.manager_cap_count)
        CAP_DAYS = frappe.utils.cint(s.manager_cap_days) or 90
        DEFAULT_AUTHORITY = frappe.utils.flt(s.manager_max_amount)
        AUTH_ROWS = [{"manager": r.manager, "max_amount": r.max_amount} for r in s.authorities]
    # The payment commitment ladder's default (17 Nov 2026): a share of the
    # order, unless a Manager has their own rupee figure below.
    pct = frappe.db.get_single_value(SETTINGS, "manager_authority_percent")
    pct = 10.0 if pct is None or str(pct) == "" else frappe.utils.flt(pct)
    own_of = {}
    for r in AUTH_ROWS:
        own_of[r.get("manager")] = r.get("max_amount")
    managers = frappe.get_all("User", filters={"custom_managed_team": ["is", "set"], "enabled": 1},
                              fields=["name", "full_name", "custom_managed_team"], order_by="full_name asc", limit_page_length=0)
    # A loop, not a comprehension: before Python 3.12 a Server Script
    # comprehension cannot see the script's own names (authority_for, user).
    shown = []
    for m in managers:
        if is_gm or m.name == user:
            shown.append({"user": m.name, "name": m.full_name or m.name, "team": m.custom_managed_team,
                          "authority": authority_for(m.name, AUTH_ROWS, DEFAULT_AUTHORITY),
                          "own": own_of.get(m.name)})
    frappe.response["message"] = {
        "can_edit": 1 if is_gm else 0,
        "manager_max_amount": DEFAULT_AUTHORITY, "manager_cap_count": CAP_COUNT, "manager_cap_days": CAP_DAYS,
        "manager_authority_percent": pct,
        "my_own_authority": own_of.get(user) if managed else None,
        "max_days": 10,
        "authorities": [{"manager": r.get("manager"), "max_amount": r.get("max_amount")} for r in AUTH_ROWS],
        "managers": shown,
        "my_authority": authority_for(user, AUTH_ROWS, DEFAULT_AUTHORITY) if managed else None,
    }

elif action == "alerts":
    # Notification Log is Frappe's per-user store, and the script writes every
    # extension notification there; neither app read it before 17 Nov 2026.
    rows = frappe.get_all("Notification Log", filters={"for_user": user, "document_type": DT},
                          fields=["name", "subject", "document_name", "read", "creation"],
                          order_by="creation desc", limit_page_length=50)
    frappe.response["message"] = [{"name": r.name, "subject": r.subject, "extension": r.document_name,
                                   "read": 1 if r.read else 0, "at": str(r.creation)} for r in rows]

elif action == "seen":
    for r in frappe.get_all("Notification Log", filters={"for_user": user, "document_type": DT, "read": 0},
                            fields=["name"], limit_page_length=0):
        frappe.db.set_value("Notification Log", r.name, "read", 1, update_modified=False)
    frappe.response["message"] = "ok"

else:
    frappe.throw("Unknown action.")
