# Offline: the roll-figure rules in manna_sap_weights.py, without a site.
import os
import types

HERE = os.path.dirname(__file__)
ns = {"frappe": types.SimpleNamespace(flags={"manna_test": True})}
exec(open(os.path.join(HERE, "manna_sap_weights.py"), encoding="utf-8").read(), ns)
plan = ns["plan"]


def test_an_item_with_no_figures_in_erpnext_gets_saps():
	p = plan([{"code": "PMB1", "wpr": "25.000000", "bpr": "10"}], {"PMB1": {"wpr": 0, "bpr": 0, "pending": 0}})
	assert p["writes"] == [{"code": "PMB1", "fields": {"custom_weight_per_roll": 25.0, "custom_belts_per_roll": 10}}]


def test_a_figure_erpnext_already_has_is_never_overwritten_by_saps_rounded_one():
	p = plan([{"code": "I-11672", "wpr": "38.000000", "bpr": "6"}], {"I-11672": {"wpr": 38.4, "bpr": 6, "pending": 0}})
	assert p["writes"] == [] and "SAP 38, ERPNext 38.4 (kept)" in p["differs"][0]


def test_only_the_blank_one_of_the_two_is_filled():
	p = plan([{"code": "A", "wpr": "30", "bpr": "4"}], {"A": {"wpr": 0, "bpr": 4, "pending": 0}})
	assert p["writes"] == [{"code": "A", "fields": {"custom_weight_per_roll": 30.0}}]


def test_a_blank_in_sap_never_clears_erpnext():
	p = plan([{"code": "A", "wpr": "", "bpr": "0"}], {"A": {"wpr": 30, "bpr": 4, "pending": 0}})
	assert p["writes"] == [] and p["differs"] == []


def test_an_item_waiting_to_be_pushed_into_sap_is_left_alone():
	p = plan([{"code": "A", "wpr": "30", "bpr": "4"}], {"A": {"wpr": 0, "bpr": 0, "pending": 1}})
	assert p["writes"] == [] and p["counts"]["waiting_for_push"] == 1


def test_an_item_erpnext_does_not_hold_is_counted_not_created():
	p = plan([{"code": "X", "wpr": "30", "bpr": "4"}], {})
	assert p["writes"] == [] and p["counts"]["not_in_erpnext"] == 1
