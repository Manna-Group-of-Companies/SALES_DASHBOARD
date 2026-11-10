# Frappe Server Script
#   Name          : manna_sap_status
#   Script Type   : API
#   API Method    : manna_sap_status
#   Body (POST)   : JSON {"source": "hitech" | "manna", "lines": [ {order, item, stage}, ... ], "dry_run": 0|1}
#
# The order and line status the reps see (decided by the user, 9 Nov 2026).
# Two B1iF timer packages post here, one per company, because a B1iF query runs
# on one company's connection and must name no database:
#   hitech - per Hi-Tech sales-order line made for an ERPNext order:
#            stage "In SAP" (the line exists), "Picked" (on a pick list, or
#            already delivered or invoiced) or "Cancelled" (the order was
#            cancelled, or the line closed with nothing sent)
#   manna  - per Manna Treads sales-order line: stage "Dispatched" when a Manna
#            A/R invoice covers it (straight from the order, or through its
#            delivery), else ""
# `order` is the ERPNext name, which the whole chain carries in NumAtCard.
#
# Each post is the whole state of every order it names: a line of a named order
# that the batch does not mention has nothing from that source (a Hi-Tech line
# removed, an invoice cancelled) and is cleared. Orders not named are untouched.
#
# Line status = Dispatched if Manna invoiced it, else Hi-Tech's stage.
# Order status (Cancelled lines left out): Dispatched when every line is,
# Partially Dispatched when some are, then Picked / Partially Picked the same
# way, In SAP when every line is at least in SAP, else blank. A line's place in
# the chain is found by ITEM CODE, as PASS B and the pick-list step find it -
# the chain carries no line key - so an item on two lines of one order cannot
# be told apart and gets no status, reported.
#
# Writes with frappe.db.set_value and update_modified=False: these are reports
# about the order, and bumping `modified` would make a rep editing a draft lose
# their edit to "the document has been modified".
#
# Callers: System Manager or the "SAP Sync Bot" role.

LINE_STAGES = ["", "In SAP", "Picked", "Cancelled"]


def squash(s):
	return " ".join(str(s or "").split())


def merge_stage(prev, st):
	# One item on two Hi-Tech lines: the item is only as far along as its
	# slower line, and Cancelled only when both are.
	if prev is None:
		return st
	if prev == "Cancelled":
		return st
	if st == "Cancelled":
		return prev
	return prev if LINE_STAGES.index(prev) <= LINE_STAGES.index(st) else st


def line_status(ht_stage, dispatched):
	if dispatched:
		return "Dispatched"
	return ht_stage or ""


def order_status(statuses):
	live = [s for s in statuses if s != "Cancelled"]
	if statuses and not live:
		return "Cancelled"
	if not live:
		return ""
	n = len(live)
	disp = sum(1 for s in live if s == "Dispatched")
	picked = sum(1 for s in live if s in ("Picked", "Dispatched"))
	in_sap = sum(1 for s in live if s in ("In SAP", "Picked", "Dispatched"))
	if disp == n:
		return "Dispatched"
	if disp:
		return "Partially Dispatched"
	if picked == n:
		return "Picked"
	if picked:
		return "Partially Picked"
	if in_sap == n:
		return "In SAP"
	return ""


def plan(source, rows, orders):
	"""Pure. orders: ERPNext name -> {"status": current order status,
	"lines": [ {name, item_code, ht_stage, dispatched, status} ]}.
	Returns {"lines": [ {row, fields} ], "orders": [ {name, status} ], "notes": [...]}."""
	got = {}
	notes = []
	for r in rows:
		o = squash(r.get("order"))
		it = squash(r.get("item")).upper()
		st = squash(r.get("stage"))
		if not o or not it:
			continue
		if source == "hitech" and st not in LINE_STAGES:
			notes.append("%s %s: unknown stage '%s'" % (o, it, st))
			continue
		got.setdefault(o, {})
		if source == "hitech":
			got[o][it] = merge_stage(got[o].get(it), st)
		else:
			got[o][it] = got[o].get(it, True) and st == "Dispatched"
	line_writes = []
	order_writes = []
	for o in sorted(got):
		doc = orders.get(o)
		if not doc:
			notes.append("%s: no such ERPNext order, or it is cancelled" % o)
			continue
		count = {}
		for l in doc["lines"]:
			k = squash(l.get("item_code")).upper()
			count[k] = count.get(k, 0) + 1
		statuses = []
		for l in doc["lines"]:
			k = squash(l.get("item_code")).upper()
			ht = squash(l.get("ht_stage"))
			disp = 1 if int(l.get("dispatched") or 0) else 0
			if count[k] > 1:
				if k in got[o]:
					notes.append("%s %s: on %d lines of the order - no status, the chain cannot tell them apart" % (o, k, count[k]))
				statuses.append(squash(l.get("status")))
				continue
			if source == "hitech":
				ht = got[o].get(k, "")
			else:
				disp = 1 if got[o].get(k) else 0
			new = line_status(ht, disp)
			fields = {}
			if ht != squash(l.get("ht_stage")):
				fields["custom_sap_ht_stage"] = ht
			if disp != (1 if int(l.get("dispatched") or 0) else 0):
				fields["custom_sap_mt_dispatched"] = disp
			if new != squash(l.get("status")):
				fields["custom_sap_line_status"] = new
			if fields:
				line_writes.append({"order": o, "row": l["name"], "item": k, "fields": fields})
			statuses.append(new)
		for k in got[o]:
			if k not in count:
				notes.append("%s %s: in SAP but not on the ERPNext order" % (o, k))
		st = order_status(statuses)
		if st != squash(doc.get("status")):
			order_writes.append({"name": o, "status": st})
	return {"lines": line_writes, "orders": order_writes, "notes": notes}


def run():
	user = frappe.session.user
	allowed = user == "Administrator" or bool(frappe.get_all("Has Role",
		filters={"parent": user, "parenttype": "User", "role": ["in", ["System Manager", "SAP Sync Bot"]]}, limit=1))
	if not allowed:
		frappe.throw("Only the SAP sync user may post order status.")
	body = frappe.form_dict
	source = squash(body.get("source")).lower()
	if source not in ("hitech", "manna"):
		frappe.throw("source must be hitech or manna.")
	rows = body.get("lines")
	if isinstance(rows, str):
		rows = frappe.parse_json(rows)
	if not isinstance(rows, list):
		frappe.throw("lines must be a list.")
	dry = frappe.utils.cint(body.get("dry_run")) == 1
	names = list({squash(r.get("order")) for r in rows if squash(r.get("order"))})
	orders = {}
	if names:
		for so in frappe.get_all("Sales Order", filters={"name": ["in", names], "docstatus": ["<", 2]}, fields=["name", "custom_sap_order_status"], limit_page_length=0):
			orders[so.name] = {"status": so.custom_sap_order_status, "lines": []}
		if orders:
			for l in frappe.get_all("Sales Order Item", filters={"parent": ["in", list(orders.keys())], "parenttype": "Sales Order"},
					fields=["name", "parent", "item_code", "custom_sap_ht_stage", "custom_sap_mt_dispatched", "custom_sap_line_status"], limit_page_length=0):
				orders[l.parent]["lines"].append({"name": l.name, "item_code": l.item_code, "ht_stage": l.custom_sap_ht_stage,
					"dispatched": l.custom_sap_mt_dispatched, "status": l.custom_sap_line_status})
	p = plan(source, rows, orders)
	if not dry:
		stamp = frappe.utils.now()
		for w in p["lines"]:
			frappe.db.set_value("Sales Order Item", w["row"], w["fields"], update_modified=False)
		touched = {w["order"] for w in p["lines"]} | {w["name"] for w in p["orders"]}
		for w in p["orders"]:
			frappe.db.set_value("Sales Order", w["name"], "custom_sap_order_status", w["status"], update_modified=False)
		for n in touched:
			frappe.db.set_value("Sales Order", n, "custom_sap_status_synced_at", stamp, update_modified=False)
	frappe.response["message"] = {"dry_run": dry, "source": source, "orders_named": len(names), "orders_found": len(orders),
		"line_writes": p["lines"], "order_writes": p["orders"], "notes": p["notes"][:50], "notes_total": len(p["notes"])}


if not frappe.flags.get("manna_test"):
	run()
