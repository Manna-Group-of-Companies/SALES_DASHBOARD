# Frappe Server Script
#   Name          : manna_sap_payments
#   Script Type   : API
#   API Method    : manna_sap_payments
#   Body (POST)   : JSON {"payments": [ {entry, num, code, date, amount, on_account,
#                   cancelled, mode, reference, remarks, invoices}, ... ], "dry_run": 0|1}
#
# Manna Treads' incoming payments, mirrored as SAP Payment rows (10 Nov 2026) so
# the apps can list what a customer paid and ERPNext can act when money arrives.
# B1iF's payments package (a timer) posts every customer payment of the current
# financial year on every run; this writes only what is new or changed.
#
# - Only customers ERPNext holds by custom_bp_code; a row is '<company>-<DocEntry>',
#   like SAP Invoice, because DocNum restarts every financial year.
# - A payment SAP cancelled is kept and marked Cancelled - the list is a history,
#   and "that receipt was cancelled" is something a trigger may want to act on.
#   Nothing is ever deleted here: a payment that leaves the batch has only aged
#   out of the financial year.
# - Rows are INSERTED AND SAVED AS DOCUMENTS (not db.set_value), so a Server
#   Script on SAP Payment - After Insert for "payment received", After Save for
#   "cancelled" - is the trigger point. (The field cannot be called is_new:
#   every document has a method of that name, and the insert calls it.) new_payment = 1 only when the payment reaches
#   ERPNext within NEW_DAYS of its posting date and is not cancelled, so the
#   first load of a year's payments does not message every customer.
# - At most MAX_CREATE new rows per call: a first load is hundreds of inserts
#   and B1iF waits a minute; the timer brings the rest on its next runs.
#
# Callers: System Manager or the "SAP Sync Bot" role.

COMPANY = "Manna Treads"
NEW_DAYS = 3
MAX_CREATE = 250
EPS = 0.005
COMPARED = ["customer", "payment_no", "sap_card_code", "posting_date", "status", "mode", "reference", "amount", "on_account", "invoices", "remarks"]
MONEY = ["amount", "on_account"]


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
	if field == "posting_date":
		return str(a or "")[:10] == str(b or "")[:10]
	return squash(a) == squash(b)


def plan(rows, customers, existing, today, age_days):
	"""Pure. customers: lowercased SAP code -> Customer name; existing: sap_key ->
	stored row; age_days(date_text) -> whole days from that date to today.
	Returns {"create": [...], "update": [ {name, fields} ], "no_customer": n, "held": n}."""
	create = []
	update = []
	no_customer = 0
	seen = set()
	for r in rows:
		entry = int(num(r.get("entry")))
		if entry <= 0:
			continue
		key = "%s-%d" % (COMPANY, entry)
		if key in seen:
			continue
		seen.add(key)
		code = squash(r.get("code"))
		cust = customers.get(code.lower())
		if not cust:
			no_customer = no_customer + 1
			continue
		cancelled = str(r.get("cancelled") or "").upper() == "Y"
		rec = {"customer": cust, "payment_no": squash(r.get("num")), "sap_card_code": code, "posting_date": str(r.get("date") or "")[:10],
			"status": "Cancelled" if cancelled else "Posted", "mode": squash(r.get("mode")), "reference": squash(r.get("reference"))[:140],
			"amount": round(num(r.get("amount")), 2), "on_account": round(num(r.get("on_account")), 2),
			"invoices": squash(r.get("invoices")), "remarks": squash(r.get("remarks"))[:140]}
		have = existing.get(key)
		if have is None:
			fresh = (not cancelled) and rec["posting_date"] != "" and 0 <= age_days(rec["posting_date"]) <= NEW_DAYS
			create.append(dict(rec, sap_key=key, company=COMPANY, sap_doc_entry=entry, new_payment=1 if fresh else 0))
		else:
			fields = {}
			for f in COMPARED:
				if not same(f, have.get(f), rec[f]):
					fields[f] = rec[f]
			if fields:
				update.append({"name": key, "fields": fields})
	held = max(0, len(create) - MAX_CREATE)
	return {"create": create[:MAX_CREATE], "update": update, "no_customer": no_customer, "held": held}


def run():
	user = frappe.session.user
	allowed = user == "Administrator" or bool(frappe.get_all("Has Role",
		filters={"parent": user, "parenttype": "User", "role": ["in", ["System Manager", "SAP Sync Bot"]]}, limit=1))
	if not allowed:
		frappe.throw("Only the SAP sync user may post payments.")
	body = frappe.form_dict
	rows = body.get("payments")
	if isinstance(rows, str):
		rows = frappe.parse_json(rows)
	if not isinstance(rows, list):
		frappe.throw("payments must be a list.")
	dry = frappe.utils.cint(body.get("dry_run")) == 1
	customers = {}
	for c in frappe.get_all("Customer", filters={"custom_bp_code": ["is", "set"]}, fields=["name", "custom_bp_code"], limit_page_length=0):
		customers[squash(c.custom_bp_code).lower()] = c.name
	existing = {}
	for e in frappe.get_all("SAP Payment", filters={"company": COMPANY}, fields=["name"] + COMPARED, limit_page_length=0):
		existing[e.name] = e
	today = frappe.utils.nowdate()
	p = plan(rows, customers, existing, today, lambda d: frappe.utils.date_diff(today, d))
	created = 0
	updated = 0
	errors = []
	if not dry:
		stamp = frappe.utils.now()
		for rec in p["create"]:
			try:
				frappe.get_doc(dict(rec, doctype="SAP Payment", sap_last_synced=stamp)).insert(ignore_permissions=True)
				created = created + 1
			except Exception as e:
				errors.append("%s: %s" % (rec["sap_key"], e))
		for u in p["update"]:
			try:
				d = frappe.get_doc("SAP Payment", u["name"])
				d.update(u["fields"])
				d.sap_last_synced = stamp
				d.save(ignore_permissions=True)
				updated = updated + 1
			except Exception as e:
				errors.append("%s: %s" % (u["name"], e))
	frappe.response["message"] = {"dry_run": dry, "rows": len(rows), "to_create": len(p["create"]), "to_update": len(p["update"]),
		"created": created, "updated": updated, "left_for_next_run": p["held"], "no_customer": p["no_customer"],
		"new_payments": [c["sap_key"] for c in p["create"] if c["new_payment"]][:50], "updates": p["update"][:50], "errors": errors[:20]}


if not frappe.flags.get("manna_test"):
	run()
