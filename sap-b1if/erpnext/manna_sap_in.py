# Frappe Server Script
#   Name          : manna_sap_in
#   Script Type   : API
#   API Method    : manna_sap_in
#   Body (POST)   : the JSON body of one of the endpoints below, plus "kind"
#
# The one address B1iF posts to. B1iF's Call HTTP atom takes its host, path and
# login from ONE system in the SLD, so one path for every package means one SLD
# system - and one thing to re-point on live - instead of one per endpoint.
# "kind" in the body says which endpoint the batch is for; this script only
# hands it on. The rules, and who may call, are in those scripts.
#
# WHETHER A SYNC WRITES IS DECIDED HERE, NOT IN B1iF (10 Nov 2026). The body's
# own "dry_run" is ignored: a kind writes only when it is named in
# SAP Sync Control -> "B1iF: syncs that write" (custom_b1if_writes, kinds
# separated by commas or spaces; "all" for every kind). Everything else is a dry
# run, which answers what it would do and changes nothing. So going live, or
# stopping one sync from writing, is one field in ERPNext - no stylesheet to
# edit and no package to import again in B1iF - and a site that has never been
# told anything writes nothing.

KINDS = {"customers": "manna_sap_customers", "items": "manna_sap_items", "stock": "manna_sap_stock", "status": "manna_sap_status",
	"weights": "manna_sap_weights", "payments": "manna_sap_payments",
	"credit": "manna_sap_credit", "invoices": "manna_sap_invoices", "pricing": "manna_sap_pricing"}
kind = str(frappe.form_dict.get("kind") or "").strip().lower()
if kind not in KINDS:
	# Say which keys did arrive: a body B1if sent in a shape ERPNext could not
	# read as JSON looks exactly like a missing kind, and the sender sees only this.
	seen = ", ".join(["%s (%d chars)" % (k, len(str(frappe.form_dict.get(k)))) for k in sorted(frappe.form_dict.keys())])[:300]
	frappe.throw("kind must be one of: " + ", ".join(sorted(KINDS)) + " | keys received: " + seen)
writes = str(frappe.db.get_single_value("SAP Sync Control", "custom_b1if_writes") or "").lower().replace(",", " ").split()
frappe.form_dict["dry_run"] = 0 if (kind in writes or "all" in writes) else 1
run_script(KINDS[kind])

# Keep each sync's last answer where a person can read it without B1iF's message
# log: SAP Sync Control -> "B1iF: last answers". Only the short values - counts,
# refusals, errors - not the row lists. A failure to note it must not fail the sync.
try:
	msg = frappe.response.get("message") or {}
	short = {"at": str(frappe.utils.now())[:19]}
	for k in msg:
		v = msg[k]
		if k in ("count", "counts", "done", "fields", "serverCheck") or not (isinstance(v, list) or isinstance(v, dict)):
			short[k] = v
	label = kind + ("/" + str(frappe.form_dict.get("source")) if kind == "status" else "")
	last = json.loads(frappe.db.get_single_value("SAP Sync Control", "custom_b1if_last") or "{}")
	last[label] = short
	frappe.db.set_value("SAP Sync Control", None, "custom_b1if_last", json.dumps(last, indent=1, sort_keys=True))
except Exception:
	pass
