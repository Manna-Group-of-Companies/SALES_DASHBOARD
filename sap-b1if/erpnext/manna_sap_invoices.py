# Frappe Server Script
#   Name          : manna_sap_invoices
#   Script Type   : API
#   API Method    : manna_sap_invoices
#   Body (POST)   : JSON {"invoices": [ {entry, num, code, date, due, total, paid, status}, ... ], "dry_run": 0|1}
#
# The SAP Invoice mirror (the credit history under Team Targets), a port of the
# mirror step in sap-credit-sync/Sync-SapCreditLimits.ps1, rule for rule. B1iF's
# invoices package (Manna Treads, a timer) posts every uncancelled A/R invoice of
# the current financial year plus every one still open; this makes the mirror
# equal to that for customers ERPNext holds by custom_bp_code:
#   - a row is '<company>-<DocEntry>' (DocNum restarts every financial year);
#   - status is SAP's document status (O -> Open, C -> Closed), never worked out
#     from the balance; balance = total - paid, from the rounded figures;
#   - only changed fields are written; an unchanged row is not touched; a
#     changed row is SAVED AS A DOCUMENT, so a Server Script on SAP Invoice
#     (After Save - the "payment received" message) hears it;
#   - a row whose invoice is no longer in the batch is deleted (SAP cancelled it,
#     or it closed and is older than the year) - but a batch that would delete
#     more than half of a mirror of 20 or more rows deletes nothing: an empty or
#     half-read batch looks exactly like that. An empty batch changes nothing.
#   - at most MAX_CREATE new rows a call, the rest on the timer's next runs.
#
# Callers: System Manager or the "SAP Sync Bot" role.

COMPANY = "Manna Treads"
MAX_CREATE = 400
EPS = 0.005
COMPARED = ["customer", "invoice_no", "sap_card_code", "posting_date", "due_date", "total", "paid", "balance", "status"]
MONEY = ["total", "paid", "balance"]
STATUS = {"O": "Open", "C": "Closed"}


def squash(s):
	return " ".join(str(s or "").split())


def num(v):
	try:
		return float(v or 0)
	except Exception:
		return 0.0


def same(field, a, b):
	if field in MONEY:
		return abs(num(a) - num(b)) < EPS
	if field.endswith("_date"):
		return str(a or "")[:10] == str(b or "")[:10]
	return squash(a) == squash(b)


def plan(rows, customers, existing):
	"""Pure. customers: lowercased SAP code -> Customer name; existing: sap_key -> stored row.
	Returns {"create", "update", "delete", "deletes_held", "no_customer", "held", "refused"}."""
	wanted = {}
	no_customer = 0
	for r in rows:
		entry = int(num(r.get("entry")))
		if entry <= 0:
			continue
		key = "%s-%d" % (COMPANY, entry)
		if key in wanted:
			continue
		code = squash(r.get("code"))
		cust = customers.get(code.lower())
		if not cust:
			no_customer = no_customer + 1
			continue
		total = round(num(r.get("total")), 2)
		paid = round(num(r.get("paid")), 2)
		st = squash(r.get("status"))
		wanted[key] = {"sap_key": key, "company": COMPANY, "sap_doc_entry": entry, "customer": cust, "invoice_no": squash(r.get("num")),
			"sap_card_code": code, "posting_date": str(r.get("date") or "")[:10], "due_date": str(r.get("due") or "")[:10],
			"total": total, "paid": paid, "balance": round(total - paid, 2), "status": STATUS.get(st.upper(), st)}
	if not rows:
		return {"create": [], "update": [], "delete": [], "deletes_held": 0, "no_customer": 0, "held": 0,
			"refused": "the batch holds no rows - nothing changed (an empty read looks like this)"}
	create = []
	update = []
	for key in sorted(wanted):
		have = existing.get(key)
		if have is None:
			create.append(wanted[key])
		else:
			fields = {}
			for f in COMPARED:
				if not same(f, have.get(f), wanted[key][f]):
					fields[f] = wanted[key][f]
			if fields:
				update.append({"name": key, "fields": fields})
	delete = sorted([k for k in existing if k not in wanted])
	deletes_held = 0
	if len(existing) >= 20 and len(delete) * 2 > len(existing):
		deletes_held = len(delete)
		delete = []
	return {"create": create[:MAX_CREATE], "update": update, "delete": delete, "deletes_held": deletes_held,
		"no_customer": no_customer, "held": max(0, len(create) - MAX_CREATE), "refused": ""}


def run():
	user = frappe.session.user
	allowed = user == "Administrator" or bool(frappe.get_all("Has Role",
		filters={"parent": user, "parenttype": "User", "role": ["in", ["System Manager", "SAP Sync Bot"]]}, limit=1))
	if not allowed:
		frappe.throw("Only the SAP sync user may post invoices.")
	body = frappe.form_dict
	rows = body.get("invoices")
	if isinstance(rows, str):
		rows = frappe.parse_json(rows)
	if not isinstance(rows, list):
		frappe.throw("invoices must be a list.")
	dry = frappe.utils.cint(body.get("dry_run")) == 1
	customers = {}
	for c in frappe.get_all("Customer", filters={"custom_bp_code": ["is", "set"]}, fields=["name", "custom_bp_code"], limit_page_length=0):
		customers[squash(c.custom_bp_code).lower()] = c.name
	existing = {}
	for e in frappe.get_all("SAP Invoice", filters={"company": COMPANY}, fields=["name"] + COMPARED, limit_page_length=0):
		existing[e.name] = e
	p = plan(rows, customers, existing)
	done = {"created": 0, "updated": 0, "deleted": 0}
	errors = []
	if not dry and not p["refused"]:
		stamp = frappe.utils.now()
		for rec in p["create"]:
			try:
				frappe.get_doc(dict(rec, doctype="SAP Invoice", sap_last_synced=stamp)).insert(ignore_permissions=True)
				done["created"] = done["created"] + 1
			except Exception as e:
				errors.append("%s: %s" % (rec["sap_key"], e))
		for u in p["update"]:
			# Saved as a document, never db.set_value (11 Nov 2026): the "payment
			# received" message is a Server Script on SAP Invoice, After Save, that
			# compares `paid` with the row before the save
			# (whatsapp/server-scripts/manna_whatsapp_payment.py), and set_value
			# raises no such event. This mirror and B1if's invoice events
			# (Z.erpinv -> manna_sap_invoice_sync) both write a payment; when this
			# one got there first by set_value, the event's save found nothing
			# changed and the customer was never told. Whichever writes first now
			# raises it, and that script's own key stops a second message.
			try:
				d = frappe.get_doc("SAP Invoice", u["name"])
				d.update(dict(u["fields"], sap_last_synced=stamp))
				d.save(ignore_permissions=True)
				done["updated"] = done["updated"] + 1
			except Exception as e:
				errors.append("%s: %s" % (u["name"], e))
		for name in p["delete"]:
			try:
				frappe.delete_doc("SAP Invoice", name, ignore_permissions=True)
				done["deleted"] = done["deleted"] + 1
			except Exception as e:
				errors.append("%s: %s" % (name, e))
	frappe.response["message"] = {"dry_run": dry, "refused": p["refused"], "rows": len(rows), "mirror_held": len(existing),
		"to_create": len(p["create"]), "to_update": len(p["update"]), "to_delete": len(p["delete"]), "deletes_held": p["deletes_held"],
		"left_for_next_run": p["held"], "no_customer": p["no_customer"], "done": done, "updates": p["update"][:30], "errors": errors[:20]}


if not frappe.flags.get("manna_test"):
	run()
