# Post a B1iF-shaped customer batch to the LOCAL manna_sap_customers, the way B1iF will.
#   python try_local.py            dry run
#   python try_local.py --write    writes (local only), then deletes the test customer it made
import json, sys, urllib.request, urllib.error
from install_local import URL, AUTH, api

existing = api("GET", "/api/resource/Customer?fields=" + urllib.parse.quote('["name","custom_bp_code","custom_phone"]') +
	"&filters=" + urllib.parse.quote('[["custom_bp_code","like","C-%"]]') + "&limit_page_length=1")["data"][0]
rows = [
	{"code": existing["custom_bp_code"], "name": existing["name"], "active": "Y", "sales_employee": "PRASHANTH", "phone": existing.get("custom_phone") or "", "address": "", "state": "", "gstin": ""},
	{"code": "C-999999", "name": "B1IF TEST CUSTOMER - DELETE ME", "active": "Y", "sales_employee": "PRASHANTH", "phone": "9995133846 / 1", "address": "Main Rd, Kochi, Kerala, 682001, IN", "state": "Kerala", "gstin": ""},
	{"code": "C-999998", "name": "B1IF TEST UNMAPPED", "active": "Y", "sales_employee": "SHOP SALE"},
]
write = "--write" in sys.argv
r = api("POST", "/api/method/manna_sap_customers", {"customers": rows, "dry_run": 0 if write else 1})["message"]
print(json.dumps(r, indent=1))
if write:
	made = [p["name"] for p in r["results"] if p["action"] == "create"]
	for n in made:
		api("DELETE", "/api/resource/Customer/" + urllib.parse.quote(n))
		print("deleted test customer", n)
