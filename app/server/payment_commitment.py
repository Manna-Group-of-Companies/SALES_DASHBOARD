# Frappe Server Script
#   Name          : manna_payment_commitment
#   Script Type   : API
#   API Method    : manna_payment_commitment
#   Args (POST)   : action =
#     route     : sales_order               what the order needs, where it goes, and what this login may do
#     approve   : sales_order, commitment_date, remarks
#                                           the Manager's or the GM's approval WITH a 10-day commitment
#     history   : customer                  the customer's whole commitment history
#     orders    : names (JSON list)         each order's stage and commitment, for the Manager's and GM's lists
#     list      : -                         every commitment this login may see
#
# The 10-day payment commitment ladder (17 Nov 2026, the user's spec). An
# order whose customer is overdue more than 30 days past terms, or which takes
# them past their credit limit, needs a credit decision. The Manager approves
# it only with a commitment of at most 10 days (over the limit only within
# their approval authority, Manna Credit Extension Settings); a customer with
# a missed commitment not yet cleared goes to the GM, bypassing the Manager;
# the GM approves another 10 days or rejects. The order's own approval flow is
# unchanged otherwise: the Manager's approval is 'PO Approved - Ready for SAP',
# the GM's is 'Pending Final Approval' and the Manager pushes.
#
# manna_payment_commitment_order (a DocType Event on Sales Order) is the
# backstop: no order needing a commitment is approved without one, and an
# order of a GM-locked customer goes to the GM when it is raised.
# shared/fixtures/payment_commitment.json pins every rule below.
#
# safe_exec: no import (json is given), no frappe.get_roles / parse_json /
# hasattr, and a def may not call another def or see the script's names - the
# rule functions are leaves with their numbers inside them.

# ---- rule: shared/fixtures/payment_commitment.json ----

MAX_DAYS = 10
OVERDUE_DAYS = 30


def needs_of(customer, order_total):
    c = customer or {}
    def_f = 0.0
    stored = float(c.get("custom_outstanding_balance") or 0)
    buckets = [float(c.get(k) or 0) for k in ("custom_outstanding_0_30", "custom_outstanding_30_60",
                                              "custom_outstanding_60_90", "custom_outstanding_90_plus")]
    known = buckets[0] != 0 or buckets[1] != 0 or buckets[2] != 0 or buckets[3] != 0
    total = stored if stored != 0 else (round(sum(buckets), 2) if known else def_f)
    limit = float(c.get("custom_credit_limit") or 0)
    overdue = float(c.get("custom_overdue_past_terms") or 0)
    days = int(round(float(c.get("custom_overdue_days") or 0)))
    overdue30 = overdue > 1 and days > 30
    over_limit = limit > 0 and total + float(order_total or 0) > limit
    excess = round(total + float(order_total or 0) - limit, 2) if over_limit else 0
    return {"overdue30": overdue30, "over_limit": over_limit, "excess": excess, "needs": overdue30 or over_limit}


def route_of(needs, over_limit, excess, authority, gm_lock, cap_reached):
    if gm_lock:
        return "gm"
    if not needs:
        return "manager"
    a = float(authority or 0)
    if over_limit and not (a > 0 and float(excess or 0) <= a):
        return "gm"
    if cap_reached:
        return "gm"
    return "manager_commitment"


def gm_lock_of(commitments):
    for c in commitments:
        if (c.get("status") or "") == "Missed" and not str(c.get("cleared_on") or "").strip():
            return True
    return False


def check_approval(approved_on, commitment, remarks):
    d0 = str(approved_on or "")[:10]
    c = str(commitment or "")[:10]
    if len(c) != 10 or len(d0) != 10 or c < d0:
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
    if not str(remarks or "").strip():
        return "remarks"
    return ""


def order_stage(po_status, pushed, commitment):
    s = (po_status or "").strip()
    if s == "Rejected":
        return "Rejected"
    if s == "Pending GM Approval":
        return "Sent to GM"
    if s == "Pending Final Approval":
        return "GM Approved"
    if s == "PO Approved - Ready for SAP":
        if commitment in ("Running", "Unchecked"):
            return "Payment Pending"
        return "SAP Pushed" if pushed else "Approved"
    return "Pending Manager Approval"

# ---- end rule ----


def clean(v):
    s = (v or "")
    s = s.strip() if isinstance(s, str) else str(s)
    return "" if s == "null" else s


DT = "Manna Payment Commitment"
XS = "Manna Credit Extension Settings"
user = frappe.session.user
action = clean(frappe.form_dict.get("action")) or "route"
today = frappe.utils.today()
now = frappe.utils.now()

is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1))
is_gm = is_sys or frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_general_manager")) == 1
mine = frappe.get_all("Sales Person", filters={"custom_user": user, "is_group": 0},
                      fields=["name", "custom_team_manager"], limit=1)
me = mine[0].name if mine else None
my_team = (mine[0].custom_team_manager or "").strip() if mine else ""
managed = (frappe.db.get_value("User", user, "custom_managed_team") or "").strip()
if not managed and me and my_team and me.strip().lower().startswith(my_team.lower()):
    managed = my_team

HIST_FIELDS = ["name", "status", "customer", "sales_order", "order_date", "order_amount", "reason", "approver_role",
               "approved_by", "approved_on", "days", "commitment_date", "remarks", "outstanding_at", "overdue_at",
               "overdue_days_at", "credit_limit_at", "excess_at", "kept_on", "missed_on", "cleared_on", "overdue_last"]

# Unset Ints of a Single read 0; a cap of 0 sends every commitment to the GM,
# the safe direction (credit_extension.json's manager_cap).
CAP_COUNT = frappe.utils.cint(frappe.db.get_single_value(XS, "manager_cap_count"))
CAP_DAYS = frappe.utils.cint(frappe.db.get_single_value(XS, "manager_cap_days")) or 90
# The user, 17 Nov 2026: by default a Manager may approve up to 10% of the
# order over the limit (manager_authority_percent); a Manager's own row in the
# authorities table is a rupee figure and wins over it.
AUTH_PCT = frappe.db.get_single_value(XS, "manager_authority_percent")
AUTH_PCT = 10.0 if AUTH_PCT is None or str(AUTH_PCT) == "" else frappe.utils.flt(AUTH_PCT)
AUTH_ROWS = frappe.get_all("Manna Credit Extension Authority", filters={"parenttype": XS, "parent": XS},
                           fields=["manager", "max_amount"], limit_page_length=0)


def order_team(sales_person):
    if not sales_person:
        return ""
    return (frappe.db.get_value("Sales Person", sales_person, "custom_team_manager") or "").strip()


def team_managers(team):
    if not team:
        return []
    return [u.name for u in frappe.get_all("User", filters={"custom_managed_team": team, "enabled": 1}, fields=["name"])]


def commitments_of(customer, fields):
    return frappe.get_all("Manna Payment Commitment", filters={"customer": customer, "status": ["!=", "Pending"]},
                          fields=fields, order_by="creation asc", limit_page_length=0)


def picture(so_name):
    # Everything the ladder needs about one order, as the server reads it now.
    so = frappe.db.get_value("Sales Order", so_name, ["name", "customer", "customer_name", "total", "grand_total",
                             "transaction_date", "custom_sales_person", "custom_po_status", "docstatus"], as_dict=True)
    if not so:
        frappe.throw("Order not found.")
    c = frappe.db.get_value("Customer", so.customer, ["name", "customer_name", "custom_bp_code", "custom_credit_limit",
                            "custom_outstanding_balance", "custom_outstanding_0_30", "custom_outstanding_30_60",
                            "custom_outstanding_60_90", "custom_outstanding_90_plus", "custom_overdue_past_terms",
                            "custom_overdue_days", "custom_payment_terms"], as_dict=True) or {}
    return {"so": so, "customer": c}


def as_rows(rows):
    out = []
    for r in rows:
        d = {}
        for k in r:
            v = r[k]
            d[k] = str(v) if (v is not None and not isinstance(v, (int, float, str))) else v
        out.append(d)
    return out


if action == "route":
    p = picture(clean(frappe.form_dict.get("sales_order")))
    so = p["so"]
    team = order_team(so.custom_sales_person)
    if not (is_gm or (managed and managed == team) or (me and so.custom_sales_person == me)):
        frappe.throw("Not yours to see.", frappe.PermissionError)
    n = needs_of(p["customer"], so.total)
    hist = commitments_of(so.customer, ["name", "status", "cleared_on", "approver_role", "approved_on"])
    lock = gm_lock_of(hist)
    # The authority is the order's team manager's, whoever looks at it.
    manager_user = user if (managed and managed == team) else ((team_managers(team) or [""])[0])
    authority = round(frappe.utils.flt(so.total) * AUTH_PCT / 100, 2)
    for r in AUTH_ROWS:
        if r.manager == manager_user:
            authority = frappe.utils.flt(r.max_amount)
    used = 0
    for h in hist:
        if h.approver_role == "manager" and h.approved_on and frappe.utils.date_diff(today, h.approved_on) < CAP_DAYS:
            used = used + 1
    cap_reached = used >= CAP_COUNT
    route = route_of(n["needs"], n["over_limit"], n["excess"], authority, lock, cap_reached)
    pend = frappe.get_all(DT, filters={"sales_order": so.name, "status": ["!=", "Cancelled"]},
                          fields=["name", "status", "commitment_date", "remarks", "approver_role"],
                          order_by="creation desc", limit=1)
    frappe.response["message"] = {
        "sales_order": so.name, "customer": so.customer, "needs": n, "route": route, "gm_lock": lock,
        "authority": authority, "cap": {"count": CAP_COUNT, "days": CAP_DAYS, "used": used, "reached": cap_reached},
        "max_days": MAX_DAYS, "commitment": as_rows(pend)[0] if pend else None,
        "stage": order_stage(so.custom_po_status, False, pend[0].status if pend else ""),
    }

elif action == "approve":
    # Entered with the Manager's or the GM's approval; it becomes Running when
    # the order's approval is saved (manna_payment_commitment_order), so an
    # approval that fails leaves nothing active behind.
    p = picture(clean(frappe.form_dict.get("sales_order")))
    so = p["so"]
    team = order_team(so.custom_sales_person)
    role = "gm" if is_gm else ("manager" if (managed and managed == team) else "")
    if not role:
        frappe.throw("Only the order's manager or the GM gives a payment commitment.", frappe.PermissionError)
    commitment = clean(frappe.form_dict.get("commitment_date"))
    remarks = clean(frappe.form_dict.get("remarks"))
    problem = check_approval(today, commitment, remarks)
    if problem:
        frappe.throw({"date_past": "Choose a payment commitment date from today on.",
                      "too_long": "A payment commitment may be at most 10 days.",
                      "remarks": "Enter your remarks."}[problem])
    n = needs_of(p["customer"], so.total)
    lock = gm_lock_of(commitments_of(so.customer, ["name", "status", "cleared_on"]))
    if role == "manager" and lock:
        frappe.throw("This customer missed a payment commitment that is not cleared: the order is the GM's.")
    for old in frappe.get_all(DT, filters={"sales_order": so.name, "status": "Pending"}, pluck="name"):
        frappe.delete_doc(DT, old, ignore_permissions=True, force=True)
    c = p["customer"]
    why = []
    if n["overdue30"]:
        why.append("Overdue more than 30 days past terms")
    if n["over_limit"]:
        why.append("Over the credit limit by Rs " + str(int(round(n["excess"]))))
    if lock:
        why.append("Missed a commitment not yet cleared")
    doc = frappe.get_doc({
        "doctype": DT, "status": "Pending", "customer": so.customer, "customer_name": so.customer_name,
        "bp_code": c.get("custom_bp_code"), "sales_order": so.name, "order_date": so.transaction_date,
        "order_amount": so.total, "sales_person": so.custom_sales_person, "team": team or None,
        "reason": "; ".join(why) or "Asked by the approver",
        "outstanding_at": frappe.utils.flt(c.get("custom_outstanding_balance")),
        "overdue_at": frappe.utils.flt(c.get("custom_overdue_past_terms")),
        "overdue_days_at": frappe.utils.cint(c.get("custom_overdue_days")),
        "credit_limit_at": frappe.utils.flt(c.get("custom_credit_limit")), "excess_at": n["excess"],
        "approver_role": role, "approved_by": user, "days": frappe.utils.date_diff(commitment, today),
        "commitment_date": commitment, "remarks": remarks,
    })
    doc.append("log", {"action": "Entered with the approval", "actor_role": role, "by_user": user, "at": now,
                       "remarks": remarks})
    doc.insert(ignore_permissions=True)
    frappe.response["message"] = {"name": doc.name, "status": doc.status}

elif action == "history":
    customer = clean(frappe.form_dict.get("customer"))
    if not customer:
        frappe.throw("Which customer?")
    if not (is_gm or managed or me):
        frappe.throw("Not yours to see.", frappe.PermissionError)
    rows = commitments_of(customer, HIST_FIELDS)
    given = [r for r in rows if r.status != "Cancelled"]
    c = frappe.db.get_value("Customer", customer, ["custom_outstanding_balance", "custom_overdue_past_terms",
                            "custom_overdue_days"], as_dict=True) or {}
    frappe.response["message"] = {
        "customer": customer,
        "commitments_given": len(given),
        "total_days": sum([frappe.utils.cint(r.days) for r in given]),
        "by_manager": len([r for r in given if r.approver_role == "manager"]),
        "by_gm": len([r for r in given if r.approver_role == "gm"]),
        "kept": len([r for r in given if r.status == "Kept"]),
        "missed": len([r for r in given if r.status == "Missed"]),
        "running": len([r for r in given if r.status in ("Running", "Unchecked")]),
        "gm_lock": gm_lock_of(given),
        "outstanding_now": frappe.utils.flt(c.get("custom_outstanding_balance")),
        "overdue_now": frappe.utils.flt(c.get("custom_overdue_past_terms")),
        "overdue_days_now": frappe.utils.cint(c.get("custom_overdue_days")),
        "rows": as_rows(rows[::-1]),
    }

elif action == "list":
    # Every commitment this login may see: the GM all, a Manager their team's,
    # a rep their own; newest first.
    f = {"status": ["!=", "Pending"]}
    if is_gm:
        pass
    elif managed:
        f["team"] = managed
    elif me:
        f["sales_person"] = me
    else:
        frappe.throw("Not yours to see.", frappe.PermissionError)
    rows = frappe.get_all(DT, filters=f, fields=HIST_FIELDS + ["customer_name", "sales_person", "team"],
                          order_by="creation desc", limit_page_length=500)
    frappe.response["message"] = as_rows(rows)

elif action == "orders":
    # Each order's live commitment, and which customers are with the GM, for
    # the Manager's and GM's lists.
    if not (is_gm or managed or me):
        frappe.throw("Not yours to see.", frappe.PermissionError)
    names = json.loads(frappe.form_dict.get("names") or "[]")
    out = {}
    if names:
        for r in frappe.get_all(DT, filters={"sales_order": ["in", names[:1000]], "status": ["not in", ["Pending", "Cancelled"]]},
                                fields=["name", "sales_order", "status", "commitment_date", "approver_role", "days"],
                                order_by="creation asc", limit_page_length=0):
            out[r.sales_order] = {"name": r.name, "status": r.status, "commitment_date": str(r.commitment_date or ""),
                                  "approver_role": r.approver_role, "days": r.days}
    locked = {}
    custs = json.loads(frappe.form_dict.get("customers") or "[]")
    if custs:
        for r in frappe.get_all(DT, filters={"customer": ["in", custs[:1000]], "status": "Missed",
                                             "cleared_on": ["is", "not set"]}, fields=["customer"], limit_page_length=0):
            locked[r.customer] = 1
    # In SAP: SAP's order number, Hi-Tech's or (manna_first) Manna Treads'.
    # The second field is on some sites only, so it is asked for only where
    # it exists.
    pushed = []
    if names:
        fields = ["name", "custom_sap_sales_order"]
        try:
            if frappe.get_meta("Sales Order").has_field("custom_mt_sales_order"):
                fields.append("custom_mt_sales_order")
        except Exception:
            pass
        for r in frappe.get_all("Sales Order", filters={"name": ["in", names[:1000]]}, fields=fields, limit_page_length=0):
            if (r.get("custom_sap_sales_order") or "").strip() or (r.get("custom_mt_sales_order") or "").strip():
                pushed.append(r.name)
    frappe.response["message"] = {"orders": out, "gm_locked": locked, "pushed": pushed}

elif action == "alerts":
    # This login's notifications about the ladder: commitments, orders sent to
    # the GM directly, and the earlier temporary credit extensions'.
    rows = frappe.get_all("Notification Log", filters={"for_user": user, "document_type": ["in", [DT, "Manna Credit Extension", "Sales Order"]]},
                          fields=["name", "subject", "document_type", "document_name", "read", "creation"],
                          order_by="creation desc", limit_page_length=80)
    out = []
    for r in rows:
        if r.document_type == "Sales Order" and not (r.subject or "").startswith("Sent to GM"):
            continue
        out.append({"name": r.name, "subject": r.subject, "doctype": r.document_type, "docname": r.document_name,
                    "read": 1 if r.read else 0, "at": str(r.creation)})
    frappe.response["message"] = out[:50]

elif action == "seen":
    for r in frappe.get_all("Notification Log", filters={"for_user": user, "read": 0,
                            "document_type": ["in", [DT, "Manna Credit Extension", "Sales Order"]]},
                            fields=["name", "document_type", "subject"], limit_page_length=0):
        if r.document_type == "Sales Order" and not (r.subject or "").startswith("Sent to GM"):
            continue
        frappe.db.set_value("Notification Log", r.name, "read", 1, update_modified=False)
    frappe.response["message"] = "ok"

else:
    frappe.throw("Unknown action.")
