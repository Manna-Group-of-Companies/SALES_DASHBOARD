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
#
# A BATCH THAT IS OLD IS IGNORED (11 Nov 2026). B1iF keeps every message it could
# not deliver and sends them all when ERPNext answers again: after one night
# with the local site down, about 900 arrived in ten minutes. Most kinds are the
# WHOLE current state - the shelf, every order's stage, every balance - so an old
# one written after a newer one puts yesterday's figures back. Each query now
# stamps SAP's own UTC time on the batch ("sent_at"), and a kind in MAX_AGE whose
# batch is older than that is answered "stale, ignored" - with 200, so B1iF
# counts it delivered and stops sending it. The next run carries the same state,
# fresh. Customers and items are not in MAX_AGE: a late one is still the newest
# word on that record, and dropping it would lose the change until the nightly
# send. A batch with no sent_at (an older package, an empty result) or one that
# cannot be read as a time is let through: refusing everything because of a
# field this script does not understand would stop every sync without a word.
# The age is taken from the database's UTC clock, so no time zone setting on
# either side matters; a SAP server clock that runs more than MAX_AGE behind
# would make every batch stale, which is why each answer records age_seconds.

KINDS = {"customers": "manna_sap_customers", "items": "manna_sap_items", "stock": "manna_sap_stock", "status": "manna_sap_status",
	"weights": "manna_sap_weights", "payments": "manna_sap_payments",
	"credit": "manna_sap_credit", "invoices": "manna_sap_invoices", "pricing": "manna_sap_pricing"}
# Seconds. Every timer step runs at least every 30 minutes and posts within
# seconds of reading, so ten minutes is far outside a healthy run.
MAX_AGE = {"stock": 600, "status": 600, "credit": 600, "invoices": 600, "payments": 600, "pricing": 600, "weights": 600}


def stale(kind, age):
	"""Pure. Whether a batch of this kind, read from SAP `age` seconds ago, is too
	old to write. An unknown age (None) is never stale."""
	if age is None or kind not in MAX_AGE:
		return False
	return age > MAX_AGE[kind]


def age_of(sent_at):
	"""Seconds since SAP read the batch, by the database's UTC clock; None when
	the batch carries no time or one that is not a time."""
	sent = str(sent_at or "").strip()
	if not sent:
		return None
	try:
		rows = frappe.db.sql("select timestampdiff(second, %s, utc_timestamp())", (sent[:19],))
		return None if rows[0][0] is None else int(rows[0][0])
	except Exception:
		return None


def run():
	kind = str(frappe.form_dict.get("kind") or "").strip().lower()
	if kind not in KINDS:
		# Say which keys did arrive: a body B1if sent in a shape ERPNext could not
		# read as JSON looks exactly like a missing kind, and the sender sees only this.
		seen = ", ".join(["%s (%d chars)" % (k, len(str(frappe.form_dict.get(k)))) for k in sorted(frappe.form_dict.keys())])[:300]
		frappe.throw("kind must be one of: " + ", ".join(sorted(KINDS)) + " | keys received: " + seen)
	label = kind + ("/" + str(frappe.form_dict.get("source")) if kind == "status" else "")
	age = age_of(frappe.form_dict.get("sent_at"))
	old = stale(kind, age)
	if old:
		frappe.response["message"] = {"stale": True, "age_seconds": age,
			"ignored": "read from SAP %d s ago, more than the %d s a %s batch may be - nothing changed; the next run carries the same state" % (age, MAX_AGE[kind], kind)}
	else:
		writes = str(frappe.db.get_single_value("SAP Sync Control", "custom_b1if_writes") or "").lower().replace(",", " ").split()
		frappe.form_dict["dry_run"] = 0 if (kind in writes or "all" in writes) else 1
		run_script(KINDS[kind])

	# Keep each sync's last answer where a person can read it without B1iF's message
	# log: SAP Sync Control -> "B1iF: last answers". Only the short values - counts,
	# refusals, errors - not the row lists. An ignored batch is noted beside the
	# kind's last real answer, not over it. A failure to note it must not fail the sync.
	try:
		last = json.loads(frappe.db.get_single_value("SAP Sync Control", "custom_b1if_last") or "{}")
		if old:
			was = last.get(label + " (stale, ignored)") or {}
			last[label + " (stale, ignored)"] = {"at": str(frappe.utils.now())[:19], "age_seconds": age, "ignored_so_far": int(was.get("ignored_so_far") or 0) + 1}
		else:
			msg = frappe.response.get("message") or {}
			short = {"at": str(frappe.utils.now())[:19]}
			if age is not None:
				short["age_seconds"] = age
			for k in msg:
				v = msg[k]
				if k in ("count", "counts", "done", "fields", "serverCheck") or not (isinstance(v, list) or isinstance(v, dict)):
					short[k] = v
			last[label] = short
		frappe.db.set_value("SAP Sync Control", None, "custom_b1if_last", json.dumps(last, indent=1, sort_keys=True))
	except Exception:
		pass


if not frappe.flags.get("manna_test"):
	run()
