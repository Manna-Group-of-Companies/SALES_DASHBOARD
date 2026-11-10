# Offline: the item rules in manna_sap_items.py, without a site.
import os
import types

HERE = os.path.dirname(__file__)
ns = {"frappe": types.SimpleNamespace(flags={"manna_test": True})}
exec(open(os.path.join(HERE, "manna_sap_items.py"), encoding="utf-8").read(), ns)
plan, shared_prefix = ns["plan"], ns["shared_prefix"]
GROUPS = {"FG", "HOT", "Bonding Gum", "Vulcanizing Solution"}
HSNS = {"40082940", "40059990"}


def row(**kw):
	r = {"code": "PMB00101002", "name": "PCTR MANNA BLUE VIKING 205 129 (PLATINUM)", "active": "Y", "uom": "KGS", "hsn": "40.0829.40"}
	r.update(kw)
	return r


def one(r, existing=None):
	return plan([r], existing or {}, HSNS, GROUPS)[0]


def test_a_manna_i_code_is_never_written_because_erpnext_i_codes_are_hi_techs():
	p = one(row(code="I-1048", name="TREAD RUBBER HOT BLACK PEARL 32*14"), existing={"I-1048": {"item_name": "Something else"}})
	assert p["action"] == "skip" and "not a shared code" in p["reason"]


def test_only_the_conversion_prefixes_followed_by_digits_are_shared():
	assert shared_prefix("BME2301002") == "BME"
	assert shared_prefix("BM02200504") == "BM"
	assert shared_prefix("SM010001") == "SM"
	assert shared_prefix("PMD01700004") == "PMD"
	assert shared_prefix("PMBX1") == ""
	assert shared_prefix("C-1001") == ""


def test_a_new_shared_code_is_created_in_the_group_its_prefix_gives():
	assert one(row())["doc"]["item_group"] == "FG"
	assert one(row(code="HMD001060"))["doc"]["item_group"] == "HOT"
	assert one(row(code="BME2301002"))["doc"]["item_group"] == "Bonding Gum"
	s = one(row(code="SM030001", uom="LTR", hsn="4005.99.90"))
	assert s["doc"]["item_group"] == "Vulcanizing Solution" and s["doc"]["stock_uom"] == "Litre"


def test_the_hsn_is_sap_s_chapter_without_dots_when_erpnext_has_it():
	assert one(row())["doc"]["gst_hsn_code"] == "40082940"


def test_an_inactive_or_unknown_unit_item_is_not_created():
	assert one(row(active="N"))["reason"] == "inactive in SAP"
	assert "has no ERPNext unit" in one(row(uom="BOX"))["reason"]


def test_an_existing_item_follows_sap_name_and_active_but_not_group_or_unit():
	h = {"item_name": "PCTR MANNA BLUE VIKING 205 129", "description": "PCTR MANNA BLUE VIKING 205 129", "disabled": 0, "gst_hsn_code": "40082940"}
	p = one(row(active="N"), existing={"PMB00101002": h})
	assert p["fields"] == {"item_name": "PCTR MANNA BLUE VIKING 205 129 (PLATINUM)", "description": "PCTR MANNA BLUE VIKING 205 129 (PLATINUM)", "disabled": 1}


def test_a_hand_written_description_is_kept_when_the_name_changes():
	h = {"item_name": "OLD", "description": "Customer favourite, 2 rolls per box", "disabled": 0, "gst_hsn_code": "40082940"}
	assert "description" not in one(row(), existing={"PMB00101002": h})["fields"]


def test_an_item_already_as_sap_has_it_is_left_unchanged():
	h = {"item_name": row()["name"], "description": "", "disabled": 0, "gst_hsn_code": "40082940"}
	assert one(row(), existing={"PMB00101002": h})["action"] == "unchanged"


def test_an_hsn_erpnext_lacks_is_reported_not_written():
	h = {"item_name": row()["name"], "disabled": 0, "gst_hsn_code": ""}
	p = one(row(hsn="9999.99"), existing={"PMB00101002": h})
	assert p["action"] == "unchanged" and "not in ERPNext" in p["notes"][0]


def test_a_code_sent_twice_is_written_once():
	out = plan([row(), row()], {}, HSNS, GROUPS)
	assert [p["action"] for p in out] == ["create", "skip"]


def test_without_a_6_or_8_digit_hsn_an_item_is_not_put_on_nor_created_because_india_compliance_refuses_it():
	h = {"item_name": row()["name"], "disabled": 0, "gst_hsn_code": "40082940"}
	assert one(row(hsn="35.06"), existing={"PMB00101002": h})["action"] == "unchanged"
	assert "no valid HSN" in one(row(code="SM030001", uom="LTR", hsn="35.06"))["reason"]
