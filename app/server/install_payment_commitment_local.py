# The 10-day payment commitment ladder (17 Nov 2026) on the LOCAL ERPNext
# (127.0.0.1:8000) only: the Manna Payment Commitment doctypes (child first)
# and its three Server Scripts - the API, the Sales Order backstop and the
# hourly tracker.
#   python install_payment_commitment_local.py
# Reads the local API key from Manna_CMMS/server/.env (MANNA_CMMS_DIR) and
# refuses any other host. The live site gets the same, by hand, with the
# user's go-ahead. Needs the credit extension's settings doctype
# (install_credit_extension_local.py): the authority and the cap live there.
import json, os, sys, urllib.parse, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
ENV = os.path.join(os.environ.get("MANNA_CMMS_DIR") or os.path.join(HERE, "..", "..", "..", "Manna_CMMS"), "server", ".env")
env = dict(l.strip().split("=", 1) for l in open(ENV, encoding="utf-8") if "=" in l and not l.startswith("#"))
URL = env["ERPNEXT_URL"].rstrip("/")
if URL not in ("http://127.0.0.1:8000", "http://localhost:8000"):
	sys.exit("refusing: ERPNEXT_URL is %s, not the local site" % URL)
AUTH = "token %s:%s" % (env["ERPNEXT_API_KEY"], env["ERPNEXT_API_SECRET"])
q = urllib.parse.quote

SCRIPTS = [
	("manna_payment_commitment", {"script_type": "API", "api_method": "manna_payment_commitment"}, "payment_commitment.py"),
	("manna_payment_commitment_order", {"script_type": "DocType Event", "reference_doctype": "Sales Order",
	                                    "doctype_event": "Before Save"}, "payment_commitment_order.py"),
	("manna_payment_commitment_watch", {"script_type": "Scheduler Event", "event_frequency": "Cron",
	                                    "cron_format": "15 * * * *"}, "payment_commitment_watch.py"),
]


def api(method, path, body=None):
	req = urllib.request.Request(URL + path, method=method, data=json.dumps(body).encode() if body is not None else None,
		headers={"Authorization": AUTH, "Content-Type": "application/json", "Accept": "application/json"})
	try:
		return json.load(urllib.request.urlopen(req, timeout=60))
	except urllib.error.HTTPError as e:
		raise SystemExit("%s %s -> %s %s" % (method, path, e.code, e.read()[:600]))


def main():
	spec = json.load(open(os.path.join(HERE, "payment_commitment_doctypes.json"), encoding="utf-8"))
	for dt in spec["doctypes"]:
		if api("GET", "/api/resource/DocType?filters=" + q(json.dumps([["name", "=", dt["name"]]])))["data"]:
			doc = api("GET", "/api/resource/DocType/" + q(dt["name"]))["data"]
			have = {f["fieldname"]: f for f in doc["fields"]}
			add = [f for f in dt["fields"] if f["fieldname"] not in have]
			fields = doc["fields"]
			# A Select's options may grow (Pending was added to status).
			for f in dt["fields"]:
				h = have.get(f["fieldname"])
				if h and f.get("options") and h.get("options") != f["options"]:
					h["options"] = f["options"]
					if "default" in f:
						h["default"] = f["default"]
			api("PUT", "/api/resource/DocType/" + q(dt["name"]), {"fields": fields + add})
			print("doctype", dt["name"], "updated", [f["fieldname"] for f in add])
		else:
			api("POST", "/api/resource/DocType", dt)
			print("doctype created", dt["name"])
	for name, base, path in SCRIPTS:
		doc = dict(base, script=open(os.path.join(HERE, path), encoding="utf-8").read(), disabled=0)
		if api("GET", "/api/resource/Server%20Script?filters=" + q(json.dumps([["name", "=", name]])))["data"]:
			api("PUT", "/api/resource/Server%20Script/" + q(name), doc)
			print("updated", name)
		else:
			api("POST", "/api/resource/Server%20Script", dict(doc, name=name, __newname=name))
			print("created", name)


if __name__ == "__main__":
	main()
