# Offline: the SAP Invoice mirror's rules in manna_sap_invoices.py, without a site.
import os
import types

HERE = os.path.dirname(__file__)
ns = {"frappe": types.SimpleNamespace(flags={"manna_test": True})}
exec(open(os.path.join(HERE, "manna_sap_invoices.py"), encoding="utf-8").read(), ns)
plan = ns["plan"]
CUST = {"c-1018": "Rollex"}


def row(**kw):
	r = {"entry": "9560", "num": "1264", "code": "C-1018", "date": "2026-10-01", "due": "2026-10-31", "total": "29526.000000", "paid": "10000.456000", "status": "O"}
	r.update(kw)
	return r


def stored(**kw):
	s = {"customer": "Rollex", "invoice_no": "1264", "sap_card_code": "C-1018", "posting_date": "2026-10-01", "due_date": "2026-10-31",
		"total": 29526.0, "paid": 10000.46, "balance": 19525.54, "status": "Open"}
	s.update(kw)
	return s


def test_a_new_invoice_is_created_named_by_company_and_docentry_with_balance_from_rounded_figures():
	c = plan([row()], CUST, {})["create"][0]
	assert c["sap_key"] == "Manna Treads-9560" and c["paid"] == 10000.46 and c["balance"] == 19525.54 and c["status"] == "Open"


def test_status_is_saps_document_status_not_worked_out_from_the_balance():
	assert plan([row(status="C", paid="100")], CUST, {})["create"][0]["status"] == "Closed"


def test_only_the_changed_fields_of_a_row_are_written():
	p = plan([row(paid="29526", status="C")], CUST, {"Manna Treads-9560": stored()})
	assert p["update"] == [{"name": "Manna Treads-9560", "fields": {"paid": 29526.0, "balance": 0.0, "status": "Closed"}}]


def test_an_unchanged_row_is_not_touched():
	p = plan([row()], CUST, {"Manna Treads-9560": stored()})
	assert p["create"] == [] and p["update"] == [] and p["delete"] == []


def test_an_invoice_no_longer_in_the_batch_is_deleted():
	p = plan([row()], CUST, {"Manna Treads-9560": stored(), "Manna Treads-1": stored()})
	assert p["delete"] == ["Manna Treads-1"]


def test_a_batch_that_would_delete_more_than_half_of_a_mirror_of_20_deletes_nothing():
	have = {"Manna Treads-%d" % n: stored() for n in range(1, 31)}
	p = plan([row(entry="1")], CUST, have)
	assert p["delete"] == [] and p["deletes_held"] == 29


def test_exactly_half_is_still_deleted():
	have = {"Manna Treads-%d" % n: stored() for n in range(1, 31)}
	p = plan([row(entry=str(n)) for n in range(1, 16)], CUST, have)
	assert len(p["delete"]) == 15 and p["deletes_held"] == 0


def test_an_empty_batch_changes_nothing():
	p = plan([], CUST, {"Manna Treads-1": stored()})
	assert p["refused"] and p["delete"] == []


def test_an_invoice_of_a_customer_erpnext_does_not_hold_is_left_out():
	p = plan([row(code="C-9")], CUST, {})
	assert p["create"] == [] and p["no_customer"] == 1
