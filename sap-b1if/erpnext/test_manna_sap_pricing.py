# Offline: the price snapshot's rules in manna_sap_pricing.py (a port of
# Sync-SapPricingSnapshot.ps1 + RupeeRules.ps1), without a site.
import json
import os
import types

HERE = os.path.dirname(__file__)
ns = {"frappe": types.SimpleNamespace(flags={"manna_test": True}), "json": json}
exec(open(os.path.join(HERE, "manna_sap_pricing.py"), encoding="utf-8").read(), ns)
build, round_money, rupees_text, item_kind = ns["build"], ns["round_money"], ns["rupees_text"], ns["item_kind"]


def flags(*ticked):
	return "".join("Y" if n in ticked else "N" for n in range(1, 65))


def item(code="PMB1", name="PCTR MANNA BLUE VIKING 205", price="200.000000", ticked=(6,), **kw):
	r = ["I", code, name, "116", "FG", "Y", "N", "KGS", "", "PLATINUM", "2026-11-09", "0.000000", price, "INR", flags(*ticked)]
	for k, v in kw.items():
		r[k] = v
	return r


def hitem(code="PMB1", name="PCTR MANNA BLUE VIKING 205", valid="Y", price="190.000000"):
	return ["H", code, name, valid, "N", "Y", "2026-11-09", "121.000000", "3", "20.000000", price, "INR"]


MT = [["D", "MANNA_TREADS_LIVE"], ["L", "1", "selling price"], ["P", "6", "Precured - Platinum"], ["P", "7", "Items Property 7"],
	["C", "C-1001", "Aman Tyres", "Sales - Cinto", "1", "Y", "N"]]
HT = [["D", "HITECH_PRETREADS_LIVE"], ["L", "1", "Price List 01"]]


def snap(mt_extra=(), ht_extra=(), rules=(), margin=10):
	return build(MT + list(mt_extra), HT + list(ht_extra), list(rules), margin, "2026-11-10 12:00:00")


def test_only_properties_somebody_named_are_price_groups():
	assert snap()["properties"] == [{"no": 6, "name": "Precured - Platinum"}]


def test_an_item_is_in_the_snapshot_only_with_a_named_property_ticked():
	s = snap([item(), item(code="X2", ticked=(7,))])
	assert [i["code"] for i in s["items"]] == ["PMB1"] and s["items"][0]["props"] == [6]


def test_a_twin_is_hitechs_item_of_the_same_code_and_name_and_gives_the_roll_figures():
	s = snap([item()], [hitem(name="pctr  manna blue VIKING 205")])
	i = s["items"][0]
	assert i["twin"] == "PMB1" and i["twinNote"] is None and i["beltsPerRoll"] == 3 and i["weightPerRoll"] == 20.0
	assert s["hitech"]["items"][0]["listPrice"] == 190 and i["type"] == "PRECURED"


def test_a_different_name_or_an_inactive_item_at_hitech_is_no_twin_and_says_why():
	a = snap([item()], [hitem(name="SOMETHING ELSE")])["items"][0]
	b = snap([item()], [hitem(valid="N")])["items"][0]
	c = snap([item()])["items"][0]
	assert a["twin"] is None and "different item" in a["twinNote"]
	assert b["twin"] is None and b["twinNote"] == "Hi-Tech's PMB1 is inactive"
	assert c["twin"] is None and c["twinNote"] is None and c["weightPerRoll"] is None


def test_a_manna_price_of_zero_is_zero_but_a_hitech_price_of_zero_is_none():
	s = snap([item(price="0.000000")], [hitem(price="0.000000")])
	assert s["items"][0]["listPrice"] == 0 and s["hitech"]["items"][0]["listPrice"] is None


def test_the_hitech_check_counts_a_twin_priced_at_list_less_the_margin_as_ok():
	assert snap([item()], [hitem()])["serverCheck"]["hitech"] == {"OK": 1, "DRIFT": 0, "MISSING": 0}
	assert snap([item()], [hitem(price="191.000000")])["serverCheck"]["hitech"]["DRIFT"] == 1
	assert snap([item()], [hitem(price="0.000000")])["serverCheck"]["hitech"]["MISSING"] == 1
	assert snap([item()])["serverCheck"]["noTwin"] == 1


def test_the_dealer_check_follows_the_rules_fixed_price_only():
	rule = [{"card": "C-1001", "property": 6, "rupees": 5}]
	ok = snap([item(), ["S", "PMB1", "c-1001", "195.000000", "INR", "0.000000", "0", "N", "Y"]], rules=rule)["serverCheck"]
	kind = snap([item(), ["S", "PMB1", "C-1001", "195.000000", "INR", "0.000000", "1", "N", "Y"]], rules=rule)["serverCheck"]
	drift = snap([item(), ["S", "PMB1", "C-1001", "196.000000", "INR", "0.000000", "0", "N", "Y"]], rules=rule)["serverCheck"]
	off = snap([item(), ["S", "PMB1", "C-1001", "195.000000", "INR", "0.000000", "0", "N", "N"]], rules=rule)["serverCheck"]
	none = snap([item()], rules=rule)["serverCheck"]
	assert ok["dealer"]["OK"] == 1 and kind["dealer"]["KIND"] == 1 and drift["dealer"]["DRIFT"] == 1
	assert off["dealer"]["MISSING"] == 1 and none["dealer"]["MISSING"] == 1 and ok["rules"] == ["C-1001|6|5"]


def test_a_rule_that_would_price_at_or_below_zero_is_refused_and_two_rules_on_one_item_conflict():
	assert snap([item(price="4.000000")], rules=[{"card": "C-1001", "property": 6, "rupees": 5}])["serverCheck"]["refused"] == 1
	two = [{"card": "C-1001", "property": 6, "rupees": 5}, {"card": "C-1001", "property": 8, "rupees": 2}]
	mt = [["P", "8", "Hot - Silver"], item(ticked=(6, 8))]
	assert snap(mt, rules=two)["serverCheck"]["conflicts"] == 1


def test_money_rounds_half_away_from_zero_and_rupees_print_as_the_dashboard_prints_them():
	assert round_money(146.525) == 146.53 and round_money(-146.525) == -146.53
	assert rupees_text(5) == "5" and rupees_text(8.5) == "8.5" and rupees_text(8.456) == "8.46"


def test_special_rows_keep_their_positions_and_integer_flags():
	s = snap([["S", "I-1001", "C-1001", "205.000000", "INR", "3.240000", "1", "Y", "Y"]])
	assert s["specialCols"] == ["card", "item", "price", "priceList", "autoUpdate", "discount", "valid", "currency"]
	assert s["specialRows"] == [["C-1001", "I-1001", 205, 1, 1, 3.24, 1, "INR"]]


def test_the_item_kind_reads_whole_words():
	assert item_kind("BONDING GUM 220") == "BONDING GUM" and item_kind("TREAD RUBBER PRECURED X") == "PCTR"
	assert item_kind("TREAD RUBBER HOT BP") == "HOT" and item_kind("SHOTGUN") == "OTHER"


def test_the_snapshot_is_version_3_with_the_company_databases_named():
	s = snap()
	assert s["version"] == 3 and s["company"] == "MANNA_TREADS_LIVE" and s["hitech"]["company"] == "HITECH_PRETREADS_LIVE"
	assert s["customers"] == [{"code": "C-1001", "name": "Aman Tyres", "group": "Sales - Cinto", "priceList": 1, "active": True}]


# ---- price groups and stand-ins (11 Nov 2026): shared/fixtures/price_groups.json, which Test-AutoGroups.ps1 reads too ----
FX = json.load(open(os.path.join(HERE, "..", "..", "shared", "fixtures", "price_groups.json"), encoding="utf-8"))
auto_group, median_price, stand_in_companies = ns["auto_group"], ns["median_price"], ns["stand_in_companies"]


def test_price_groups_fixture():
	props = [{"no": p["no"], "name": p["name"]} for p in FX["properties"]]
	for c in FX["groups"]:
		g = auto_group(c["name"], c["subType"], c["itemGroup"], props)
		assert g["no"] == c["property"], c["why"]
		assert g["no"] is not None or g["why"], c["why"] + ": left out with no reason"


def test_stand_in_companies_fixture():
	for c in FX["standIns"]:
		assert stand_in_companies(c["treads"], c["hitech"]) == c["on"], c["why"]


def test_median_fixture():
	for c in FX["medians"]:
		assert median_price(c["prices"]) == c["median"], c["why"]


TEST_MT = [["D", "TEST_MANNA_TREADS"], ["L", "1", "selling price"], ["P", "1", "Hot - Black Pearl"], ["P", "6", "PCTR - Black Pearl"],
	["P", "10", "PCTR - Diamond"], ["C", "C-1001", "Aman Tyres", "Sales - Cinto", "1", "Y", "N"]]
TEST_HT = [["D", "TEST_HITECH_PRETREADS"], ["L", "1", "Price List 01"]]


def tread(code, name, group, price, sub="", ticked=()):
	r = item(code=code, name=name, price=price, ticked=ticked)
	r[4] = group
	r[9] = sub
	return r


def test_only_a_ticked_item_is_in_a_group_and_an_unticked_one_an_order_could_carry_is_listed():
	# 14 Nov 2026: the groups are the price list's rows and every new code is ticked; nothing is worked out from names.
	ht = TEST_HT + [hitem("A", "PCTR BLACK PEARL 205"), hitem("E", "SOMETHING ELSE")]
	s = build(TEST_MT + [tread("A", "PCTR BLACK PEARL 205", "PRECURED", "200.000000"), tread("B", "HOT MANNA DOUBLE BLUE 35", "HOT", ""),
		tread("D", "HOT X", "HOT", "190.000000", ticked=(1,)), tread("E", "PCTR BLACK PEARL 9", "PRECURED", "200.000000")], ht, [], 10, "now")
	assert [i["code"] for i in s["items"]] == ["D"] and s["items"][0]["groupSource"] == "ticked"
	assert [u["code"] for u in s["ungrouped"]] == ["A"] and "no price group is ticked" in s["ungrouped"][0]["reason"]
	# B has no Hi-Tech item, E's is another tread: Manna Treads' own codes, which no order can carry - counted only.
	assert s["ungroupedNoTwin"] == 2


def test_the_new_bonding_gum_names_read_as_bonding_gum():
	assert item_kind("BG MANNA 220 04") == "BONDING GUM" and item_kind("BG EXPORT VERDO 230 02") == "BONDING GUM"
	assert item_kind("PCTR MANNA DOUBLE BLUE ENDURA 115 82") == "PCTR" and item_kind("VULCANIZING SOLUTION MANNA 10") == "OTHER"


def test_hitech_keeps_no_price_list():
	# Its sales order is priced from Manna Treads' purchase order (B1iF, MARGIN): no Hi-Tech check, whatever the margin field says.
	assert ns["HITECH_PRICE_LIST"] is False


def test_a_test_company_gives_an_unpriced_item_its_groups_median_or_its_types():
	mt = TEST_MT + [tread("A", "PCTR BLACK PEARL 1", "PRECURED", "200.000000", ticked=(6,)), tread("B", "PCTR BLACK PEARL 2", "PRECURED", "211.000000", ticked=(6,)),
		tread("C", "PCTR BLACK PEARL 3", "PRECURED", "", ticked=(6,)), tread("Z", "PCTR BLACK PEARL 4", "PRECURED", "0.000000", ticked=(6,)),
		tread("D", "PCTR DIAMOND 1", "PRECURED", "", ticked=(10,))]
	s = build(mt, TEST_HT, [], 10, "now")
	by = {i["code"]: (i["listPrice"], i["listPriceSource"]) for i in s["items"]}
	assert s["placeholderPrices"] is True
	assert by["A"] == (200, "sap") and by["C"] == (206, "placeholder") and by["Z"] == (206, "placeholder")
	assert by["D"] == (206, "placeholder")


def test_live_never_gets_a_stand_in():
	s = build([r if r[0] != "D" else ["D", "MANNA_TREADS_LIVE"] for r in TEST_MT] + [tread("C", "PCTR BLACK PEARL 3", "PRECURED", "", ticked=(6,))], TEST_HT, [], 10, "now")
	assert s["placeholderPrices"] is False and s["items"][0]["listPrice"] is None and s["items"][0]["listPriceSource"] == "none"
