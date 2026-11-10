# Frappe Server Script
#   Name          : manna_sap_customers
#   Script Type   : API
#   API Method    : manna_sap_customers
#   Body (POST)   : JSON {"customers": [ {code, name, active, sales_employee,
#                   phone, address, state, gstin}, ... ], "dry_run": 0|1}
#
# B1iF's customer package (Manna Treads, BP add/update event and a nightly full
# send) posts here, so one HTTP call does the insert-or-update and B1iF needs no
# branch (a B1iF step with a branch atom never runs - see sap-b1if/README).
#
# The rules are sap-credit-sync's new-customer rules (11 Oct 2026), unchanged,
# so the two can run side by side until the script is switched off:
#   - matched on custom_bp_code ONLY, never by name;
#   - created only for an active, standard-coded (C-123) SAP customer whose
#     sales employee is an enabled ERPNext rep (REP_MAP, else the same name);
#   - never created when ERPNext already holds the name - that is most likely
#     the same shop keyed by hand without its code, and needs linking by hand.
# On an existing customer only phone, billing address, state and GSTIN follow
# SAP, and only when SAP holds a value: a blank in SAP never clears ERPNext.
# Name, rep and SAP's inactive flag are reported, not written - a rep owns the
# customer on the phone, and moving it is a sales decision, not a sync.
#
# Credit, outstanding and payment terms are not here: they change with
# invoices and payments, not with the BP record (a later timer package).
#
# Callers: System Manager or the "SAP Sync Bot" role. Writes use
# ignore_permissions after that check.

# SAP (Manna Treads) sales employee -> ERPNext Sales Person. Copied from
# sap-credit-sync/rep-map.json (11 Oct 2026); keep the two the same while both run.
REP_MAP = {
	"prashanth": "Prashanth",
	"siraj-ekm": "Sirajudheen Kasim",
	"siraj-palakkad": "Sirajudheen Kasim",
	"siraj-ktm": "Sirajudheen Kasim",
	"siraj-kottayam": "Sirajudheen Kasim",
	"siraj-tvm": "Sirajudheen Kasim",
	"amjad kzkd": "Amjad Pr",
	"jaimon": "Jaimon D",
}
UPDATABLE = [("phone", "custom_phone"), ("address", "custom_billing_address"), ("state", "custom_state"), ("gstin", "custom_gstin")]


def squash(s):
	return " ".join(str(s or "").split())


def clean_phone(raw):
	# custom_phone is a Phone field: digits, spaces and + - ( ) only, 20 at most.
	# SAP often holds two numbers ("99951 / 9447..."); the first is taken.
	first = str(raw or "")
	for sep in "/;,":
		first = first.split(sep)[0]
	kept = "".join(ch for ch in first if ch.isdigit() or ch in "+-() ")
	# A dash left dangling ("9895621169-") would differ from ERPNext's copy and
	# rewrite the phone on every run.
	kept = squash(kept)[:20].strip(" -")
	digits = sum(1 for ch in kept if ch.isdigit())
	return kept if digits >= 6 else ""


def standard_code(code):
	return code.startswith("C-") and len(code) > 2 and code[2:].isdigit()


def plan(rows, existing_by_code, names, reps):
	"""Pure: what to do with each SAP customer. existing_by_code: code -> list of
	{name, customer_name, custom_assigned_reps, fields...}; names: lowercased
	customer name -> {name, code}; reps: lowercased -> exact Sales Person."""
	out = []
	for r in rows:
		code = squash(r.get("code"))
		nm = squash(r.get("name"))[:140].strip()
		active = str(r.get("active") or "").upper() in ("Y", "1", "TRUE", "TYES")
		sap = {"phone": clean_phone(r.get("phone")), "address": squash(r.get("address")), "state": squash(r.get("state")), "gstin": squash(r.get("gstin")).upper()}
		if not code:
			out.append({"code": "", "action": "skip", "reason": "no code"})
			continue
		hits = existing_by_code.get(code) or []
		if len(hits) > 1:
			out.append({"code": code, "action": "error", "reason": "ERPNext has %d customers with this code: %s" % (len(hits), ", ".join(h["name"] for h in hits))})
			continue
		if hits:
			h = hits[0]
			fields = {}
			for key, fn in UPDATABLE:
				if sap[key] and sap[key] != squash(h.get(fn)):
					fields[fn] = sap[key]
			notes = []
			if nm and nm.lower() != squash(h.get("customer_name")).lower():
				notes.append("SAP name is '%s'" % nm)
			if not active:
				notes.append("inactive or frozen in SAP")
			out.append({"code": code, "action": "update" if fields else "unchanged", "name": h["name"], "fields": fields, "notes": notes})
			continue
		se = squash(r.get("sales_employee"))
		key = se.lower()
		target = REP_MAP.get(key, se)
		rep = reps.get(squash(target).lower()) if key and key != "-no sales employee-" else None
		if not se or key == "-no sales employee-":
			out.append({"code": code, "action": "skip", "reason": "unassigned in SAP"})
		elif not rep:
			out.append({"code": code, "action": "skip", "reason": "SAP sales employee '%s' has no enabled ERPNext rep" % se})
		elif not standard_code(code):
			out.append({"code": code, "action": "skip", "reason": "non-standard SAP code"})
		elif not active:
			out.append({"code": code, "action": "skip", "reason": "inactive or frozen in SAP"})
		elif not nm:
			out.append({"code": code, "action": "skip", "reason": "no name in SAP"})
		elif nm.lower() in names:
			hit = names[nm.lower()]
			out.append({"code": code, "action": "skip", "reason": "ERPNext already has '%s'%s - put %s on it by hand" % (hit["name"], " (code %s)" % hit["code"] if hit["code"] else " with no SAP code", code)})
		else:
			names[nm.lower()] = {"name": nm, "code": code}
			doc = {"customer_name": nm, "customer_type": "Company", "gst_category": "Unregistered", "territory": "India",
				"custom_bp_code": code, "custom_assigned_reps": rep}
			if sap["phone"]:
				doc["custom_phone"] = sap["phone"]
			if sap["address"]:
				doc["custom_address"] = sap["address"]
				doc["custom_billing_address"] = sap["address"]
			if sap["state"]:
				doc["custom_state"] = sap["state"]
			if sap["gstin"]:
				doc["custom_gstin"] = sap["gstin"]
			out.append({"code": code, "action": "create", "doc": doc})
	return out


def run():
	user = frappe.session.user
	# frappe.get_roles is not in safe_exec; Has Role is.
	allowed = user == "Administrator" or bool(frappe.get_all("Has Role",
		filters={"parent": user, "parenttype": "User", "role": ["in", ["System Manager", "SAP Sync Bot"]]}, limit=1))
	if not allowed:
		frappe.throw("Only the SAP sync user may post customers.")
	body = frappe.form_dict
	rows = body.get("customers")
	if isinstance(rows, str):
		rows = frappe.parse_json(rows)
	if not isinstance(rows, list):
		frappe.throw("customers must be a list.")
	dry = frappe.utils.cint(body.get("dry_run")) == 1
	codes = [squash(r.get("code")) for r in rows if squash(r.get("code"))]
	fl = ["name", "customer_name", "custom_bp_code", "custom_assigned_reps"] + [fn for _, fn in UPDATABLE]
	existing = {}
	for c in frappe.get_all("Customer", filters={"custom_bp_code": ["in", codes]}, fields=fl, limit_page_length=0) if codes else []:
		existing.setdefault(squash(c.custom_bp_code), []).append(c)
	names = {}
	for c in frappe.get_all("Customer", fields=["name", "customer_name", "custom_bp_code"], limit_page_length=0):
		for k in (squash(c.customer_name).lower(), squash(c.name).lower()):
			if k and k not in names:
				names[k] = {"name": c.name, "code": squash(c.custom_bp_code)}
	reps = {}
	for s in frappe.get_all("Sales Person", filters={"enabled": 1, "is_group": 0}, fields=["name"], limit_page_length=0):
		reps[squash(s.name).lower()] = s.name
	result = plan(rows, existing, names, reps)
	stamp = frappe.utils.now()
	for p in result:
		if dry or p["action"] not in ("create", "update"):
			continue
		try:
			if p["action"] == "create":
				d = frappe.get_doc(dict(p["doc"], doctype="Customer", custom_sap_last_synced=stamp))
				d.insert(ignore_permissions=True)
				p["name"] = d.name
			else:
				d = frappe.get_doc("Customer", p["name"])
				d.update(p["fields"])
				d.custom_sap_last_synced = stamp
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
