# Offline: the customer rules in manna_sap_customers.py, without a site.
#   python -m pytest sap-b1if/erpnext -q
import os
import types

HERE = os.path.dirname(__file__)


def load():
	fake = types.SimpleNamespace(flags={"manna_test": True})
	ns = {"frappe": fake}
	exec(open(os.path.join(HERE, "manna_sap_customers.py"), encoding="utf-8").read(), ns)
	return ns


NS = load()
plan, clean_phone = NS["plan"], NS["clean_phone"]
REPS = {"prashanth": "Prashanth", "sirajudheen kasim": "Sirajudheen Kasim", "jaimon d": "Jaimon D"}


def row(**kw):
	r = {"code": "C-500", "name": "New Tyres", "active": "Y", "sales_employee": "PRASHANTH", "phone": "", "address": "", "state": "", "gstin": ""}
	r.update(kw)
	return r


def one(r, existing=None, names=None):
	return plan([r], existing or {}, {} if names is None else names, REPS)[0]


def test_a_new_customer_with_a_mapped_rep_is_created_under_that_rep():
	p = one(row(sales_employee="Siraj-EKM", phone="9995133846 / 9447000000", gstin="32abcde1234f1z5"))
	assert p["action"] == "create"
	assert p["doc"]["custom_assigned_reps"] == "Sirajudheen Kasim"
	assert p["doc"]["custom_phone"] == "9995133846"
	assert p["doc"]["custom_gstin"] == "32ABCDE1234F1Z5"


def test_a_sales_employee_spelled_like_a_rep_needs_no_map_entry():
	assert one(row(sales_employee="Jaimon D"))["action"] == "create"


def test_an_unassigned_customer_stays_in_sap():
	assert one(row(sales_employee="-No Sales Employee-"))["reason"] == "unassigned in SAP"
	assert one(row(sales_employee=""))["reason"] == "unassigned in SAP"


def test_a_sales_employee_with_no_rep_keeps_the_customer_in_sap():
	assert "no enabled ERPNext rep" in one(row(sales_employee="SHOP SALE"))["reason"]


def test_an_inactive_or_nonstandard_customer_is_not_created():
	assert one(row(active="N"))["reason"] == "inactive or frozen in SAP"
	assert one(row(code="CUST-9"))["reason"] == "non-standard SAP code"


def test_a_name_erpnext_already_holds_is_never_created_twice():
	p = one(row(name="New  Tyres"), names={"new tyres": {"name": "New Tyres", "code": ""}})
	assert p["action"] == "skip" and "by hand" in p["reason"]


def test_two_sap_customers_with_one_name_create_only_the_first():
	out = plan([row(code="C-1"), row(code="C-2")], {}, {}, REPS)
	assert [p["action"] for p in out] == ["create", "skip"]


def test_an_existing_customer_is_matched_by_code_and_only_changed_fields_are_sent():
	h = {"name": "Old Name", "customer_name": "Old Name", "custom_phone": "9995133846", "custom_billing_address": "", "custom_state": "Kerala", "custom_gstin": ""}
	p = one(row(name="Renamed In SAP", phone="9995133846", address="Main Rd, Kochi", state="Kerala"), existing={"C-500": [h]})
	assert p["action"] == "update"
	assert p["fields"] == {"custom_billing_address": "Main Rd, Kochi"}
	assert any("SAP name" in n for n in p["notes"])


def test_a_blank_in_sap_never_clears_erpnext():
	h = {"name": "X", "customer_name": "New Tyres", "custom_phone": "9995133846", "custom_billing_address": "A", "custom_state": "Kerala", "custom_gstin": "G"}
	assert one(row(), existing={"C-500": [h]})["action"] == "unchanged"


def test_an_existing_customer_inactive_in_sap_is_reported_not_disabled():
	h = {"name": "X", "customer_name": "New Tyres"}
	p = one(row(active="N"), existing={"C-500": [h]})
	assert p["action"] == "unchanged" and "inactive or frozen in SAP" in p["notes"]


def test_a_code_held_by_two_erpnext_customers_is_an_error_not_a_guess():
	p = one(row(), existing={"C-500": [{"name": "A"}, {"name": "B"}]})
	assert p["action"] == "error"


def test_a_phone_with_too_few_digits_is_dropped():
	assert clean_phone("call office") == ""
	assert clean_phone("+91 99951-33846 ext") == "+91 99951-33846"


def test_a_dangling_dash_on_a_phone_is_dropped_so_it_is_not_rewritten_every_run():
	assert clean_phone("9895621169-") == "9895621169"
