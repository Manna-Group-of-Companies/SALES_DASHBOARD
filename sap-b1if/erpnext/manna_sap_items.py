# Frappe Server Script
#   Name          : manna_sap_items
#   Script Type   : API
#   API Method    : manna_sap_items
#   Body (POST)   : JSON {"items": [ {code, name, active, uom, hsn}, ... ], "dry_run": 0|1}
#
# B1iF's item package (Manna Treads, item add/update event and a nightly full
# send) posts here; one call does the insert-or-update, as manna_sap_customers.
#
# ONLY THE SHARED CODES. The finished-goods codes made in the November 2026
# conversion (PMD..., PMB..., PV..., PR..., HMD..., BM..., SM... - SHARED_PREFIXES)
# are the same item in Manna Treads and Hi-Tech. Everything else is not: Manna's
# I-1048 and Hi-Tech's I-1048 are different items, and ERPNext's I- codes are
# Hi-Tech's. A Manna I- code written here would rename a Hi-Tech item. So any
# code that is not a shared one is skipped, whatever ERPNext holds under it.
#
# Existing item: the name (and a description still equal to the old name)
# follows SAP - the conversion put the old quality in brackets on every name -
# and so does `disabled`, because SAP refuses an inactive item on an order and
# the phone should not offer one. HSN follows SAP when ERPNext has that code.
# Group, unit and the roll figures are never touched: the group is how the phone
# sorts its list, a unit cannot change once an item has transactions, and the
# roll figures go the other way (ERPNext -> SAP, manna_item_packing_handover).
#
# New item: created only when active in SAP and in a unit ERPNext knows, set
# the way localdev/erp-fg-items.mjs made the first ones (stock, sales and
# purchase item), in the group its prefix gives (GROUP_BY_PREFIX).
#
# Callers: System Manager or the "SAP Sync Bot" role.

# Longest first: "BME" must win over "BM".
SHARED_PREFIXES = ["PMD", "PMB", "HMD", "BME", "BRE", "BVE", "PV", "PR", "HR", "HV", "BM", "BR", "BV", "SM", "SR", "SV"]
GROUP_BY_PREFIX = {"P": "FG", "H": "HOT", "B": "Bonding Gum", "S": "Vulcanizing Solution"}
UOM = {"KGS": "Kg", "KG": "Kg", "KGG": "Kg", "LTR": "Litre", "LTRS": "Litre", "NOS": "Nos"}


def squash(s):
	return " ".join(str(s or "").split())


def shared_prefix(code):
	for p in SHARED_PREFIXES:
		rest = code[len(p):]
		if code.startswith(p) and rest and rest.isdigit():
			return p
	return ""


def hsn_digits(h):
	# India Compliance refuses an Item HSN that is not 6 or 8 digits ("3506" is
	# a valid GST HSN Code record but not a valid Item HSN), so a shorter one is
	# treated as none and reported.
	d = "".join(ch for ch in str(h or "") if ch.isdigit())
	return d if len(d) in (6, 8) else ""


def plan(rows, existing, hsns, groups):
	"""Pure. existing: code -> {item_name, description, disabled, gst_hsn_code};
	hsns: set of ERPNext GST HSN Codes; groups: set of ERPNext Item Groups."""
	out = []
	seen = set()
	for r in rows:
		code = squash(r.get("code")).upper()
		nm = squash(r.get("name"))[:140].strip()
		active = str(r.get("active") or "").upper() in ("Y", "1", "TRUE", "TYES")
		hsn = hsn_digits(r.get("hsn"))
		pre = shared_prefix(code)
		if not pre:
			out.append({"code": code, "action": "skip", "reason": "not a shared code - Manna's own code, never written to ERPNext"})
			continue
		if code in seen:
			out.append({"code": code, "action": "skip", "reason": "sent twice"})
			continue
		seen.add(code)
		h = existing.get(code)
		if h:
			fields = {}
			if nm and nm != squash(h.get("item_name")):
				fields["item_name"] = nm
				if squash(h.get("description")) in ("", squash(h.get("item_name"))):
					fields["description"] = nm
			dis = 0 if active else 1
			if dis != int(h.get("disabled") or 0):
				fields["disabled"] = dis
			notes = []
			if hsn and hsn != squash(h.get("gst_hsn_code")):
				if hsn in hsns:
					fields["gst_hsn_code"] = hsn
				else:
					notes.append("SAP HSN %s is not in ERPNext" % hsn)
			out.append({"code": code, "action": "update" if fields else "unchanged", "fields": fields, "notes": notes})
			continue
		uom = UOM.get(squash(r.get("uom")).upper())
		group = GROUP_BY_PREFIX[pre[0]]
		if not active:
			out.append({"code": code, "action": "skip", "reason": "inactive in SAP"})
		elif not nm:
			out.append({"code": code, "action": "skip", "reason": "no name in SAP"})
		elif not uom:
			out.append({"code": code, "action": "skip", "reason": "SAP unit '%s' has no ERPNext unit" % squash(r.get("uom"))})
		elif group not in groups:
			out.append({"code": code, "action": "skip", "reason": "Item Group '%s' is not in ERPNext" % group})
		elif hsn not in hsns:
			# India Compliance requires an HSN on a sales item, so it cannot be
			# made without one; it is made the run after SAP's HSN is fixed.
			out.append({"code": code, "action": "skip", "reason": "no valid HSN: SAP has '%s'" % (squash(r.get("hsn")) or "none")})
		else:
			doc = {"item_code": code, "item_name": nm, "description": nm, "item_group": group, "stock_uom": uom,
				"uoms": [{"uom": uom, "conversion_factor": 1}], "is_stock_item": 1, "is_sales_item": 1, "is_purchase_item": 1,
				"include_item_in_manufacturing": 1, "grant_commission": 1, "gst_hsn_code": hsn}
			out.append({"code": code, "action": "create", "doc": doc})
	return out


def run():
	user = frappe.session.user
	allowed = user == "Administrator" or bool(frappe.get_all("Has Role",
		filters={"parent": user, "parenttype": "User", "role": ["in", ["System Manager", "SAP Sync Bot"]]}, limit=1))
	if not allowed:
		frappe.throw("Only the SAP sync user may post items.")
	body = frappe.form_dict
	rows = body.get("items")
	if isinstance(rows, str):
		rows = frappe.parse_json(rows)
	if not isinstance(rows, list):
		frappe.throw("items must be a list.")
	dry = frappe.utils.cint(body.get("dry_run")) == 1
	codes = [squash(r.get("code")).upper() for r in rows if shared_prefix(squash(r.get("code")).upper())]
	existing = {}
	if codes:
		for i in frappe.get_all("Item", filters={"name": ["in", codes]}, fields=["name", "item_name", "description", "disabled", "gst_hsn_code"], limit_page_length=0):
			existing[i.name.upper()] = i
	want = list({hsn_digits(r.get("hsn")) for r in rows if hsn_digits(r.get("hsn"))})
	hsns = set(frappe.get_all("GST HSN Code", filters={"name": ["in", want]}, pluck="name")) if want else set()
	groups = set(frappe.get_all("Item Group", filters={"name": ["in", list(GROUP_BY_PREFIX.values())]}, pluck="name"))
	result = plan(rows, existing, hsns, groups)
	for p in result:
		if dry or p["action"] not in ("create", "update"):
			continue
		try:
			if p["action"] == "create":
				frappe.get_doc(dict(p["doc"], doctype="Item")).insert(ignore_permissions=True)
			else:
				d = frappe.get_doc("Item", existing[p["code"]].name)
				d.update(p["fields"])
				d.save(ignore_permissions=True)
		except Exception as e:
			p["action"] = "error"
			p["reason"] = str(e)
	count = {}
	for p in result:
		count[p["action"]] = count.get(p["action"], 0) + 1
	frappe.response["message"] = {"dry_run": dry, "count": count, "results": result}


if not frappe.flags.get("manna_test"):
	run()
