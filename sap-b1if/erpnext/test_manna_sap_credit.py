# Offline: the credit rules in manna_sap_credit.py (a port of Sync-SapCreditLimits.ps1), without a site.
import os
import types

HERE = os.path.dirname(__file__)
ns = {"frappe": types.SimpleNamespace(flags={"manna_test": True})}
exec(open(os.path.join(HERE, "manna_sap_credit.py"), encoding="utf-8").read(), ns)
figures, changes = ns["figures"], ns["changes"]
BLANK = {}


def row(**kw):
	r = {"code": "C-1", "limit": "50000", "balance": "12000.50", "terms_code": "1", "terms": "Net-30",
		"b1": "8000", "b2": "3000.5", "b3": "0", "b4": "1000", "od_amt": "4000.5", "od_days": "40"}
	r.update(kw)
	return r


def test_every_figure_is_written_on_a_customer_that_has_none():
	f = changes(figures(row()), BLANK)
	assert f == {"custom_credit_limit": 50000.0, "custom_outstanding_balance": 12000.5, "custom_outstanding_0_30": 8000.0,
		"custom_outstanding_30_60": 3000.5, "custom_outstanding_90_plus": 1000.0, "custom_payment_terms": "Net-30",
		"custom_overdue_past_terms": 4000.5, "custom_overdue_days": 40}


def test_a_sap_limit_of_zero_never_wipes_a_typed_limit():
	assert "custom_credit_limit" not in changes(figures(row(limit="0")), {"custom_credit_limit": 75000})


def test_a_customer_with_no_open_documents_has_stale_buckets_written_down_to_zero():
	have = {"custom_credit_limit": 50000, "custom_outstanding_balance": 500, "custom_outstanding_0_30": 500, "custom_payment_terms": "Net-30"}
	f = changes(figures(row(balance="0", b1="0", b2="0", b3="0", b4="0", od_amt="0", od_days="0")), have)
	assert f == {"custom_outstanding_balance": 0.0, "custom_outstanding_0_30": 0.0}


def test_overdue_is_capped_at_the_account_balance_so_payments_on_account_count():
	w = figures(row(balance="1500", od_amt="4000"))
	assert w["od_amt"] == 1500.0 and w["od_days"] == 40


def test_no_payment_term_means_nothing_is_overdue_past_terms():
	w = figures(row(terms_code="-1"))
	assert w["od_amt"] == 0.0 and w["od_days"] == 0


def test_a_balance_at_or_below_zero_means_nothing_is_overdue_and_no_days():
	w = figures(row(balance="-200"))
	assert w["od_amt"] == 0.0 and w["od_days"] == 0


def test_a_blank_term_name_never_clears_the_stored_one_and_case_alone_is_not_a_change():
	assert "custom_payment_terms" not in changes(figures(row(terms="")), {"custom_payment_terms": "Net-30"})
	assert "custom_payment_terms" not in changes(figures(row(terms="NET-30")), {"custom_payment_terms": "Net-30"})


def test_a_difference_under_half_a_paisa_is_not_a_change():
	have = {"custom_credit_limit": 50000.004, "custom_outstanding_balance": 12000.504, "custom_outstanding_0_30": 8000, "custom_outstanding_30_60": 3000.5,
		"custom_outstanding_90_plus": 1000, "custom_payment_terms": "Net-30", "custom_overdue_past_terms": 4000.5, "custom_overdue_days": 40}
	assert changes(figures(row()), have) == {}


def test_a_negative_bucket_is_written_as_it_is():
	assert figures(row(b1="-250.129"))["buckets"][0] == -250.13


# run() against a stand-in site, for SAP Sync Control.last_sync_at.

class Row(dict):
	__getattr__ = dict.get


def run_on(customers, dry):
	"""Run the endpoint once on a fake site; returns every db.set_value call."""
	sets = []

	def get_all(doctype, **kw):
		return [Row(name="x")] if doctype == "Has Role" else [Row(c) for c in customers]

	def throw(msg):
		raise RuntimeError(msg)

	fr = types.SimpleNamespace(
		flags={"manna_test": True}, session=types.SimpleNamespace(user="sync@x"), get_all=get_all, throw=throw,
		form_dict={"credit": [row(code="C-1")], "dry_run": 1 if dry else 0}, response={},
		utils=types.SimpleNamespace(cint=lambda v: int(v or 0), now=lambda: "2026-11-26 10:49:01.000000"),
		db=types.SimpleNamespace(set_value=lambda *a: sets.append(a)))
	env = {"frappe": fr}
	exec(open(os.path.join(HERE, "manna_sap_credit.py"), encoding="utf-8").read(), env)
	env["run"]()
	return sets


def stamps(sets):
	return [s for s in sets if s[0] == "SAP Sync Control"]


SAME = {"name": "CUST-1", "custom_bp_code": "C-1", "custom_credit_limit": 50000, "custom_outstanding_balance": 12000.5,
	"custom_outstanding_0_30": 8000, "custom_outstanding_30_60": 3000.5, "custom_outstanding_90_plus": 1000,
	"custom_payment_terms": "Net-30", "custom_overdue_past_terms": 4000.5, "custom_overdue_days": 40}


def test_an_applied_run_stamps_last_sync_at_so_payment_commitments_can_be_judged():
	# 26 Nov 2026: only the old poller stamped it (last 20 Oct), so every
	# commitment would have gone Unchecked while B1iF kept the figures current.
	assert stamps(run_on([dict(SAME, custom_outstanding_balance=0)], dry=False)) == [
		("SAP Sync Control", None, "last_sync_at", "2026-11-26 10:49:01.000000")]


def test_an_applied_run_with_nothing_changed_still_stamps_because_the_figures_are_current():
	sets = run_on([SAME], dry=False)
	assert [s for s in sets if s[0] == "Customer"] == [] and len(stamps(sets)) == 1


def test_a_dry_run_never_stamps_last_sync_at():
	assert run_on([dict(SAME, custom_outstanding_balance=0)], dry=True) == []


def test_a_duplicate_code_refusal_never_stamps_last_sync_at():
	sets = []
	try:
		sets = run_on([SAME, dict(SAME, name="CUST-2")], dry=False)
	except RuntimeError as e:
		assert "duplicate" in str(e)
	else:
		raise AssertionError("expected the duplicate-code refusal")
	assert stamps(sets) == []
