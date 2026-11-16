# Frappe Server Script
#   Name          : manna_credit_period_request
#   Script Type   : API
#   API Method    : manna_credit_period_request
#   Args (POST)   : action = list | terms | submit | decide | escalate | push | sap_result
#     list       : customer (optional)
#     terms      : -
#     submit     : customer, term_code, reason
#     decide     : name, decision = Approve | Reject, note (needed to Reject)
#     escalate   : name, note (optional)
#     push       : name
#     sap_result : name, ok = 1 | 0, error, previous_term   (the credit sync only)
#
# Credit-period requests (16 Nov 2026, the user): a customer asks, through
# their rep, for a different credit period - the SAP payment term on their
# Manna Treads account. Up to 30 days the rep's manager approves it and pushes
# it to SAP; 31 to 40 days the manager may only escalate it (or reject it) and
# the GM approves and pushes it. Over 40 days is refused. The GM may decide any
# open request, and is the manager of a rep with no team.
# shared/fixtures/credit_period_request.json pins every rule; both apps
# implement it to draw their buttons, but THIS is where it is enforced - the
# doctype is System Manager's only, so the apps cannot write around it.
#
# "Push" marks the request 'Sending to SAP' and raises the credit sync's flag
# (SAP Sync Control). The sync (sap-credit-sync/Sync-SapCreditLimits.ps1)
# changes the business partner's payment term in Manna Treads and answers
# through sap_result: 'In SAP', or back to 'Approved' with SAP's error. It
# writes the payment term only, never the credit limit.
#
# The terms on offer are SAP's own, copied by the same sync to
# SAP Sync Control.payment_terms_json as [{code, name, days}].
#
# safe_exec: no frappe.get_roles / parse_json / hasattr, no augmented
# assignment to an item, and a def may not call another def or see the
# script's names - so the rule functions below are leaves, with their numbers
# written inside them. No import either: safe_exec has no __import__, and
# hands the script json already.

# ---- rule: shared/fixtures/credit_period_request.json ----
# test_credit_period_request.py runs the text between these two markers
# against the fixture. Keep them leaves.


def next_status(action, status, days, actor):
    """The status [action] by [actor] moves a request to, or "" when refused."""
    d = int(days or 0)
    if d < 0 or d > 40:
        return ""
    gm_band = d > 30
    if action == "approve" or action == "reject":
        to = "Approved" if action == "approve" else "Rejected"
        if status == "With Manager":
            if actor == "gm":
                return to
            if actor == "manager" and (action == "reject" or not gm_band):
                return to
        if status == "With GM" and actor == "gm":
            return to
        return ""
    if action == "escalate":
        if status == "With Manager" and actor == "manager" and gm_band:
            return "With GM"
        return ""
    if action == "push":
        if status == "Approved" and (actor == "gm" or (actor == "manager" and not gm_band)):
            return "Sending to SAP"
        return ""
    if action == "sap_done" or action == "sap_failed":
        if status == "Sending to SAP" and actor == "sap_sync":
            return "In SAP" if action == "sap_done" else "Approved"
        return ""
    return ""


def submit_status(days):
    """A new request's status, or "" when it may not be asked for."""
    d = int(days or 0)
    if d < 0 or d > 40:
        return ""
    return "With Manager"


def offered_terms(terms, current_code):
    """The SAP terms a rep may ask for: 40 days or fewer, not Cash Basic
    (-1, SAP's 'no term'), not the one the customer is on. Shortest first."""
    out = []
    for t in terms or []:
        code = int(t.get("code") if t.get("code") is not None else -1)
        days = int(t.get("days") or 0)
        if code == -1 or days < 0 or days > 40:
            continue
        if current_code is not None and code == int(current_code):
            continue
        out.append({"code": code, "name": t.get("name") or "", "days": days})
    return sorted(out, key=lambda t: (t["days"], t["name"]))

# ---- end rule ----


def actor_for(row_sales_person, row_team, me, managed, is_gm):
    """Who this login is to one request."""
    if is_gm:
        return "gm"
    if managed and (row_team or "") == managed:
        return "manager"
    if me and row_sales_person == me:
        return "rep"
    return "other"


def clean(v):
    s = (v or "")
    s = s.strip() if isinstance(s, str) else str(s)
    return "" if s == "null" else s


user = frappe.session.user
action = clean(frappe.form_dict.get("action")) or "list"
DT = "Manna Credit Period Request"
OPEN = ["With Manager", "With GM", "Approved", "Sending to SAP"]

is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1
))
is_bot = bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "SAP Sync Bot"}, limit=1
))
is_gm = is_sys or frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_general_manager")) == 1
mine = frappe.get_all("Sales Person", filters={"custom_user": user, "is_group": 0},
                      fields=["name", "custom_team_manager"], limit=1)
me = mine[0].name if mine else None
my_team = (mine[0].custom_team_manager or "").strip() if mine else ""
managed = (frappe.db.get_value("User", user, "custom_managed_team") or "").strip()
if not managed and me and my_team and me.strip().lower().startswith(my_team.lower()):
    managed = my_team

FIELDS = ["name", "status", "customer", "customer_name", "bp_code", "current_term", "current_term_days",
          "requested_term", "requested_term_code", "requested_days", "reason",
          "sales_person", "team", "requested_by", "requested_on",
          "escalated_by", "escalated_on", "manager_note",
          "decided_by", "decided_on", "approver_role", "decision_note",
          "push_requested_by", "push_requested_on", "sap_company", "sap_pushed_on",
          "sap_previous_term", "sap_error"]

# SAP's terms, as the credit sync last copied them. [] until it has run once.
terms = []
try:
    raw = frappe.db.get_single_value("SAP Sync Control", "payment_terms_json")
    terms = json.loads(raw) if raw else []
except Exception:
    terms = []


def load(name):
    if not name or not frappe.db.exists("Manna Credit Period Request", name):
        frappe.throw("Request not found.")
    return frappe.get_doc("Manna Credit Period Request", name)


if action == "list":
    filters = {}
    customer = clean(frappe.form_dict.get("customer"))
    if customer:
        filters["customer"] = customer
    if is_gm:
        pass
    elif managed:
        filters["team"] = managed
    elif me:
        filters["sales_person"] = me
    else:
        frappe.throw("Only a rep, a manager or the GM can see credit-period requests.")
    rows = frappe.get_all(DT, filters=filters, fields=FIELDS, order_by="creation desc", limit_page_length=500)
    for r in rows:
        for k in ("requested_on", "escalated_on", "decided_on", "push_requested_on", "sap_pushed_on"):
            r[k] = str(r[k] or "")
        who = actor_for(r.sales_person, r.team, me, managed, is_gm)
        st = r.status or ""
        dd = r.requested_days or 0
        # The same test each action makes; the apps draw their buttons from these.
        r["actor"] = who
        r["can_approve"] = 1 if next_status("approve", st, dd, who) else 0
        r["can_reject"] = 1 if next_status("reject", st, dd, who) else 0
        r["can_escalate"] = 1 if next_status("escalate", st, dd, who) else 0
        r["can_push"] = 1 if next_status("push", st, dd, who) else 0
    frappe.response["message"] = rows

elif action == "terms":
    frappe.response["message"] = terms

elif action == "submit":
    if not me:
        frappe.throw("Only a rep can ask for a credit period.")
    customer = clean(frappe.form_dict.get("customer"))
    if not customer or not frappe.db.exists("Customer", customer):
        frappe.throw("That customer was not found.")
    cust = frappe.db.get_value("Customer", customer,
                               ["customer_name", "custom_bp_code", "custom_payment_terms"], as_dict=True)
    bp = (cust.custom_bp_code or "").strip()
    if not bp:
        frappe.throw("This customer has no SAP code, so SAP has no payment term to change.")
    if frappe.get_all(DT, filters={"customer": customer, "status": ["in", OPEN]}, limit=1):
        frappe.throw("This customer already has a credit-period request open. Wait for it to be decided.")
    if not terms:
        frappe.throw("SAP's payment terms have not reached ERPNext yet. Press Sync and try again.")
    current_name = (cust.custom_payment_terms or "").strip()
    current_code = None
    current_days = 0
    for t in terms:
        if (t.get("name") or "").strip() == current_name and current_name:
            current_code = t.get("code")
            current_days = int(t.get("days") or 0)
    want = frappe.utils.cint(frappe.form_dict.get("term_code"))
    term = None
    for t in terms:
        if int(t.get("code") if t.get("code") is not None else -999) == want:
            term = t
    if not term:
        frappe.throw("That payment term is not in SAP.")
    days = int(term.get("days") or 0)
    if days > 40:
        frappe.throw("A credit period over 40 days cannot be requested here. Speak to the GM.")
    if not [t for t in offered_terms(terms, current_code) if t["code"] == want]:
        frappe.throw("The customer is already on " + (term.get("name") or "that term") + ".")
    status = submit_status(days)
    if not status:
        frappe.throw("That credit period cannot be requested.")
    doc = frappe.get_doc({
        "doctype": DT,
        "status": status,
        "customer": customer,
        "customer_name": cust.customer_name,
        "bp_code": bp,
        "current_term": current_name,
        "current_term_days": current_days,
        "requested_term": term.get("name") or "",
        "requested_term_code": want,
        "requested_days": days,
        "reason": clean(frappe.form_dict.get("reason")),
        "sales_person": me,
        "team": my_team or None,
        "requested_by": user,
        "requested_on": frappe.utils.now(),
    })
    doc.insert(ignore_permissions=True)
    frappe.response["message"] = {"name": doc.name, "status": doc.status}

elif action in ("decide", "escalate", "push"):
    doc = load(clean(frappe.form_dict.get("name")))
    who = actor_for(doc.sales_person, doc.team, me, managed, is_gm)
    note = clean(frappe.form_dict.get("note"))
    if action == "decide":
        decision = clean(frappe.form_dict.get("decision"))
        if decision not in ("Approve", "Reject"):
            frappe.throw("Choose Approve or Reject.")
        step = "approve" if decision == "Approve" else "reject"
        if step == "reject" and not note:
            frappe.throw("Say why it is rejected.")
    else:
        step = action
    to = next_status(step, doc.status or "", doc.requested_days or 0, who)
    if not to:
        if step == "approve" and doc.status == "With Manager" and who == "manager":
            frappe.throw("Over 30 days needs the GM. Escalate it instead.", frappe.PermissionError)
        if step == "push" and doc.status == "Approved" and who == "manager":
            frappe.throw("Over 30 days is pushed to SAP by the GM.", frappe.PermissionError)
        frappe.throw("You cannot " + step + " this request now (it is " + (doc.status or "unknown") + ").",
                     frappe.PermissionError)
    now = frappe.utils.now()
    if step == "escalate":
        doc.escalated_by = user
        doc.escalated_on = now
        doc.manager_note = note
    elif step in ("approve", "reject"):
        doc.decided_by = user
        doc.decided_on = now
        doc.approver_role = who
        doc.decision_note = note
    else:
        doc.push_requested_by = user
        doc.push_requested_on = now
        doc.sap_error = ""
    doc.status = to
    doc.save(ignore_permissions=True)
    if step == "push":
        # The credit sync's flag: the watcher on the office server starts the
        # sync, which pushes this before it reads the customers. The request
        # stands whether or not the flag lands, so a failure is logged.
        try:
            ctl = frappe.get_doc("SAP Sync Control")
            ctl.sync_requested = 1
            ctl.sync_requested_by = user
            ctl.sync_requested_at = frappe.utils.now()
            ctl.save(ignore_permissions=True)
        except Exception:
            frappe.log_error(title="manna_credit_period_request: could not ask for the credit sync")
    frappe.response["message"] = {"name": doc.name, "status": doc.status}

elif action == "sap_result":
    if not (is_bot or is_sys):
        frappe.throw("Only the SAP credit sync reports a push.", frappe.PermissionError)
    doc = load(clean(frappe.form_dict.get("name")))
    ok = frappe.utils.cint(frappe.form_dict.get("ok")) == 1
    to = next_status("sap_done" if ok else "sap_failed", doc.status or "", doc.requested_days or 0, "sap_sync")
    if not to:
        frappe.throw("This request is not waiting for SAP (it is " + (doc.status or "unknown") + ").")
    doc.status = to
    if ok:
        doc.sap_pushed_on = frappe.utils.now()
        doc.sap_error = ""
        doc.sap_previous_term = clean(frappe.form_dict.get("previous_term"))
        doc.sap_company = clean(frappe.form_dict.get("company"))
    else:
        doc.sap_error = clean(frappe.form_dict.get("error")) or "SAP refused the change."
    doc.save(ignore_permissions=True)
    frappe.response["message"] = {"name": doc.name, "status": doc.status}

else:
    frappe.throw("Unknown action.")
