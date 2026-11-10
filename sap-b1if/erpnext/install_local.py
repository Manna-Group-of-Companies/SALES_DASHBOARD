# Put the B1iF receiving Server Scripts on the LOCAL ERPNext (127.0.0.1:8000) only.
#   python install_local.py            check fields, create or update the scripts
# Reads the local API key from Manna_CMMS/server/.env and refuses any other host:
# these scripts write customers, so they reach the live site only by hand, later.
import json, os, sys, urllib.request, urllib.error
HERE = os.path.dirname(os.path.abspath(__file__))
ENV = r"C:\Users\Melvin\Documents\MANNA\Manna_CMMS\server\.env"
env = dict(l.strip().split("=", 1) for l in open(ENV, encoding="utf-8") if "=" in l and not l.startswith("#"))
URL = env["ERPNEXT_URL"].rstrip("/")
if URL not in ("http://127.0.0.1:8000", "http://localhost:8000"):
	sys.exit("refusing: ERPNEXT_URL is %s, not the local site" % URL)
AUTH = "token %s:%s" % (env["ERPNEXT_API_KEY"], env["ERPNEXT_API_SECRET"])
SCRIPTS = ["manna_sap_customers", "manna_sap_items", "manna_sap_stock", "manna_sap_status", "manna_sap_weights", "manna_sap_payments", "manna_sap_credit", "manna_sap_invoices", "manna_sap_pricing", "manna_sap_in"]
FIELDS = {"Item": ["gst_hsn_code", "custom_weight_per_roll"], "Customer": ["custom_bp_code", "custom_assigned_reps", "custom_phone", "custom_address", "custom_billing_address", "custom_state", "custom_gstin", "custom_sap_last_synced"]}


def api(method, path, body=None):
	req = urllib.request.Request(URL + path, method=method, data=json.dumps(body).encode() if body is not None else None,
		headers={"Authorization": AUTH, "Content-Type": "application/json", "Accept": "application/json"})
	try:
		return json.load(urllib.request.urlopen(req, timeout=30))
	except urllib.error.HTTPError as e:
		raise SystemExit("%s %s -> %s %s" % (method, path, e.code, e.read()[:400]))


q = urllib.parse.quote


def main():
	for dt, want in FIELDS.items():
		meta = api("GET", "/api/method/frappe.desk.form.load.getdoctype?doctype=" + q(dt))
		have = {f["fieldname"] for d in meta["docs"] for f in d.get("fields", [])}
		missing = [f for f in want if f not in have]
		print(dt, "fields missing:" if missing else "fields ok", missing or "")
	# Our own fields: added when missing, never changed once there.
	for f in json.load(open(os.path.join(HERE, "custom_fields.json"), encoding="utf-8"))["fields"]:
		name = "%s-%s" % (f["dt"], f["fieldname"])
		if api("GET", "/api/resource/Custom%20Field?filters=" + q(json.dumps([["name", "=", name]])))["data"]:
			print("field ok", name)
		else:
			api("POST", "/api/resource/Custom%20Field", f)
			print("field added", name)
	# The role's extra rights: added when missing, never changed once there. Only for a doctype
	# whose permissions are ALREADY custom rows - the first custom row switches the standard ones off.
	for perm in json.load(open(os.path.join(HERE, "custom_fields.json"), encoding="utf-8")).get("docperms", []):
		rows = api("GET", "/api/resource/Custom%20DocPerm?limit_page_length=0&fields=" + q(json.dumps(["name", "role", "permlevel"])) +
			"&filters=" + q(json.dumps([["parent", "=", perm["parent"]]])))["data"]
		if not rows:
			print("permission NOT added: %s has no custom permission rows - adding one would switch its standard rows off; do it by hand" % perm["parent"])
		elif any(r["role"] == perm["role"] and int(r["permlevel"]) == perm["permlevel"] for r in rows):
			print("permission ok", perm["parent"], perm["role"])
		else:
			api("POST", "/api/resource/Custom%20DocPerm", dict(perm, parenttype="DocType", parentfield="permissions"))
			print("permission added", perm["parent"], perm["role"])
	roles = {r["name"] for r in api("GET", "/api/resource/Role?limit_page_length=0")["data"]}
	print("role SAP Sync Bot", "exists" if "SAP Sync Bot" in roles else "MISSING")
	for name in SCRIPTS:
		src = open(os.path.join(HERE, name + ".py"), encoding="utf-8").read()
		doc = {"script_type": "API", "api_method": name, "script": src, "disabled": 0}
		got = api("GET", "/api/resource/Server%20Script?filters=" + q(json.dumps([["name", "=", name]])))["data"]
		if got:
			api("PUT", "/api/resource/Server%20Script/" + q(name), doc)
			print("updated", name)
		else:
			api("POST", "/api/resource/Server%20Script", dict(doc, name=name, __newname=name))
			print("created", name)


if __name__ == "__main__":
	main()
