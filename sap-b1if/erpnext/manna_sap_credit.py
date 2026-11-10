# Frappe Server Script
#   Name          : manna_sap_credit
#   Script Type   : API
#   API Method    : manna_sap_credit
#   Body (POST)   : JSON {"credit": [ {code, limit, balance, terms_code, terms,
#                   b1, b2, b3, b4, od_amt, od_days}, ... ], "dry_run": 0|1}
#
# Credit limit, outstanding, ageing and overdue-past-terms on Customer, for
# customers matched on custom_bp_code only. A port of what
# sap-credit-sync/Sync-SapCreditLimits.ps1 writes (its header is the reference),
# rule for rule, so the two agree while both run. B1iF's credit package (Manna
# Treads, a timer) posts one row per SAP customer with SAP's own sums; every
# rule that decides what is written is here:
#
#   custom_credit_limit         <- limit, when > 0 (SAP's 0 means "no figure"
#                                  and never wipes a typed limit); WRITE_MODE
#                                  fill_blanks only sets an empty one
#   custom_outstanding_balance  <- balance (the account balance), or the bucket
#                                  sum when OUTSTANDING_TOTAL says so
#   custom_outstanding_0_30 ... <- b1..b4: open invoices less open credit notes,
#     30_60, 60_90, 90_plus        aged in SAP by posting date; 0 when the
#                                  customer has none, so stale figures clear
#   custom_payment_terms        <- the SAP term's name; a blank never clears it
#   custom_overdue_past_terms   <- open amount on invoices past their due date,
#                                  capped at the account balance (so payments on
#                                  account count), 0 when no term is set (-1)
#   custom_overdue_days         <- days the oldest of those is past due, 0 when
#                                  the amount is 0
#   custom_sap_last_synced      <- now, only on a customer something changed on
#
# A customer SAP did not send is left completely alone. The standard
# credit_limits child table is never touched (it would switch on ERPNext's own
# order blocking). Written with db.set_value: these are figures, and saving 250
# Customers as documents every few minutes would take longer than B1iF waits.
#
# Callers: System Manager or the "SAP Sync Bot" role.

WRITE_MODE = "overwrite"               # or "fill_blanks" - the script's write_mode
OUTSTANDING_TOTAL = "account_balance"  # or "bucket_sum"
NO_TERMS_CODE = -1
EPS = 0.005
BUCKETS = [("b1", "custom_outstanding_0_30"), ("b2", "custom_outstanding_30_60"), ("b3", "custom_outstanding_60_90"), ("b4", "custom_outstanding_90_plus")]


def squash(s):
	return " ".join(str(s or "").split())


def num(v):
	try:
		return float(v or 0)
	except Exception:
		return 0.0


def figures(r):
	"""Pure: one SAP row -> the values the Customer should hold."""
	b = [round(num(r.get(k)), 2) for k, _ in BUCKETS]
	bucket_sum = round(b[0] + b[1] + b[2] + b[3], 2)
	balance = num(r.get("balance"))
	terms_code = int(num(r.get("terms_code"))) if squash(r.get("terms_code")) != "" else NO_TERMS_CODE
	od_amt = 0.0
	od_days = 0
	if terms_code != NO_TERMS_CODE and num(r.get("od_amt")) > 0:
		od_amt = round(max(0.0, min(num(r.get("od_amt")), balance)), 2)
		if od_amt > 0:
			od_days = int(num(r.get("od_days")))
	return {"limit": num(r.get("limit")), "balance": round(bucket_sum if OUTSTANDING_TOTAL == "bucket_sum" else balance, 2),
		"buckets": b, "terms": squash(r.get("terms")), "od_amt": od_amt, "od_days": od_days}


def changes(want, have):
	"""Pure: the fields to write on one customer. have: the Customer row as ERPNext holds it."""
	f = {}
	cur = num(have.get("custom_credit_limit"))
	if want["limit"] > 0 and not (WRITE_MODE == "fill_blanks" and cur != 0) and abs(want["limit"] - cur) >= EPS:
		f["custom_credit_limit"] = want["limit"]
	if abs(want["balance"] - num(have.get("custom_outstanding_balance"))) >= EPS:
		f["custom_outstanding_balance"] = want["balance"]
	for i in range(4):
		fn = BUCKETS[i][1]
		if abs(want["buckets"][i] - num(have.get(fn))) >= EPS:
			f[fn] = want["buckets"][i]
	if want["terms"] != "" and want["terms"].lower() != squash(have.get("custom_payment_terms")).lower():
		f["custom_payment_terms"] = want["terms"]
	if abs(want["od_amt"] - num(have.get("custom_overdue_past_terms"))) >= EPS:
		f["custom_overdue_past_terms"] = want["od_amt"]
	if want["od_days"] != int(num(have.get("custom_overdue_days"))):
		f["custom_overdue_days"] = want["od_days"]
	return f


def run():
	user = frappe.session.user
	allowed = user == "Administrator" or bool(frappe.get_all("Has Role",
		filters={"parent": user, "parenttype": "User", "role": ["in", ["System Manager", "SAP Sync Bot"]]}, limit=1))
	if not allowed:
		frappe.throw("Only the SAP sync user may post credit figures.")
	body = frappe.form_dict
	rows = body.get("credit")
	if isinstance(rows, str):
		rows = frappe.parse_json(rows)
	if not isinstance(rows, list):
		frappe.throw("credit must be a list.")
	dry = frappe.utils.cint(body.get("dry_run")) == 1
	fl = ["name", "custom_bp_code", "custom_credit_limit", "custom_outstanding_balance", "custom_payment_terms", "custom_overdue_past_terms",
		"custom_overdue_days"] + [fn for _, fn in BUCKETS]
	by_code = {}
	dupes = []
	for c in frappe.get_all("Customer", filters={"custom_bp_code": ["is", "set"]}, fields=fl, limit_page_length=0):
		k = squash(c.custom_bp_code).lower()
		if k in by_code:
			dupes.append(squash(c.custom_bp_code))
		by_code[k] = c
	if dupes:
		# Never pick one of two customers with the same code to write to.
		frappe.throw("ERPNext has duplicate custom_bp_code value(s): %s. Resolve before syncing." % ", ".join(sorted(set(dupes))))
	writes = []
	seen = set()
	for r in rows:
		k = squash(r.get("code")).lower()
		if not k or k in seen or k not in by_code:
			continue
		seen.add(k)
		f = changes(figures(r), by_code[k])
		if f:
			writes.append({"name": by_code[k].name, "code": squash(r.get("code")), "fields": f})
	if not dry:
		stamp = frappe.utils.now()
		for w in writes:
			frappe.db.set_value("Customer", w["name"], dict(w["fields"], custom_sap_last_synced=stamp))
	count = {}
	for w in writes:
		for fn in w["fields"]:
			count[fn] = count.get(fn, 0) + 1
	frappe.response["message"] = {"dry_run": dry, "rows": len(rows), "matched": len(seen), "changed": len(writes), "fields": count, "writes": writes[:50]}


if not frappe.flags.get("manna_test"):
	run()
