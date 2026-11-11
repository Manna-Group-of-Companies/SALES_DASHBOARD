# Offline: the stale-batch rule in manna_sap_in.py, without a site.
import os
import types

HERE = os.path.dirname(__file__)
ns = {"frappe": types.SimpleNamespace(flags={"manna_test": True})}
exec(open(os.path.join(HERE, "manna_sap_in.py"), encoding="utf-8").read(), ns)
stale, MAX_AGE, KINDS = ns["stale"], ns["MAX_AGE"], ns["KINDS"]


def test_a_whole_state_batch_older_than_its_limit_is_ignored():
	assert stale("stock", MAX_AGE["stock"] + 1)
	assert stale("status", 15 * 3600)


def test_a_batch_inside_its_limit_is_written():
	assert not stale("stock", 0) and not stale("stock", MAX_AGE["stock"])


def test_a_batch_with_no_readable_time_is_let_through_not_refused():
	# an older package, an empty result, a field this script cannot read
	for kind in KINDS:
		assert not stale(kind, None)


def test_a_sap_clock_ahead_of_erpnext_is_not_stale():
	assert not stale("payments", -900)


def test_a_late_customer_or_item_is_still_written_however_old():
	# one record's newest word; dropping it loses the change until the nightly send
	assert not stale("customers", 10 ** 6) and not stale("items", 10 ** 6)


def test_every_whole_state_kind_has_a_limit_and_no_limit_names_an_unknown_kind():
	assert set(MAX_AGE) == set(KINDS) - {"customers", "items"}
