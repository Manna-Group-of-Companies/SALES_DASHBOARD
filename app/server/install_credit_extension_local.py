# Temporary credit extensions (16 Nov 2026) on the LOCAL ERPNext (127.0.0.1:8000)
# only: the Manna Credit Extension doctypes (child tables first) and the
# manna_credit_extension Server Script.
#   python install_credit_extension_local.py
# Reads the local API key from Manna_CMMS/server/.env (MANNA_CMMS_DIR) and
# refuses any other host. The live site gets the same three things by hand,
# each with the user's go-ahead.
import json, os, sys, urllib.parse, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
ENV = os.path.join(os.environ.get("MANNA_CMMS_DIR") or os.path.join(HERE, "..", "..", "..", "Manna_CMMS"), "server", ".env")
env = dict(l.strip().split("=", 1) for l in open(ENV, encoding="utf-8") if "=" in l and not l.startswith("#"))
URL = env["ERPNEXT_URL"].rstrip("/")
if URL not in ("http://127.0.0.1:8000", "http://localhost:8000"):
	sys.exit("refusing: ERPNEXT_URL is %s, not the local site" % URL)
AUTH = "token %s:%s" % (env["ERPNEXT_API_KEY"], env["ERPNEXT_API_SECRET"])
q = urllib.parse.quote
NAME = "manna_credit_extension"


def api(method, path, body=None):
	req = urllib.request.Request(URL + path, method=method, data=json.dumps(body).encode() if body is not None else None,
		headers={"Authorization": AUTH, "Content-Type": "application/json", "Accept": "application/json"})
	try:
		return json.load(urllib.request.urlopen(req, timeout=60))
	except urllib.error.HTTPError as e:
		raise SystemExit("%s %s -> %s %s" % (method, path, e.code, e.read()[:600]))


def main():
	spec = json.load(open(os.path.join(HERE, "credit_extension_doctypes.json"), encoding="utf-8"))
	for dt in spec["doctypes"]:
		if api("GET", "/api/resource/DocType?filters=" + q(json.dumps([["name", "=", dt["name"]]])))["data"]:
			doc = api("GET", "/api/resource/DocType/" + q(dt["name"]))["data"]
			have = {f["fieldname"] for f in doc["fields"]}
			add = [f for f in dt["fields"] if f["fieldname"] not in have]
			if add:
				api("PUT", "/api/resource/DocType/" + q(dt["name"]), {"fields": doc["fields"] + add})
				print("doctype", dt["name"], "fields added", [f["fieldname"] for f in add])
			else:
				print("doctype ok", dt["name"])
		else:
			api("POST", "/api/resource/DocType", dt)
			print("doctype created", dt["name"])
	# A field on a doctype of our own is added to the doctype itself, without
	# the custom_ prefix (app/CLAUDE.md, landmines).
	for single in spec.get("single_fields", []):
		path = "/api/resource/DocType/" + q(single["doctype"])
		doc = api("GET", path)["data"]
		if not doc.get("custom"):
			sys.exit("refusing: %s is not a custom doctype here; its field would need a Custom Field" % single["doctype"])
		have = {f["fieldname"] for f in doc["fields"]}
		add = [f for f in single["fields"] if f["fieldname"] not in have]
		if add:
			api("PUT", path, {"fields": doc["fields"] + add})
			print("fields added to", single["doctype"], [f["fieldname"] for f in add])
		else:
			print("fields ok", single["doctype"])
	src = open(os.path.join(HERE, "credit_extension.py"), encoding="utf-8").read()
	doc = {"script_type": "API", "api_method": NAME, "script": src, "disabled": 0}
	if api("GET", "/api/resource/Server%20Script?filters=" + q(json.dumps([["name", "=", NAME]])))["data"]:
		api("PUT", "/api/resource/Server%20Script/" + q(NAME), doc)
		print("updated", NAME)
	else:
		api("POST", "/api/resource/Server%20Script", dict(doc, name=NAME, __newname=NAME))
		print("created", NAME)


if __name__ == "__main__":
	main()
