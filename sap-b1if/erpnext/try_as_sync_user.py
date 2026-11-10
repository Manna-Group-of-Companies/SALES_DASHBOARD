# Post to the LOCAL manna_sap_in AS THE SYNC USER (the key in .sapsync-local-key.txt),
# the way B1iF does - not as Administrator, who passes every permission check and so
# hides the ones the sync user fails (the stock submit, 10 Nov 2026).
#
#   python try_as_sync_user.py stock      one harmless stock line: +1 kg on an item, then back
import base64, json, os, sys, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
line = [l for l in open(os.path.join(HERE, ".sapsync-local-key.txt")) if l.startswith("Authorization:")][0]
AUTH = "Basic " + base64.b64encode(line.split(":", 1)[1].strip().split(" ", 1)[1].encode()).decode()


def post(body):
	req = urllib.request.Request("http://127.0.0.1:8000/api/method/manna_sap_in", data=json.dumps(body).encode(), method="POST",
		headers={"Authorization": AUTH, "Content-Type": "application/json", "Accept": "application/json"})
	return json.load(urllib.request.urlopen(req, timeout=120))["message"]


if sys.argv[1:] == ["stock"]:
	import urllib.parse as u
	from install_local import api   # the sync user may not read Bin; Administrator reads, the sync user posts
	bins = api("GET", "/api/resource/Bin?limit_page_length=0&fields=" + u.quote('["item_code","actual_qty"]') + "&filters=" + u.quote('[["warehouse","=","Finished Goods - MT"]]'))["data"]
	rows = [{"code": b["item_code"], "qty": b["actual_qty"]} for b in bins]
	first = next(r for r in rows if r["qty"] > 0)
	for label, delta in (("+1 kg", 1), ("back", 0)):
		batch = [dict(r, qty=r["qty"] + delta) if r is first else r for r in rows]
		m = post({"kind": "stock", "stock": batch})
		print(label, first["code"], {k: m[k] for k in ("dry_run", "refused", "error", "reconciliations", "changed")})
else:
	sys.exit("usage: python try_as_sync_user.py stock")
