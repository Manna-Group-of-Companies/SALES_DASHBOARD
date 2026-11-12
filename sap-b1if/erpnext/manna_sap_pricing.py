# Frappe Server Script
#   Name          : manna_sap_pricing
#   Script Type   : API
#   API Method    : manna_sap_pricing
#   Body (POST)   : JSON {"mt": [[k, c01..c14], ...], "ht": [[k, c01..c11], ...], "dry_run": 0|1}
#
# The SAP price snapshot in SAP Pricing Control (snapshot_json, snapshot_items,
# snapshot_special_prices), a port of sap-pricing/Sync-SapPricingSnapshot.ps1 with
# RupeeRules.ps1, so the phone (manna_customer_rates) and the rates dashboard
# read exactly what they read today: version 3, the same keys, the same values.
# B1iF's pricing package posts two result sets - Manna Treads' and Hi-Tech's
# (../pricing/*.sql say what each row kind holds) - and everything is decided here:
#
#   - "named" item properties are the price groups: any property whose name is
#     not SAP's placeholder "Items Property <n>". An item is in the snapshot when
#     it has at least one of them ticked (the query already asks for active items),
#     or (11 Nov 2026) when it sits in item group HOT or PRECURED and its quality
#     picks one: the item group gives the type, the name - else U_SubTypeA - the
#     quality ("Hot - Black Pearl"). One that cannot be placed is listed under
#     "ungrouped" with why. The port of sap-pricing/AutoGroups.ps1; both read
#     shared/fixtures/price_groups.json.
#   - on test companies only (neither database *_LIVE), an item with no Price
#     List 01 price gets its group's median (its type's when the group has none)
#     as a stand-in, listPriceSource "placeholder", so the screen can be tried.
#   - an item's twin is Hi-Tech's item of the SAME code, when its name is the
#     same (case and spacing aside) and it is active; the roll figures are the twin's.
#   - prices are stored as SAP holds them (GST-inclusive, no margin applied). A
#     Manna price of 0 is 0; a Hi-Tech price of 0 is "none" - the script's own asymmetry.
#   - serverCheck counts how many dealer and Hi-Tech prices agree with the dealer
#     rules (SAP Dealer Rate Rule) and the inter-company margin; the dashboard
#     compares it with its own count, so the rounding (half away from zero) and
#     the "card|property|rupees" strings must match the script's.
#
# Not written: the run stamps (status, last_sync_at, ...) - the old poller owns
# them while it still runs. An empty Manna result set writes nothing (the script
# would have failed before writing; an empty snapshot would blank every price).
#
# Callers: System Manager or the "SAP Sync Bot" role.

CONTROL = "SAP Pricing Control"
RULES = "SAP Dealer Rate Rule"
PRICE_LIST = 1
COMPANY_NAME = {"mt": "Manna Treads", "ht": "Hi-Tech Pretreads"}
KIND_LABEL = {"PCTR": "PRECURED", "HOT": "HOT", "BONDING GUM": "BONDING GUM"}


def norm(s):
	return " ".join(str(s or "").split()).upper()


def num(v):
	try:
		return float(v or 0)
	except Exception:
		return 0.0


def tidy(x):
	# A whole number as an int, so the JSON reads 200 and not 200.0.
	return int(x) if x == int(x) else x


def round_money(x):
	# 2 places, half AWAY from zero (146.525 -> 146.53), as the script rounds through decimal.
	v = abs(num(x))
	r = int(v * 100 + 0.5 + 0.000000001) / 100.0
	return -r if num(x) < 0 else r


def rupees_text(x):
	r = round_money(x)
	if r == int(r):
		return str(int(r))
	return ("%.2f" % r).rstrip("0")


def words(name):
	out = ""
	for ch in name:
		out = out + (ch if (ch.isalnum() or ch == "_") else " ")
	return out.split()


def item_kind(name_upper):
	w = words(name_upper)
	if "GUM" in w:
		return "BONDING GUM"
	if "PRECURED" in name_upper or "PCTR" in w:
		return "PCTR"
	if "HOT" in w:
		return "HOT"
	return "OTHER"


def is_placeholder(name):
	n = str(name or "").lower()
	return n.startswith("items property ") and n[len("items property "):].isdigit()


# Quality from text with every space removed - no `re` in a Server Script, and
# AutoGroups.ps1 matches the same way. "POLYCOLD" is U_SubTypeA's Polygold.
# Lists of dicts, not tuples: safe_exec allows no unpacking (README, "Traps").
QUALITY_WORDS = [{"q": "BLACK PEARL", "words": ["BLACKPEARL"]}, {"q": "PLATINUM", "words": ["PLATINUM", "PLATNIUM"]},
	{"q": "POLYGOLD", "words": ["POLYGOLD", "POLYCOLD"]}, {"q": "SILVER", "words": ["SILVER"]}, {"q": "DIAMOND", "words": ["DIAMOND", "DAIMOND"]}]


def quality_from_text(text):
	t = "".join(str(text or "").upper().split())
	found = []
	for e in QUALITY_WORDS:
		for w in e["words"]:
			if w in t and e["q"] not in found:
				found.append(e["q"])
	if not found:
		return ""
	return found[0] if len(found) == 1 else "MULTI"


def type_from_item_group(name):
	g = str(name or "").strip().upper()
	if g == "HOT":
		return "HOT"
	if g in ("PRECURED", "PCTR"):
		return "PCTR"
	return ""


def split_group_name(name):
	n = str(name or "")
	i = n.find("-")
	if i < 0:
		return None
	t = type_from_item_group(n[:i])
	q = quality_from_text(n[i + 1:])
	if not t or not q or q == "MULTI":
		return None
	return t + "|" + q


def auto_group(name, sub_type, item_group, props):
	"""{"no": property no or None, "why": why not} for an item with no property ticked."""
	t = type_from_item_group(item_group)
	if not t:
		return {"no": None, "why": "item group %s is not HOT or PRECURED" % item_group}
	by_name = quality_from_text(name)
	by_sub = quality_from_text(sub_type)
	if by_name == "MULTI":
		return {"no": None, "why": "the name names more than one quality"}
	if by_name and by_sub and by_sub != "MULTI" and by_name != by_sub:
		return {"no": None, "why": "the name says %s, U_SubTypeA says %s" % (by_name, sub_type)}
	q = by_name or (by_sub if by_sub != "MULTI" else "")
	if not q:
		return {"no": None, "why": "neither the name nor U_SubTypeA names a quality"}
	for p in props:
		if split_group_name(p["name"]) == t + "|" + q:
			return {"no": p["no"], "why": ""}
	return {"no": None, "why": "no group is named for %s %s" % (t, q)}


def median_price(prices):
	p = sorted([num(x) for x in prices if num(x) > 0])
	if not p:
		return None
	mid = len(p) // 2
	m = p[mid] if len(p) % 2 else (p[mid - 1] + p[mid]) / 2.0
	return int(m + 0.5)


def stand_in_companies(treads_db, hitech_db):
	for d in (treads_db, hitech_db):
		u = str(d or "").strip().upper()
		if not u or u.endswith("_LIVE"):
			return False
	return True


def rows_of(batch, kind):
	return [list(r[1:]) + [""] * 14 for r in batch if r and str(r[0]) == kind]


def build(mt, ht, rules, margin, now):
	"""Pure: the snapshot dict, from the two result sets, the dealer rules
	([{card, property, rupees}]) and the inter-company margin."""
	db_mt = (rows_of(mt, "D") or [[""]])[0][0]
	db_ht = (rows_of(ht, "D") or [[""]])[0][0]
	pl_mt = (rows_of(mt, "L") or [["1", ""]])[0]
	pl_ht = (rows_of(ht, "L") or [["1", ""]])[0]
	props = sorted([{"no": int(num(r[0])), "name": r[1]} for r in rows_of(mt, "P") if not is_placeholder(r[1])], key=lambda p: p["no"])
	named = [p["no"] for p in props]
	hitech = {}
	for r in rows_of(ht, "H"):
		hitech.setdefault(str(r[0]).lower(), r)
	items = []
	twins = []
	ungrouped = []
	for r in sorted(rows_of(mt, "I"), key=lambda r: str(r[0])):
		code = str(r[0])
		name = str(r[1])
		flags = str(r[13])
		ticked = [n for n in named if n <= len(flags) and flags[n - 1] == "Y"]
		source = "ticked"
		if not ticked:
			g = auto_group(name, r[8], r[3], props)
			if g["no"] is None:
				ungrouped.append({"code": code, "name": name, "groupName": r[3], "subType": r[8], "reason": g["why"]})
				continue
			ticked = [g["no"]]
			source = "auto"
		h = hitech.get(code.lower())
		twin = None
		note = None
		belts = None
		weight = None
		if h:
			if norm(h[1]) != norm(name):
				note = "Hi-Tech's %s is a different item: %s" % (code, h[1])
			elif h[2] != "Y":
				note = "Hi-Tech's %s is inactive" % code
			else:
				twin = code
				belts = int(num(h[7])) if h[7] != "" else None
				weight = num(h[8]) if h[8] != "" else None
				hp = num(h[9])
				twins.append({"code": str(h[0]), "name": h[1], "listPrice": tidy(hp) if (h[9] != "" and hp > 0) else None, "currency": h[10] if h[9] != "" else "",
					"stock": tidy(num(h[6])), "sales": h[4] == "Y", "frozen": h[3] == "Y", "updated": str(h[5])[:10]})
		items.append({"code": code, "name": name, "group": int(num(r[2])), "groupName": r[3] or None,
			"type": KIND_LABEL.get(item_kind(norm(name)), ""), "quality": r[8], "uom": r[7] if str(r[7]).strip() else r[6],
			"beltsPerRoll": belts, "weightPerRoll": weight, "stock": tidy(num(r[10])), "sales": r[4] == "Y", "frozen": r[5] == "Y",
			"updated": str(r[9])[:10], "props": ticked, "groupSource": source,
			"listPrice": tidy(num(r[11])) if r[11] != "" else None, "listPriceSource": "sap" if num(r[11]) > 0 else "none",
			"currency": r[12] if r[11] != "" else "", "twin": twin, "twinNote": note})
	stand_ins = stand_in_companies(db_mt, db_ht)
	if stand_ins:
		type_of = {}
		for p in props:
			g = split_group_name(p["name"])
			type_of[p["no"]] = g.split("|")[0] if g else ""
		for p in props:
			mine = [i for i in items if p["no"] in i["props"]]
			m = median_price([i["listPrice"] for i in mine if i["listPriceSource"] == "sap"])
			if m is None and type_of[p["no"]]:
				m = median_price([i["listPrice"] for i in items if i["listPriceSource"] == "sap" and type_of.get(i["props"][0]) == type_of[p["no"]]])
			if m is None:
				continue
			for i in mine:
				if i["listPriceSource"] == "none":
					i["listPrice"] = m
					i["listPriceSource"] = "placeholder"
					i["currency"] = "INR"
	customers = [{"code": r[0], "name": r[1], "group": r[2] or None, "priceList": int(num(r[3])), "active": r[4] == "Y" and r[5] != "Y"}
		for r in rows_of(mt, "C")]
	special = [[r[1], r[0], tidy(num(r[2])), int(num(r[5])), 1 if r[6] == "Y" else 0, tidy(num(r[4])), 0 if r[7] == "N" else 1, r[3]]
		for r in rows_of(mt, "S")]
	snap = {"version": 3, "company": db_mt, "companyName": COMPANY_NAME["mt"],
		"priceList": {"no": int(num(pl_mt[0])), "name": pl_mt[1]}, "syncedAt": now, "properties": props, "items": items, "customers": customers,
		"specialCols": ["card", "item", "price", "priceList", "autoUpdate", "discount", "valid", "currency"], "specialRows": special,
		"hitech": {"company": db_ht, "companyName": COMPANY_NAME["ht"], "priceList": {"no": int(num(pl_ht[0])), "name": pl_ht[1]}, "items": twins},
		"serverCheck": check(items, twins, special, rules, margin), "ungrouped": ungrouped, "placeholderPrices": stand_ins}
	return snap


def check(items, twins, special, rules, margin):
	"""Pure: the script's Get-RatesCheck."""
	sp = {}
	for s in special:
		sp[(str(s[0]) + "|" + str(s[1])).lower()] = s
	ht = {}
	for t in twins:
		ht[str(t["code"]).lower()] = t
	dealer = {"OK": 0, "DRIFT": 0, "MISSING": 0, "KIND": 0}
	hi = {"OK": 0, "DRIFT": 0, "MISSING": 0}
	no_twin = 0
	conflicts = 0
	refused = 0
	cards = []
	for r in rules:
		if str(r["card"]).lower() not in [c.lower() for c in cards]:
			cards.append(str(r["card"]))
	for card in cards:
		mine = [r for r in rules if str(r["card"]).lower() == card.lower()]
		for it in items:
			hit = [r for r in mine if int(r["property"]) in it["props"]]
			if not hit:
				continue
			if len(hit) > 1:
				conflicts = conflicts + 1
			lst = num(it["listPrice"])
			rup = num(hit[0]["rupees"])
			want = round_money(lst - rup)
			if lst <= 0 or rup <= 0 or want <= 0:
				refused = refused + 1
				continue
			row = sp.get((card + "|" + it["code"]).lower())
			if row is None or row[6] != 1:
				dealer["MISSING"] = dealer["MISSING"] + 1
			elif row[3] != 0:
				dealer["KIND"] = dealer["KIND"] + 1
			elif abs(num(row[2]) - want) > 0.004:
				dealer["DRIFT"] = dealer["DRIFT"] + 1
			else:
				dealer["OK"] = dealer["OK"] + 1
	m = num(margin)
	for it in items:
		t = ht.get(str(it["twin"] or "").lower()) if it["twin"] else None
		if t is None:
			no_twin = no_twin + 1
			continue
		if m <= 0:
			continue
		lst = num(it["listPrice"])
		want = round_money(lst - m)
		if lst <= 0 or want <= 0:
			refused = refused + 1
			continue
		now_price = num(t["listPrice"])
		if t["listPrice"] is None or now_price <= 0:
			hi["MISSING"] = hi["MISSING"] + 1
		elif abs(now_price - want) <= 0.004:
			hi["OK"] = hi["OK"] + 1
		else:
			hi["DRIFT"] = hi["DRIFT"] + 1
	return {"margin": tidy(round_money(m)) if m > 0 else None,
		"rules": ["%s|%d|%s" % (r["card"], int(r["property"]), rupees_text(r["rupees"])) for r in rules],
		"dealer": dealer, "hitech": hi, "noTwin": no_twin, "conflicts": conflicts, "refused": refused}


def run():
	user = frappe.session.user
	allowed = user == "Administrator" or bool(frappe.get_all("Has Role",
		filters={"parent": user, "parenttype": "User", "role": ["in", ["System Manager", "SAP Sync Bot"]]}, limit=1))
	if not allowed:
		frappe.throw("Only the SAP sync user may post the price snapshot.")
	body = frappe.form_dict
	mt = body.get("mt")
	ht = body.get("ht")
	if isinstance(mt, str):
		mt = frappe.parse_json(mt)
	if isinstance(ht, str):
		ht = frappe.parse_json(ht)
	if not isinstance(mt, list) or not isinstance(ht, list):
		frappe.throw("mt and ht must be lists.")
	dry = frappe.utils.cint(body.get("dry_run")) == 1
	refused = ""
	if not rows_of(mt, "D") or not rows_of(mt, "C"):
		refused = "Manna Treads' result set is empty or has no customers - nothing changed"
	elif not rows_of(ht, "D"):
		refused = "Hi-Tech's result set is empty - nothing changed"
	rules = [{"card": r.card_code, "property": frappe.utils.cint(r.property_no), "rupees": num(r.rupees_off)}
		for r in frappe.get_all(RULES, fields=["card_code", "property_no", "rupees_off"], limit_page_length=0)]
	margin = num(frappe.db.get_single_value(CONTROL, "intercompany_margin"))
	snap = build(mt, ht, rules, margin, str(frappe.utils.now())[:19])
	text = json.dumps(snap, separators=(",", ":"))
	if not dry and not refused:
		frappe.db.set_value(CONTROL, None, {"snapshot_json": text, "snapshot_items": len(snap["items"]), "snapshot_special_prices": len(snap["specialRows"])})
	c = snap["serverCheck"]
	wrong = c["dealer"]["DRIFT"] + c["dealer"]["MISSING"] + c["dealer"]["KIND"] + c["hitech"]["DRIFT"] + c["hitech"]["MISSING"]
	frappe.response["message"] = {"dry_run": dry, "refused": refused, "company": snap["company"], "hitech_company": snap["hitech"]["company"],
		"properties": len(snap["properties"]), "items": len(snap["items"]), "ungrouped": len(snap["ungrouped"]),
		"auto_grouped": len([i for i in snap["items"] if i["groupSource"] == "auto"]),
		"stand_ins": len([i for i in snap["items"] if i["listPriceSource"] == "placeholder"]), "twins": len(snap["hitech"]["items"]), "customers": len(snap["customers"]),
		"special_prices": len(snap["specialRows"]), "kb": int(len(text) / 1024), "serverCheck": c,
		"summary": "SAP prices read: %d groups, %d Manna Treads items (%d grouped by item group and quality, %d left out; %d with a Hi-Tech twin%s), %d customers, %d special prices. Check: %d dealer price(s) and %d Hi-Tech price(s) right, %d not." % (
			len(snap["properties"]), len(snap["items"]), len([i for i in snap["items"] if i["groupSource"] == "auto"]), len(snap["ungrouped"]), len(snap["hitech"]["items"]),
			("; %d with a stand-in price" % len([i for i in snap["items"] if i["listPriceSource"] == "placeholder"])) if snap["placeholderPrices"] else "",
			len(snap["customers"]), len(snap["specialRows"]), c["dealer"]["OK"], c["hitech"]["OK"], wrong)}


if not frappe.flags.get("manna_test"):
	run()
