# Frappe Server Script
#   Name          : manna_item_request
#   Script Type   : API
#   API Method    : manna_item_request
#   Args (POST)   : action = list | submit | approve | decide
#     list    : status (optional)
#     submit  : product_line, item_type, pattern, size, customer, quantity,
#               unit, note, photo (a file_url already uploaded)
#     approve : name, decision = Approve | Reject, note (needed to Reject)
#     decide  : name, status = Done | Rejected, item_code (Done), reply
#
# Item requests (10 Nov 2026): a rep asks for a product that is not in the
# catalogue; the accountant creates it in SAP and answers with its code, or
# rejects it with a reason.
#
# The manager first (12 Nov 2026, the user): a new request is "Pending
# Manager" and goes to the rep's team manager, who approves it on to the
# accountant ("Pending") or rejects it with a reason. A rep with no team waits
# for the GM. Requests already "Pending" on that day stay with the accountant.
# shared/fixtures/item_request_flow.json pins the stages for both apps.
#
# The doctype is System Manager's only, so this is the way in, and it decides
# who may do what:
#   - accounts staff (User.custom_is_accounts_staff) or System Manager: lists
#     every request and answers the ones the manager has approved. Moved here
#     from the accountant (User.custom_is_accountant) on 12 Nov 2026, the
#     user: the accounts staff make the item in SAP, and the accountant no
#     longer sees item requests at all;
#   - the GM (User.custom_is_general_manager): lists every request and
#     approves any waiting for a manager;
#   - a team manager (User.custom_managed_team, or a Sales Person named after
#     its own team token, as pick_lists.py reads it): lists the team's
#     requests and approves them;
#   - HR (User.custom_is_hr_manager): lists every request, decides none
#     (10 Nov 2026);
#   - anyone with a Sales Person: submits, and lists their own.
# Done is the accounts staff's word that the item exists in SAP; it does not
# create anything. Item codes reach ERPNext from SAP. ("With accountant", the
# stage's name in both apps, means with accounts.)
#
# safe_exec: no frappe.get_roles / parse_json / hasattr, and no augmented
# assignment to an item (d["k"] += 1).

user = frappe.session.user
action = (frappe.form_dict.get("action") or "list").strip()

is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1
))
# Who answers: the accounts staff (12 Nov 2026; the accountant until then).
is_acct = is_sys or frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_accounts_staff")) == 1
is_hr = frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_hr_manager")) == 1
is_gm = is_sys or frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_general_manager")) == 1
mine = frappe.get_all("Sales Person", filters={"custom_user": user, "is_group": 0},
                      fields=["name", "custom_team_manager"], limit=1)
me = mine[0].name if mine else None
my_team = (mine[0].custom_team_manager or "").strip() if mine else ""
managed = (frappe.db.get_value("User", user, "custom_managed_team") or "").strip()
if not managed and me and my_team and me.strip().lower().startswith(my_team.lower()):
    managed = my_team

FIELDS = ["name", "status", "product_line", "item_type", "pattern", "size", "customer", "quantity", "unit",
          "note", "photo", "sales_person", "team", "requested_by", "requested_on",
          "approved_by", "approved_on", "manager_note", "item_code", "reply",
          "decided_by", "decided_on"]
LINES = ["Black Pearl", "Platinum", "Silver", "Polygold", "Diamond", "Hot", "Bonding Gum", "Solution", "Other"]
TYPES = ["Precured", "Hot", "Bonding Gum", "Solution", "Other"]
UNITS = ["Rolls", "Kg", "Nos", "Litre"]


def clean(v):
    s = (v or "")
    s = s.strip() if isinstance(s, str) else str(s)
    return "" if s == "null" else s


if action == "list":
    filters = {}
    status = clean(frappe.form_dict.get("status"))
    if status:
        filters["status"] = status
    if is_acct or is_hr or is_gm:
        pass
    elif managed:
        filters["team"] = managed
    elif me:
        filters["sales_person"] = me
    else:
        frappe.throw("Only a rep, a manager, accounts or HR can see item requests.")
    rows = frappe.get_all("Manna Item Request", filters=filters, fields=FIELDS,
                          order_by="creation desc", limit_page_length=500)
    names = {}
    for r in rows:
        if r.customer and r.customer not in names:
            names[r.customer] = frappe.db.get_value("Customer", r.customer, "customer_name") or r.customer
        r["customer_name"] = names.get(r.customer, "") if r.customer else ""
        for k in ("requested_on", "approved_on", "decided_on"):
            r[k] = str(r[k] or "")
        # Whether this user may approve it now - the same test the approve action makes.
        r["can_approve"] = 1 if (r.status == "Pending Manager"
                                 and (is_gm or (managed and (r.team or "") == managed))) else 0
    frappe.response["message"] = rows

elif action == "submit":
    if not me:
        frappe.throw("Only a rep can ask for a new item.")
    line = clean(frappe.form_dict.get("product_line"))
    typ = clean(frappe.form_dict.get("item_type"))
    if line not in LINES:
        frappe.throw("Choose the product line.")
    if typ not in TYPES:
        frappe.throw("Choose the type.")
    pattern = clean(frappe.form_dict.get("pattern"))
    size = clean(frappe.form_dict.get("size"))
    note = clean(frappe.form_dict.get("note"))
    if not (pattern or size or note):
        frappe.throw("Say what is needed: a pattern, a size or a note.")
    customer = clean(frappe.form_dict.get("customer"))
    if customer and not frappe.db.exists("Customer", customer):
        frappe.throw("That customer was not found.")
    unit = clean(frappe.form_dict.get("unit"))
    doc = frappe.get_doc({
        "doctype": "Manna Item Request",
        "status": "Pending Manager",
        "team": my_team or None,
        "product_line": line,
        "item_type": typ,
        "pattern": pattern,
        "size": size,
        "customer": customer or None,
        "quantity": frappe.utils.flt(frappe.form_dict.get("quantity")),
        "unit": unit if unit in UNITS else None,
        "note": note,
        "photo": clean(frappe.form_dict.get("photo")) or None,
        "sales_person": me,
        "requested_by": user,
        "requested_on": frappe.utils.now(),
    })
    doc.insert(ignore_permissions=True)
    frappe.response["message"] = {"name": doc.name}

elif action == "approve":
    name = clean(frappe.form_dict.get("name"))
    if not name or not frappe.db.exists("Manna Item Request", name):
        frappe.throw("Request not found.")
    doc = frappe.get_doc("Manna Item Request", name)
    if doc.status != "Pending Manager":
        frappe.throw("This request is no longer waiting for a manager.")
    if not (is_gm or (managed and (doc.team or "") == managed)):
        frappe.throw("Only the rep's manager or the GM can approve this request.", frappe.PermissionError)
    decision = clean(frappe.form_dict.get("decision"))
    note = clean(frappe.form_dict.get("note"))
    if decision not in ("Approve", "Reject"):
        frappe.throw("Choose Approve or Reject.")
    if decision == "Reject" and not note:
        frappe.throw("Say why it is rejected.")
    doc.approved_by = user
    doc.approved_on = frappe.utils.now()
    doc.manager_note = note
    if decision == "Approve":
        doc.status = "Pending"
    else:
        # The manager's rejection is the answer the rep sees; accounts never get it.
        doc.status = "Rejected"
        doc.reply = note
        doc.decided_by = user
        doc.decided_on = frappe.utils.now()
    doc.save(ignore_permissions=True)
    frappe.response["message"] = {"name": doc.name, "status": doc.status}

elif action == "decide":
    if not is_acct:
        frappe.throw("Only accounts staff can answer item requests.", frappe.PermissionError)
    name = clean(frappe.form_dict.get("name"))
    if not name or not frappe.db.exists("Manna Item Request", name):
        frappe.throw("Request not found.")
    if frappe.db.get_value("Manna Item Request", name, "status") == "Pending Manager":
        frappe.throw("The manager has not approved this request yet.")
    status = clean(frappe.form_dict.get("status"))
    if status not in ("Done", "Rejected"):
        frappe.throw("Choose Done or Rejected.")
    code = clean(frappe.form_dict.get("item_code"))
    reply = clean(frappe.form_dict.get("reply"))
    if status == "Done" and not code:
        frappe.throw("Enter the item code created in SAP.")
    if status == "Rejected" and not reply:
        frappe.throw("Say why it is rejected.")
    doc = frappe.get_doc("Manna Item Request", name)
    doc.status = status
    doc.item_code = code if status == "Done" else ""
    doc.reply = reply
    doc.decided_by = user
    doc.decided_on = frappe.utils.now()
    doc.save(ignore_permissions=True)
    frappe.response["message"] = {"name": doc.name, "status": doc.status}

else:
    frappe.throw("Unknown action.")
