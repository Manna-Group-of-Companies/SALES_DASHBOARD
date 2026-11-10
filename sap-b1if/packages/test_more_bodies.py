# Posts each out/Z.erpmore/<step>/body.json that Test-More.ps1 wrote to the LOCAL
# ERPNext, exactly as B1if's HTTP call will. The bodies carry dry_run 1.
import json, os, sys
sys.stdout.reconfigure(encoding="utf-8")
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "erpnext"))
from install_local import api

ROOT = os.path.join(HERE, "out", "Z.erpmore")
SHOW = ("count", "counts", "written", "differs_total", "matched", "changed", "to_create", "to_update", "to_delete", "deletes_held",
	"no_customer", "left_for_next_run", "refused", "items", "twins", "customers", "special_prices", "properties", "kb")
for s in json.load(open(os.path.join(ROOT, "manifest.json"))):
	raw = open(os.path.join(ROOT, s["step"], "body.json"), encoding="utf-8").read()
	body = json.loads(raw)   # fails here if atom3 wrote bad JSON
	assert body["dry_run"] == 1, s["step"]
	m = api("POST", "/api/method/manna_sap_in", body)["message"]
	print("%-13s %-9s %7d bytes -> %s" % (s["step"], body["kind"], len(raw), {k: m[k] for k in SHOW if k in m}))
