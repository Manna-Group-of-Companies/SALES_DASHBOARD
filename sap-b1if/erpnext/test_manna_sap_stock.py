# Offline: the stock rules in manna_sap_stock.py, without a site.
import os
import types

HERE = os.path.dirname(__file__)
ns = {"frappe": types.SimpleNamespace(flags={"manna_test": True})}
exec(open(os.path.join(HERE, "manna_sap_stock.py"), encoding="utf-8").read(), ns)
def plan(*a):
	p = ns["plan"](*a)
	return p["lines"], p["notes"], p["refused"]
ITEM = {"disabled": 0, "is_stock_item": 1}


def items(*codes, **over):
	out = {c: dict(ITEM) for c in codes}
	out.update(over)
	return out


def test_only_items_whose_figure_moved_are_written():
	lines, _, refused = plan([{"code": "A", "qty": 10}, {"code": "B", "qty": 5}], items("A", "B"), {"A": 10, "B": 4})
	assert refused == "" and lines == [{"item_code": "B", "qty": 5.0, "was": 4}]


def test_an_item_with_stock_in_erpnext_but_none_in_sap_goes_to_zero():
	lines, _, _ = plan([{"code": "A", "qty": 10}], items("A", "B"), {"A": 10, "B": 3})
	assert lines == [{"item_code": "B", "qty": 0.0, "was": 3}]


def test_committed_beyond_on_hand_is_written_as_zero_not_negative():
	lines, _, _ = plan([{"code": "A", "qty": -12}], items("A"), {"A": 5})
	assert lines[0]["qty"] == 0.0


def test_an_empty_batch_changes_nothing_because_an_empty_read_looks_the_same():
	_, _, refused = plan([], items("A"), {"A": 5})
	assert "no rows" in refused


def test_a_batch_that_would_zero_most_of_the_shelf_is_refused():
	stocked = {"I-%d" % n: 1 for n in range(30)}
	_, _, refused = plan([{"code": "I-0", "qty": 1}], items(*stocked), stocked)
	assert "more than half" in refused


def test_an_item_erpnext_lacks_or_has_disabled_is_reported_not_written():
	lines, notes, _ = plan([{"code": "X", "qty": 4}, {"code": "D", "qty": 2}], {"D": {"disabled": 1, "is_stock_item": 1}}, {})
	assert lines == [] and len(notes) == 2


def test_two_rows_for_one_item_are_added_together():
	lines, _, _ = plan([{"code": "A", "qty": 2}, {"code": "A", "qty": 3}], items("A"), {})
	assert lines == [{"item_code": "A", "qty": 5.0, "was": 0.0}]


def test_force_lets_one_run_zero_most_of_the_shelf_but_never_an_empty_batch():
	stocked = {"I-%d" % n: 1 for n in range(30)}
	p = ns["plan"]([{"code": "I-0", "qty": 1}], items(*stocked), stocked, 1)
	assert p["refused"] == "" and len(p["lines"]) == 29
	assert "no rows" in ns["plan"]([], items("A"), {"A": 5}, 1)["refused"]
