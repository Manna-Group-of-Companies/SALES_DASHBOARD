# Frappe Server Script
#   Name          : manna_sap_weights
#   Script Type   : API
#   API Method    : manna_sap_weights
#   Body (POST)   : JSON {"weights": [ {code, wpr, bpr}, ... ], "dry_run": 0|1}
#
# The roll figures the phone turns kilos into rolls and belts with:
#   Item.custom_weight_per_roll  <- Hi-Tech OITM.U_WeightPerRoll  (kg in a roll)
#   Item.custom_belts_per_roll   <- Hi-Tech OITM.U_BeltsPerRoll
# B1iF's weights package (Hi-Tech, a timer) posts every item that has either.
# It stands in for Sync-HitechProductsToTreads.ps1, whose source is only on the
# SAP server; the rule below is what the two systems themselves show.
#
# FILLS BLANKS ONLY. On 8 Nov 2026 every weight in SAP was a whole number (38)
# where ERPNext held the weighed figure (38.4) on 108 items typed on 10 Sep and
# never rewritten since - so the old sync does not overwrite a figure ERPNext
# has, and neither does this: SAP's rounding would move every kilo-to-roll
# conversion on the phone. A figure that differs is reported, never written.
# An item nobody has figures for in ERPNext gets SAP's, which is how the new
# codes (PMB..., made in SAP with management's weights) come to show as rolls.
#
# Figures also travel the other way: typing one in ERPNext raises
# custom_packing_push_pending (manna_item_packing_handover, Before Save) so it
# is pushed INTO SAP. An item still waiting for that push is left alone here,
# and these writes go by db.set_value, which runs no Before Save - a figure that
# came from SAP must not be queued to go back to it.
#
# custom_avg_weight_per_roll (the per-BELT weight, despite its name) and
# custom_weight_data_status are not written: no item on the site has either
# from a sync; the apps derive the belt weight from the two fields above.
#
# Callers: System Manager or the "SAP Sync Bot" role.

EPS = 0.0005


def squash(s):
	return " ".join(str(s or "").split())


def num(v):
	try:
		return float(v or 0)
	except Exception:
		return 0.0


def plan(rows, items):
	"""Pure. items: code -> {"wpr", "bpr", "pending"} as ERPNext holds them.
	Returns {"writes": [ {code, fields} ], "differs": [...], "counts": {...}}."""
	writes = []
	differs = []
	counts = {"rows": 0, "not_in_erpnext": 0, "waiting_for_push": 0, "unchanged": 0}
	seen = set()
	for r in rows:
		code = squash(r.get("code"))
		if not code or code in seen:
			continue
		seen.add(code)
		counts["rows"] = counts["rows"] + 1
		it = items.get(code)
		if not it:
			counts["not_in_erpnext"] = counts["not_in_erpnext"] + 1
			continue
		if int(it.get("pending") or 0):
			counts["waiting_for_push"] = counts["waiting_for_push"] + 1
			continue
		fields = {}
		for key, fn, as_int in (("wpr", "custom_weight_per_roll", 0), ("bpr", "custom_belts_per_roll", 1)):
			sap = num(r.get(key))
			have = num(it.get(key))
			if sap <= 0:
				continue
			if have <= 0:
				fields[fn] = int(round(sap)) if as_int else round(sap, 3)
			elif abs(sap - have) > EPS:
				differs.append("%s %s: SAP %s, ERPNext %s (kept)" % (code, fn, ("%g" % sap), ("%g" % have)))
		if fields:
			writes.append({"code": code, "fields": fields})
		else:
			counts["unchanged"] = counts["unchanged"] + 1
	return {"writes": writes, "differs": differs, "counts": counts}


def run():
	user = frappe.session.user
	allowed = user == "Administrator" or bool(frappe.get_all("Has Role",
		filters={"parent": user, "parenttype": "User", "role": ["in", ["System Manager", "SAP Sync Bot"]]}, limit=1))
	if not allowed:
		frappe.throw("Only the SAP sync user may post item weights.")
	body = frappe.form_dict
	rows = body.get("weights")
	if isinstance(rows, str):
		rows = frappe.parse_json(rows)
	if not isinstance(rows, list):
		frappe.throw("weights must be a list.")
	dry = frappe.utils.cint(body.get("dry_run")) == 1
	codes = list({squash(r.get("code")) for r in rows if squash(r.get("code"))})
	items = {}
	# In chunks: one "name in (...)" over a thousand codes is a very long query.
	for start in range(0, len(codes), 500):
		for i in frappe.get_all("Item", filters={"name": ["in", codes[start:start + 500]]},
				fields=["name", "custom_weight_per_roll", "custom_belts_per_roll", "custom_packing_push_pending"], limit_page_length=0):
			items[i.name] = {"wpr": i.custom_weight_per_roll, "bpr": i.custom_belts_per_roll, "pending": i.custom_packing_push_pending}
	p = plan(rows, items)
	if not dry:
		for w in p["writes"]:
			frappe.db.set_value("Item", w["code"], dict(w["fields"]))
	frappe.response["message"] = {"dry_run": dry, "counts": p["counts"], "written": len(p["writes"]), "writes": p["writes"][:100],
		"differs": p["differs"][:50], "differs_total": len(p["differs"])}


if not frappe.flags.get("manna_test"):
	run()
