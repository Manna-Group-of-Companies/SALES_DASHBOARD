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
