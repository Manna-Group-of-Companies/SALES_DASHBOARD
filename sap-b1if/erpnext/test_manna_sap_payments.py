# Offline: the payment mirror's rules in manna_sap_payments.py, without a site.
import os
import types
import datetime

HERE = os.path.dirname(__file__)
ns = {"frappe": types.SimpleNamespace(flags={"manna_test": True})}
exec(open(os.path.join(HERE, "manna_sap_payments.py"), encoding="utf-8").read(), ns)
TODAY = "2026-11-10"
age = lambda d: (datetime.date.fromisoformat(TODAY) - datetime.date.fromisoformat(d)).days
CUST = {"c-1664": "Janata Tyres"}


def plan(rows, existing=None):
	return ns["plan"](rows, CUST, existing or {}, TODAY, age)


def row(**kw):
	r = {"entry": "10331", "num": "10001", "code": "C-1664", "date": "2026-11-09", "amount": "17580.00", "on_account": ".00",
		"cancelled": "N", "mode": "Bank Transfer", "reference": "", "remarks": "Being the receipt", "invoices": "INV 10286: 17580.00"}
	r.update(kw)
	return r


def test_a_payment_posted_this_week_is_created_as_new_so_a_trigger_acts_on_it():
	c = plan([row()])["create"][0]
	assert c["sap_key"] == "Manna Treads-10331" and c["customer"] == "Janata Tyres" and c["status"] == "Posted" and c["new_payment"] == 1


def test_an_old_payment_loaded_for_the_first_time_is_not_new_so_nobody_is_messaged_about_it():
	assert plan([row(date="2026-04-02")])["create"][0]["new_payment"] == 0


def test_a_payment_already_cancelled_when_first_seen_is_not_new():
	c = plan([row(cancelled="Y")])["create"][0]
	assert c["status"] == "Cancelled" and c["new_payment"] == 0


def test_a_payment_for_a_customer_erpnext_does_not_hold_is_counted_not_created():
	p = plan([row(code="C-9999")])
	assert p["create"] == [] and p["no_customer"] == 1


def test_a_payment_sap_cancels_later_is_marked_cancelled_not_deleted():
	have = {"Manna Treads-10331": {"customer": "Janata Tyres", "payment_no": "10001", "sap_card_code": "C-1664", "posting_date": "2026-11-09",
		"status": "Posted", "mode": "Bank Transfer", "reference": "", "amount": 17580.0, "on_account": 0.0,
		"invoices": "INV 10286: 17580.00", "remarks": "Being the receipt"}}
	p = plan([row(cancelled="Y")], have)
	assert p["create"] == [] and p["update"] == [{"name": "Manna Treads-10331", "fields": {"status": "Cancelled"}}]


def test_an_unchanged_payment_is_not_written_again():
	have = {"Manna Treads-10331": {"customer": "Janata Tyres", "payment_no": "10001", "sap_card_code": "C-1664", "posting_date": datetime.date(2026, 11, 9),
		"status": "Posted", "mode": "Bank Transfer", "reference": None, "amount": 17580.004, "on_account": 0,
		"invoices": "INV 10286: 17580.00", "remarks": "Being the receipt"}}
	p = plan([row()], have)
	assert p["create"] == [] and p["update"] == []


def test_a_payment_that_left_the_batch_is_left_alone():
	p = plan([], {"Manna Treads-1": {"status": "Posted"}})
	assert p["create"] == [] and p["update"] == []


def test_a_first_load_is_capped_and_the_rest_waits_for_the_next_run():
	p = plan([row(entry=str(n)) for n in range(1, 301)])
	assert len(p["create"]) == 250 and p["held"] == 50
