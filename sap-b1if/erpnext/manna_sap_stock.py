# Frappe Server Script
#   Name          : manna_sap_stock
#   Script Type   : API
#   API Method    : manna_sap_stock
#   Body (POST)   : JSON {"stock": [ {code, qty}, ... ], "dry_run": 0|1, "force": 0|1}
#
# B1iF's stock package (Hi-Tech, a timer) posts Hi-Tech's whole saleable stock
# here on every run: one row per item, qty = available to promise (on hand less
# what SAP has committed to open sales orders) in the sales warehouse.
#
# It lands where Sync-HitechStockToTreads.ps1 puts it, so the phone and the
# dashboard read it unchanged: Bin.actual_qty in WAREHOUSE, written by ONE
# submitted Stock Reconciliation per run holding only the items whose figure
# moved, at zero valuation (these are a mirror of Hi-Tech's shelf, not Manna's
# books). Nothing is written when nothing moved.
#
# The batch is the whole shelf, so an item ERPNext holds stock for that the
# batch does not mention has none left in SAP and goes to 0. That is also the
# dangerous case - an empty or half-read batch would zero the shelf - so a run
# that would zero more than half of the stocked items, or that carries no rows
# at all, writes nothing and says so (the SAP Invoice mirror's guard).
#
# Codes: ERPNext's I- codes are Hi-Tech's, and stock comes from Hi-Tech, so any
# code ERPNext holds as an enabled stock item is accepted. A negative figure
# (committed beyond on hand) is written as 0 - nothing is available.
#
# Callers: System Manager or the "SAP Sync Bot" role.

COMPANY = "Manna Treads"
WAREHOUSE = "Finished Goods - MT"
EXPENSE_ACCOUNT = "Stock Adjustment - MT"
COST_CENTER = "Main - MT"
EPS = 0.0005
CHUNK = 100   # ERPNext queues the submit of anything longer; see run()


def squash(s):
	return " ".join(str(s or "").split())


def num(v):
	try:
		return float(v)
	except Exception:
		return 0.0


def plan(rows, items, bins, force=0):
	"""Pure. items: code -> {"disabled": 0|1, "is_stock_item": 0|1};
	bins: code -> actual_qty in WAREHOUSE. Returns {lines, notes, refused} - a dict,
	because safe_exec refuses tuple unpacking on assignment."""
	want = {}
	notes = []
	for r in rows:
		code = squash(r.get("code"))
		if not code:
			continue
		qty = max(0.0, round(num(r.get("qty")), 3))
		want[code] = want.get(code, 0.0) + qty
	lines = []
	for code in sorted(want):
		it = items.get(code)
		if not it:
			if want[code] > 0:
				notes.append("%s: not an item in ERPNext (%s in SAP)" % (code, want[code]))
			continue
		if not int(it.get("is_stock_item") or 0):
			continue
		if int(it.get("disabled") or 0):
			if want[code] > 0:
				notes.append("%s: disabled in ERPNext, %s in SAP not shown" % (code, want[code]))
			continue
		if abs(want[code] - num(bins.get(code))) > EPS:
			lines.append({"item_code": code, "qty": want[code], "was": num(bins.get(code))})
	stocked = [c for c, q in bins.items() if num(q) > EPS]
	gone = [c for c in stocked if c not in want and c in items]
	for c in sorted(gone):
		lines.append({"item_code": c, "qty": 0.0, "was": num(bins.get(c))})
	refused = ""
	if not want:
		refused = "the batch holds no rows - nothing changed (an empty read looks like this)"
	elif not force and len(stocked) >= 20 and len(gone) * 2 > len(stocked):
		refused = "%d of %d stocked items would go to 0 - more than half, so nothing changed; check the SAP read" % (len(gone), len(stocked))
	return {"lines": lines, "notes": notes, "refused": refused}


def run():
	user = frappe.session.user
	allowed = user == "Administrator" or bool(frappe.get_all("Has Role",
		filters={"parent": user, "parenttype": "User", "role": ["in", ["System Manager", "SAP Sync Bot"]]}, limit=1))
	if not allowed:
		frappe.throw("Only the SAP sync user may post stock.")
	body = frappe.form_dict
	rows = body.get("stock")
	if isinstance(rows, str):
		rows = frappe.parse_json(rows)
	if not isinstance(rows, list):
		frappe.throw("stock must be a list.")
	dry = frappe.utils.cint(body.get("dry_run")) == 1
	bins = {}
	for b in frappe.get_all("Bin", filters={"warehouse": WAREHOUSE}, fields=["item_code", "actual_qty"], limit_page_length=0):
		bins[b.item_code] = b.actual_qty
	codes = list({squash(r.get("code")) for r in rows if squash(r.get("code"))} | set(bins.keys()))
	items = {}
	for i in frappe.get_all("Item", filters={"name": ["in", codes]}, fields=["name", "disabled", "is_stock_item"], limit_page_length=0) if codes else []:
		items[i.name] = i
	# force=1 lets one run past the half-the-shelf guard - for the first run after
	# the code conversion, when the stock really did leave every old code at once.
	p = plan(rows, items, bins, frappe.utils.cint(body.get("force")))
	lines = p["lines"]
	notes = p["notes"]
	refused = p["refused"]
	made = []
	error = ""
	# A draft left in WAREHOUSE is a write still in flight (or one that failed
	# half way): running now would read the Bins before it lands and write the
	# same figures twice. Wait for it, or for somebody to look at it.
	pending = frappe.get_all("Stock Reconciliation", filters={"company": COMPANY, "set_warehouse": WAREHOUSE, "docstatus": 0}, pluck="name")
	if pending and not dry:
		refused = refused or ("draft reconciliation %s in %s - nothing changed until it is submitted or deleted" % (", ".join(pending), WAREHOUSE))
	if lines and not refused and not dry:
		# ERPNext submits a reconciliation of more than 100 lines in the
		# background, so the next run would not see it and would write it again
		# (found 9 Nov 2026). At CHUNK lines each submits here and now.
		for start in range(0, len(lines), CHUNK):
			d = None
			try:
				d = frappe.get_doc({
					"doctype": "Stock Reconciliation", "company": COMPANY, "purpose": "Stock Reconciliation",
					"set_posting_time": 1, "posting_date": frappe.utils.nowdate(), "posting_time": frappe.utils.nowtime(),
					"set_warehouse": WAREHOUSE, "expense_account": EXPENSE_ACCOUNT, "cost_center": COST_CENTER,
					"items": [{"item_code": l["item_code"], "warehouse": WAREHOUSE, "qty": l["qty"], "valuation_rate": 0,
						"allow_zero_valuation_rate": 1} for l in lines[start:start + CHUNK]],
				})
				d.insert(ignore_permissions=True)
				# submit() asks for the Submit permission again, and the sync user
				# has none on Stock Reconciliation - as Administrator this passed
				# and as the sync user it failed with an empty PermissionError
				# (10 Nov 2026). The role check at the top is the gate.
				d.flags.ignore_permissions = True
				d.submit()
				made.append(d.name)
			except Exception as e:
				error = "lines %d-%d: %s" % (start + 1, min(start + CHUNK, len(lines)), str(e) or "refused with no message - usually a missing permission")
				# The traceback goes to ERPNext's Error Log: the message alone is often empty.
				frappe.log_error("manna_sap_stock: reconciliation not written")
				if d and d.name and frappe.db.exists("Stock Reconciliation", {"name": d.name, "docstatus": 0}):
					frappe.delete_doc("Stock Reconciliation", d.name, ignore_permissions=True)
				break
	frappe.response["message"] = {"dry_run": dry, "refused": refused, "error": error, "reconciliations": made,
		"rows": len(rows), "changed": len(lines), "lines": lines, "notes": notes[:50], "notes_total": len(notes)}


if not frappe.flags.get("manna_test"):
	run()
