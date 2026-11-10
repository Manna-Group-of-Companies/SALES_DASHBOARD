# Frappe Server Script
#   Name          : manna_sap_invoice_sync
#   Script Type   : API
#   API Method    : manna_sap_invoice_sync
#   Args (POST)   : company = "Manna Treads",
#                   invoices = JSON [{doc_entry, doc_num, card_code, posting_date,
#                                     due_date, total, paid, status, cancelled}]
#
# SAP's A/R invoices, pushed by B1if (sap-b1if/step5-invoice) the moment an
# invoice or an incoming payment is added, changed or cancelled in SAP
# (9 Nov 2026). Writes the same SAP Invoice rows the credit sync writes, in
# the same shape, so the two can run side by side: whichever writes last
# writes SAP's current figure.
#
#   - key: "<company>-<DocEntry>" (DocNum restarts every financial year);
#   - customer: the Customer whose custom_bp_code is the invoice's CardCode.
#     No such customer: skipped and reported, never guessed;
#   - a cancelled invoice: its row is deleted, as the credit sync does;
#   - balance = total - paid, never below zero.
#
# Only System Manager or SAP Sync Bot may call it. safe_exec: no
# frappe.get_roles / parse_json / hasattr; roles from Has Role, JSON with
# json.loads; and no augmented assignment to an item (d["k"] += 1 is a
# SyntaxError there), so the counts are plain variables.

user = frappe.session.user
roles = [r.role for r in frappe.get_all("Has Role", filters={"parent": user, "parenttype": "User"}, fields=["role"])]
if user != "Administrator" and "System Manager" not in roles and "SAP Sync Bot" not in roles:
    frappe.throw("Not allowed.", frappe.PermissionError)

company = (frappe.form_dict.get("company") or "").strip()
if not company:
    frappe.throw("company is required.")
raw = frappe.form_dict.get("invoices") or "[]"
invoices = json.loads(raw) if isinstance(raw, str) else raw
now = frappe.utils.now()

created = 0
updated = 0
deleted = 0
skipped = []
customers = {}

for inv in invoices:
    entry = frappe.utils.cint(inv.get("doc_entry"))
    if entry <= 0:
        skipped.append({"doc_entry": inv.get("doc_entry"), "why": "no DocEntry"})
        continue
    key = "%s-%s" % (company, entry)

    if str(inv.get("cancelled") or "").upper() in ("Y", "C", "1", "TRUE"):
        if frappe.db.exists("SAP Invoice", key):
            frappe.delete_doc("SAP Invoice", key, ignore_permissions=True, force=True)
            deleted = deleted + 1
        continue

    card = (inv.get("card_code") or "").strip()
    if card not in customers:
        found = frappe.get_all("Customer", filters={"custom_bp_code": card}, pluck="name", limit=2)
        customers[card] = found[0] if len(found) == 1 else None
    customer = customers[card]
    if not customer:
        skipped.append({"doc_entry": entry, "why": "no single Customer with custom_bp_code %s" % card})
        continue

    total = frappe.utils.flt(inv.get("total"), 2)
    paid = frappe.utils.flt(inv.get("paid"), 2)
    status = "Closed" if str(inv.get("status") or "").upper() in ("C", "CLOSED") else "Open"
    values = {
        "customer": customer,
        "company": company,
        "invoice_no": str(inv.get("doc_num") or ""),
        "sap_doc_entry": entry,
        "sap_card_code": card,
        "posting_date": inv.get("posting_date") or None,
        "due_date": inv.get("due_date") or None,
        "status": status,
        "total": total,
        "paid": paid,
        "balance": max(total - paid, 0),
        "sap_last_synced": now,
    }

    if frappe.db.exists("SAP Invoice", key):
        doc = frappe.get_doc("SAP Invoice", key)
        doc.update(values)
        doc.save(ignore_permissions=True)
        updated = updated + 1
    else:
        values["doctype"] = "SAP Invoice"
        values["sap_key"] = key
        frappe.get_doc(values).insert(ignore_permissions=True)
        created = created + 1

frappe.response["message"] = {"created": created, "updated": updated, "deleted": deleted, "skipped": skipped}
