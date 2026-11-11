# Frappe Server Script
#   Name          : manna_item_request
#   Script Type   : API
#   API Method    : manna_item_request
#   Args (POST)   : action = list | submit | decide
#     list   : status (optional)
#     submit : product_line, item_type, pattern, size, customer, quantity,
#              unit, note, photo (a file_url already uploaded)
#     decide : name, status = Done | Rejected, item_code (Done), reply
#
# Item requests (10 Nov 2026): a rep asks for a product that is not in the
# catalogue; the accountant creates it in SAP and answers with its code, or
# rejects it with a reason. The doctype is System Manager's only, so this is
# the way in, and it decides who may do what:
#   - an accountant (User.custom_is_accountant) or System Manager: lists every
#     request and decides them;
#   - HR (User.custom_is_hr_manager) and HR's assistant
#     (User.custom_is_hr_assistant, 11 Nov 2026): list every request, decide
#     none (10 Nov 2026);
#   - anyone with a Sales Person: submits, and lists their own.
# Done is the accountant's word that the item exists in SAP; it does not
# create anything. Item codes reach ERPNext from SAP.
#
# safe_exec: no frappe.get_roles / parse_json / hasattr, and no augmented
# assignment to an item (d["k"] += 1).

user = frappe.session.user
action = (frappe.form_dict.get("action") or "list").strip()

is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1
))
is_acct = is_sys or frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_accountant")) == 1
is_hr = (frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_hr_manager")) == 1
         or frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_hr_assistant")) == 1)
mine = frappe.get_all("Sales Person", filters={"custom_user": user, "is_group": 0}, pluck="name", limit=1)
me = mine[0] if mine else None

FIELDS = ["name", "status", "product_line", "item_type", "pattern", "size", "customer", "quantity", "unit",
          "note", "photo", "sales_person", "requested_by", "requested_on", "item_code", "reply",
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
    if not (is_acct or is_hr):
        if not me:
            frappe.throw("Only a rep, the accountant or HR can see item requests.")
        filters["sales_person"] = me
    rows = frappe.get_all("Manna Item Request", filters=filters, fields=FIELDS,
                          order_by="creation desc", limit_page_length=500)
    names = {}
    for r in rows:
        if r.customer and r.customer not in names:
            names[r.customer] = frappe.db.get_value("Customer", r.customer, "customer_name") or r.customer
        r["customer_name"] = names.get(r.customer, "") if r.customer else ""
        for k in ("requested_on", "decided_on"):
            r[k] = str(r[k] or "")
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
        "status": "Pending",
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

elif action == "decide":
    if not is_acct:
        frappe.throw("Only the accountant can answer item requests.", frappe.PermissionError)
    name = clean(frappe.form_dict.get("name"))
    if not name or not frappe.db.exists("Manna Item Request", name):
        frappe.throw("Request not found.")
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
