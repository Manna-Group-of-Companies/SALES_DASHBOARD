# Posts each out/<package>/body.json that Test-Packages.ps1 wrote to the LOCAL
# ERPNext, exactly as B1if's HTTP call will, and prints ERPNext's answer.
# The bodies carry dry_run 1, so nothing is written.
import json, os, sys
sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "erpnext"))
from install_local import api

for pkg in ("Z.erpcust", "Z.erpitem", "Z.erpstock", "Z.erpstatht", "Z.erpstatmt"):
	raw = open(os.path.join(HERE, "out", pkg, "body.json"), encoding="utf-8").read()
	body = json.loads(raw)   # fails here if atom3 wrote bad JSON
	assert body["dry_run"] == 1, pkg
	ep = "manna_sap_in"   # the one address B1if posts to; "kind" in the body picks the endpoint
	assert body["kind"] in ("customers", "items", "stock", "status"), pkg
	m = api("POST", "/api/method/" + ep, body)["message"]
	summary = {k: m[k] for k in ("count", "refused", "error", "changed", "orders_found", "notes_total") if k in m}
	print("%-11s %5d bytes -> %s %s" % (pkg, len(raw), ep, summary))
	for r in (m.get("results") or [])[:2]:
		print("            ", {k: r.get(k) for k in ("code", "action", "reason", "fields")})
