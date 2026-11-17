# Offline: the order and line status rules in manna_sap_status.py, without a site.
import os
import types

HERE = os.path.dirname(__file__)
ns = {"frappe": types.SimpleNamespace(flags={"manna_test": True})}
exec(open(os.path.join(HERE, "manna_sap_status.py"), encoding="utf-8").read(), ns)
plan, order_status, merge_stage = ns["plan"], ns["order_status"], ns["merge_stage"]


def order(*items, status=""):
	return {"status": status, "lines": [{"name": "row-%s" % it, "item_code": it, "ht_stage": ht, "dispatched": d, "status": s} for it, ht, d, s in items]}


def test_an_order_has_a_status_only_when_every_line_has_reached_it():
	assert order_status(["Picked", "Picked"]) == "Picked"
	assert order_status(["Picked", "In SAP"]) == "Partially Picked"
	assert order_status(["Dispatched", "Picked"]) == "Partially Dispatched"
	assert order_status(["Dispatched", "Dispatched"]) == "Dispatched"
	assert order_status(["In SAP", "In SAP"]) == "In SAP"
	assert order_status(["In SAP", ""]) == ""


def test_cancelled_lines_do_not_hold_an_order_back():
	assert order_status(["Dispatched", "Cancelled"]) == "Dispatched"
	assert order_status(["Cancelled", "Cancelled"]) == "Cancelled"


def test_hitech_puts_lines_in_sap_and_the_order_follows():
	p = plan("hitech", [{"order": "SO1", "item": "A", "stage": "In SAP"}, {"order": "SO1", "item": "B", "stage": "In SAP"}],
		{"SO1": order(("A", "", 0, ""), ("B", "", 0, ""))})
	assert [w["fields"]["custom_sap_line_status"] for w in p["lines"]] == ["In SAP", "In SAP"]
	assert p["orders"] == [{"name": "SO1", "status": "In SAP"}]


def test_one_line_picked_makes_the_order_partially_picked():
	p = plan("hitech", [{"order": "SO1", "item": "A", "stage": "Picked"}, {"order": "SO1", "item": "B", "stage": "In SAP"}],
		{"SO1": order(("A", "In SAP", 0, "In SAP"), ("B", "In SAP", 0, "In SAP"), status="In SAP")})
	assert p["lines"] == [{"order": "SO1", "row": "row-A", "item": "A", "fields": {"custom_sap_ht_stage": "Picked", "custom_sap_line_status": "Picked"}}]
	assert p["orders"] == [{"name": "SO1", "status": "Partially Picked"}]


def test_manna_invoice_makes_a_line_dispatched_and_hitech_stage_is_kept_under_it():
	p = plan("manna", [{"order": "SO1", "item": "A", "stage": "Dispatched"}],
		{"SO1": order(("A", "Picked", 0, "Picked"), ("B", "Picked", 0, "Picked"), status="Picked")})
	assert p["lines"][0]["fields"] == {"custom_sap_mt_dispatched": 1, "custom_sap_line_status": "Dispatched"}
	assert p["orders"] == [{"name": "SO1", "status": "Partially Dispatched"}]


def test_a_later_hitech_post_does_not_undo_dispatched():
	p = plan("hitech", [{"order": "SO1", "item": "A", "stage": "Picked"}],
		{"SO1": order(("A", "Picked", 1, "Dispatched"), status="Dispatched")})
	assert p["lines"] == [] and p["orders"] == []


def test_a_cancelled_manna_invoice_takes_the_line_back_to_hitech_stage():
	p = plan("manna", [{"order": "SO1", "item": "A", "stage": ""}],
		{"SO1": order(("A", "Picked", 1, "Dispatched"), status="Dispatched")})
	assert p["lines"][0]["fields"] == {"custom_sap_mt_dispatched": 0, "custom_sap_line_status": "Picked"}
	assert p["orders"] == [{"name": "SO1", "status": "Picked"}]


def test_a_line_the_batch_no_longer_mentions_is_cleared_for_that_source():
	p = plan("hitech", [{"order": "SO1", "item": "A", "stage": "In SAP"}],
		{"SO1": order(("A", "In SAP", 0, "In SAP"), ("B", "In SAP", 0, "In SAP"), status="In SAP")})
	assert p["lines"][0]["row"] == "row-B" and p["lines"][0]["fields"]["custom_sap_line_status"] == ""
	assert p["orders"] == [{"name": "SO1", "status": ""}]


def test_an_item_on_two_erpnext_lines_gets_no_status_and_is_reported():
	p = plan("hitech", [{"order": "SO1", "item": "A", "stage": "Picked"}],
		{"SO1": order(("A", "", 0, ""), ("A", "", 0, ""))})
	assert p["lines"] == [] and "cannot tell them apart" in p["notes"][0]


def test_an_item_on_two_hitech_lines_is_as_far_as_its_slower_line():
	assert merge_stage("Picked", "In SAP") == "In SAP"
	assert merge_stage("Cancelled", "Picked") == "Picked"
	assert merge_stage("Cancelled", "Cancelled") == "Cancelled"


def test_an_order_not_in_erpnext_is_reported_not_guessed():
	p = plan("hitech", [{"order": "SAL-ORD-X", "item": "A", "stage": "In SAP"}], {})
	assert p["lines"] == [] and "no such ERPNext order" in p["notes"][0]


def test_item_codes_match_whatever_their_case():
	p = plan("hitech", [{"order": "SO1", "item": "pmb001", "stage": "In SAP"}], {"SO1": order(("PMB001", "", 0, ""))})
	assert p["lines"][0]["fields"]["custom_sap_line_status"] == "In SAP"


# ---- delivery dates (13 Nov 2026): Hi-Tech's line date becomes the order's


def dated(header, *items, original="", status="In SAP"):
	"""An order whose lines are (item, stage/status, delivery date)."""
	return {"status": status, "delivery_date": header, "original_delivery_date": original,
		"lines": [{"name": "row-%s" % it, "item_code": it, "ht_stage": st if st != "Dispatched" else "Picked", "dispatched": 1 if st == "Dispatched" else 0,
			"status": st, "delivery_date": d} for it, st, d in items]}


def ht(order, item, date, stage="In SAP"):
	return {"order": order, "item": item, "stage": stage, "date": date}


def test_a_date_moved_for_the_whole_order_moves_every_line_and_the_order():
	p = plan("hitech", [ht("SO1", "A", "2026-11-25"), ht("SO1", "B", "2026-11-25")],
		{"SO1": dated("2026-11-20", ("A", "In SAP", "2026-11-20"), ("B", "In SAP", "2026-11-20"))})
	assert [(w["item"], w["from"], w["to"]) for w in p["date_lines"]] == [("A", "2026-11-20", "2026-11-25"), ("B", "2026-11-20", "2026-11-25")]
	assert p["date_orders"] == [{"name": "SO1", "from": "2026-11-20", "to": "2026-11-25", "original": "2026-11-20"}]


def test_a_date_moved_for_one_item_moves_that_line_and_the_order_is_complete_on_the_latest():
	p = plan("hitech", [ht("SO1", "A", "2026-11-20"), ht("SO1", "B", "2026-11-27")],
		{"SO1": dated("2026-11-20", ("A", "In SAP", "2026-11-20"), ("B", "In SAP", "2026-11-20"))})
	assert [(w["item"], w["to"]) for w in p["date_lines"]] == [("B", "2026-11-27")]
	assert p["date_orders"][0]["to"] == "2026-11-27"


def test_dates_that_already_agree_write_nothing():
	p = plan("hitech", [ht("SO1", "A", "2026-11-20")], {"SO1": dated("2026-11-20", ("A", "In SAP", "2026-11-20"))})
	assert p["date_lines"] == [] and p["date_orders"] == []


def test_the_date_the_customer_was_given_is_kept_once_and_never_overwritten():
	p = plan("hitech", [ht("SO1", "A", "2026-11-30")],
		{"SO1": dated("2026-11-25", ("A", "In SAP", "2026-11-25"), original="2026-11-20")})
	assert p["date_orders"] == [{"name": "SO1", "from": "2026-11-25", "to": "2026-11-30", "original": ""}]


def test_a_line_with_no_date_in_the_batch_keeps_its_own():
	# Closed or cancelled in Hi-Tech, or a package from before dates were sent.
	p = plan("hitech", [ht("SO1", "A", ""), ht("SO1", "B", "")],
		{"SO1": dated("2026-11-20", ("A", "In SAP", "2026-11-20"), ("B", "In SAP", "2026-11-22"))})
	assert p["date_lines"] == [] and p["date_orders"] == []


def test_a_dispatched_or_cancelled_line_does_not_hold_the_orders_date():
	p = plan("hitech", [ht("SO1", "A", "", "Picked"), ht("SO1", "B", "2026-11-18"), ht("SO1", "C", "", "Cancelled")],
		{"SO1": dated("2026-11-28", ("A", "Dispatched", "2026-11-28"), ("B", "In SAP", "2026-11-28"), ("C", "In SAP", "2026-11-28"))})
	assert [(w["item"], w["to"]) for w in p["date_lines"]] == [("B", "2026-11-18")]
	assert p["date_orders"][0]["to"] == "2026-11-18"


def test_an_item_split_over_two_hitech_lines_takes_the_later_date():
	p = plan("hitech", [ht("SO1", "A", "2026-11-20"), ht("SO1", "A", "2026-11-27")],
		{"SO1": dated("2026-11-20", ("A", "In SAP", "2026-11-20"))})
	assert p["date_lines"][0]["to"] == "2026-11-27"


def test_an_item_on_two_erpnext_lines_keeps_its_dates_and_they_still_count_for_the_order():
	p = plan("hitech", [ht("SO1", "A", "2026-11-30"), ht("SO1", "B", "2026-11-22")],
		{"SO1": {"status": "", "delivery_date": "2026-11-20", "original_delivery_date": "", "lines": [
			{"name": "r1", "item_code": "A", "ht_stage": "", "dispatched": 0, "status": "", "delivery_date": "2026-11-20"},
			{"name": "r2", "item_code": "A", "ht_stage": "", "dispatched": 0, "status": "", "delivery_date": "2026-11-24"},
			{"name": "r3", "item_code": "B", "ht_stage": "", "dispatched": 0, "status": "", "delivery_date": "2026-11-20"}]}})
	assert [(w["row"], w["to"]) for w in p["date_lines"]] == [("r3", "2026-11-22")]
	assert p["date_orders"][0]["to"] == "2026-11-24"


def test_something_that_is_not_a_date_is_never_written():
	p = plan("hitech", [ht("SO1", "A", "25/11/2026"), ht("SO1", "B", "2026-11-2")],
		{"SO1": dated("2026-11-20", ("A", "In SAP", "2026-11-20"), ("B", "In SAP", "2026-11-20"))})
	assert p["date_lines"] == [] and p["date_orders"] == []


def test_manna_posts_never_move_a_date():
	p = plan("manna", [{"order": "SO1", "item": "A", "stage": "Dispatched", "date": "2026-12-01"}],
		{"SO1": dated("2026-11-20", ("A", "Picked", "2026-11-20"))})
	assert p["date_lines"] == [] and p["date_orders"] == []


def test_a_date_read_as_a_date_object_compares_as_its_day():
	import datetime
	p = plan("hitech", [ht("SO1", "A", "2026-11-20")],
		{"SO1": dated(datetime.date(2026, 11, 20), ("A", "In SAP", datetime.date(2026, 11, 20)))})
	assert p["date_lines"] == [] and p["date_orders"] == []
