# Frappe Server Script
#   Name          : manna_payment_commitment_order
#   Script Type   : DocType Event
#   Reference Doc : Sales Order
#   DocType Event : Before Save
#
# The backstop of the 10-day payment commitment ladder (17 Nov 2026). Both
# apps check it before they write; this is what a browser console cannot talk
# around.
#
#   - A new order only the GM may decide goes straight to the GM ('Pending GM
#     Approval'), bypassing the Manager, and the GM and the team's Manager are
#     told: a customer with a missed commitment not yet cleared, an order over
#     the limit beyond the team Manager's authority, or that Manager's cap of
#     commitments reached (route 'gm').
#   - An approval ('PO Approved - Ready for SAP' by the Manager, or 'Pending
#     Final Approval' by the GM) of an order that needs a commitment is refused
#     without one; the commitment entered with it (manna_payment_commitment,
#     action approve, status Pending) becomes Running here. The Manager's push
#     after the GM's approval needs nothing more: the GM's commitment stands.
#   - The Manager may not approve an order whose route is the GM.
#   - A rejection cancels the order's commitment.
#
# System Manager (the integration user, the SAP syncs) and Administrator are
# let through, and a lead order converted already approved is left alone: a
# lead has no SAP credit. shared/fixtures/payment_commitment.json pins the
# rule; app/server/test_payment_commitment.py runs this copy of it.

# ---- rule: shared/fixtures/payment_commitment.json ----

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

# ---- end rule ----


DT = "Manna Payment Commitment"
XS = "Manna Credit Extension Settings"
APPROVED = "PO Approved - Ready for SAP"
FINAL = "Pending Final Approval"
GM_WAIT = "Pending GM Approval"
WAITING = ["Pending Approval", "PO Uploaded - Pending Approval", "Pending Rate Approval"]

user = frappe.session.user
is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1))
is_gm = frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_general_manager")) == 1
before = None if doc.is_new() else doc.get_doc_before_save()
old = ((before.get("custom_po_status") if before else "") or "").strip()
new = (doc.get("custom_po_status") or "").strip()
now = frappe.utils.now()
team = ""
if doc.get("custom_sales_person"):
    team = (frappe.db.get_value("Sales Person", doc.custom_sales_person, "custom_team_manager") or "").strip()

if doc.docstatus < 2 and doc.customer and new != old:
    hist = frappe.get_all(DT, filters={"customer": doc.customer, "status": ["not in", ["Pending", "Cancelled"]]},
                          fields=["name", "status", "cleared_on", "approver_role", "approved_on"], limit_page_length=0)
    lock = gm_lock_of(hist)

    # 1. Raised (or sent back for approval) when only the GM may decide it: the
    #    customer is with the GM, or the order is over the limit beyond the
    #    team Manager's authority, or that Manager's cap of commitments is
    #    reached. It goes straight to the GM (the user, 17 Nov 2026: "go
    #    directly to GM, but show the order in Manager, and Note for GM in
    #    Manager"); the Manager still sees it and may add a note to its thread.
    if new in WAITING and not is_sys and not is_gm:
        mgrs = []
        if team:
            mgrs = [u.name for u in frappe.get_all("User", filters={"custom_managed_team": team, "enabled": 1}, fields=["name"])]
        why = ""
        if lock:
            why = "missed a payment commitment that is not cleared"
        else:
            c = frappe.db.get_value("Customer", doc.customer, ["custom_credit_limit", "custom_outstanding_balance",
                                    "custom_outstanding_0_30", "custom_outstanding_30_60", "custom_outstanding_60_90",
                                    "custom_outstanding_90_plus", "custom_overdue_past_terms", "custom_overdue_days"],
                                    as_dict=True) or {}
            n = needs_of(c, doc.total)
            if n["needs"]:
                # The team Manager's authority, as the route action reads it.
                pct = frappe.db.get_single_value(XS, "manager_authority_percent")
                pct = 10.0 if pct is None or str(pct) == "" else frappe.utils.flt(pct)
                authority = round(frappe.utils.flt(doc.total) * pct / 100, 2)
                for r in frappe.get_all("Manna Credit Extension Authority", filters={"parenttype": XS, "parent": XS},
                                        fields=["manager", "max_amount"], limit_page_length=0):
                    if mgrs and r.manager == mgrs[0]:
                        authority = frappe.utils.flt(r.max_amount)
                cap_count = frappe.utils.cint(frappe.db.get_single_value(XS, "manager_cap_count"))
                cap_days = frappe.utils.cint(frappe.db.get_single_value(XS, "manager_cap_days")) or 90
                used = 0
                for h in hist:
                    if h.approver_role == "manager" and h.approved_on and frappe.utils.date_diff(frappe.utils.today(), h.approved_on) < cap_days:
                        used = used + 1
                if route_of(n["needs"], n["over_limit"], n["excess"], authority, False, used >= cap_count) == "gm":
                    if n["over_limit"] and not (authority > 0 and n["excess"] <= authority):
                        why = ("is over the credit limit by Rs " + str(int(round(n["excess"])))
                               + ", beyond the Manager's authority of Rs " + str(int(round(authority))))
                    else:
                        why = "has had the Manager's limit of payment commitments"
        if why:
            doc.custom_po_status = GM_WAIT
            who = doc.customer_name or doc.customer
            gms = [u.name for u in frappe.get_all("User", filters={"custom_is_general_manager": 1, "enabled": 1}, fields=["name"])]
            for u in mgrs + gms:
                frappe.get_doc({"doctype": "Notification Log", "for_user": u, "type": "Alert",
                                "subject": "Sent to GM: " + who + " " + why + (" (" + doc.name + ")" if doc.name else ""),
                                "document_type": "Sales Order", "document_name": doc.name or None}).insert(ignore_permissions=True)

    # 2. An approval.
    elif new in (APPROVED, FINAL) and not doc.is_new() and not is_sys and not (new == APPROVED and old == FINAL):
        c = frappe.db.get_value("Customer", doc.customer, ["custom_credit_limit", "custom_outstanding_balance",
                                "custom_outstanding_0_30", "custom_outstanding_30_60", "custom_outstanding_60_90",
                                "custom_outstanding_90_plus", "custom_overdue_past_terms", "custom_overdue_days"],
                                as_dict=True) or {}
        n = needs_of(c, doc.total)
        role = "gm" if is_gm else "manager"
        # By default 10% of the order (the user, 17 Nov 2026); a Manager's own
        # rupee figure wins.
        pct = frappe.db.get_single_value(XS, "manager_authority_percent")
        pct = 10.0 if pct is None or str(pct) == "" else frappe.utils.flt(pct)
        authority = round(frappe.utils.flt(doc.total) * pct / 100, 2)
        for r in frappe.get_all("Manna Credit Extension Authority", filters={"parenttype": XS, "parent": XS},
                                fields=["manager", "max_amount"], limit_page_length=0):
            if r.manager == user:
                authority = frappe.utils.flt(r.max_amount)
        cap_count = frappe.utils.cint(frappe.db.get_single_value(XS, "manager_cap_count"))
        cap_days = frappe.utils.cint(frappe.db.get_single_value(XS, "manager_cap_days")) or 90
        used = 0
        for h in hist:
            if h.approver_role == "manager" and h.approved_on and frappe.utils.date_diff(frappe.utils.today(), h.approved_on) < cap_days:
                used = used + 1
        route = route_of(n["needs"], n["over_limit"], n["excess"], authority, lock, used >= cap_count)
        if role == "manager" and route == "gm":
            frappe.throw("This order needs the GM's decision (a missed commitment not cleared, over the limit beyond "
                         + "your authority, or your limit of commitments for this customer). Send it to the GM.")
        if route != "manager" or (role == "gm" and (n["needs"] or lock)):
            pend = frappe.get_all(DT, filters={"sales_order": doc.name, "status": "Pending", "approved_by": user},
                                  fields=["name"], order_by="creation desc", limit=1)
            if not pend:
                frappe.throw("This order needs a payment commitment of up to 10 days: enter its date and remarks with "
                             + "the approval.")
            pc = frappe.get_doc(DT, pend[0].name)
            pc.status = "Running"
            pc.approved_on = now
            pc.approver_role = role
            pc.order_amount = doc.total
            pc.append("log", {"action": "Approved by the " + ("GM" if role == "gm" else "Manager") + " with the order",
                              "actor_role": role, "by_user": user, "at": now, "remarks": pc.remarks})
            pc.save(ignore_permissions=True)

    # 3. A rejection (or the GM withdrawing an approval) ends the order's commitment.
    elif new == "Rejected":
        for r in frappe.get_all(DT, filters={"sales_order": doc.name, "status": ["in", ["Pending", "Running", "Unchecked"]]},
                                pluck="name"):
            pc = frappe.get_doc(DT, r)
            pc.status = "Cancelled"
            pc.append("log", {"action": "Cancelled: the order was rejected", "actor_role": "gm" if is_gm else "manager",
                              "by_user": user, "at": now, "remarks": ""})
            pc.save(ignore_permissions=True)
