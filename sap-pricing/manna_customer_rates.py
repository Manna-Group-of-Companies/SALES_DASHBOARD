# Manna Treads' SAP rates for one customer or one lead - for the phone's order
# screen (the user, 25 Sep 2026). Read from SAP Pricing Control.snapshot_json,
# which the office server copies out of MANNA_TREADS_LIVE
# (sap-pricing/Sync-SapPricingSnapshot.ps1).
#
# ?customer=  The rate for an item is the customer's own special price when SAP
#             holds one and it is switched on; otherwise the price of Price
#             List 01 ("selling price"), when that is the customer's price list.
# ?lead=      Always Price List 01. Lead orders are taken at the list price; a
#             lower price goes through Higher Management and becomes a special
#             price once the lead is a customer (the user, 25 Sep 2026). The
#             answer carries list_only = 1 and the phone locks the rate box.
#
# Prices are per kg and GST-inclusive exactly as SAP holds them: nothing is
# added or taken off. The rule lives here only, so the phone and the dashboard
# cannot price an item differently.
#
# EVERY ITEM IN THE SNAPSHOT (the user, 11 Nov 2026). It was test items only
# (item group "ZZ - Test", 25 Sep 2026). Since 10 Nov the phone takes the rate
# from here and nothing else, so an item missing here cannot be ordered: an
# item is priced once Manna Treads' SAP has it ticked with a quality (a named
# item property, which is what puts it in the snapshot) and a Price List 01
# price, it has a Hi-Tech twin, and the snapshot has been synced since.
# ONLY_GROUP = "ZZ - Test" would bring the old limit back.
#
# Server Script: API, method manna_customer_rates. Kept in git from 11 Nov
# 2026; before that it lived only in ERPNext.
#
# An item is only priced when it has a Hi-Tech twin (the same code AND the same
# name in both companies): the phone's items are ERPNext items, whose codes are
# Hi-Tech's, and a Treads code with no twin can be a different item there.
#
# Who may ask: the rep the customer or lead is assigned to
# (Customer.custom_assigned_reps / Lead.custom_sales_person is the rep's Sales
# Person, whose custom_user is the login), a manager (Sales Manager, Higher
# Management, System Manager), or SAP Sync Bot. Only for Manna Treads:
# custom_bp_code is a Manna Treads SAP code only there.
#
# A customer's own special prices are given only when its ERPNext name is SAP's
# name for that code and no other ERPNext customer carries the code. A rep can
# write both custom_bp_code and custom_assigned_reps, so without this a rep
# could put a dealer's code on a customer of their own and read that dealer's
# prices. (The rest of that gap closes only when custom_bp_code is made
# read-only for Sales User - see shared/DIVERGENCES.md.)
#
# safe_exec traps: roles come from Has Role (frappe.get_roles is not
# whitelisted), JSON is read with json.loads (frappe.parse_json is not), and no
# def: a function here cannot see the script's own top-level names.
ONLY_GROUP = ""
TREADS = "Manna Treads"

customer = (frappe.form_dict.get("customer") or "").strip()
lead = (frappe.form_dict.get("lead") or "").strip()
if not customer and not lead:
    frappe.throw("Which customer or lead?")
user = frappe.session.user
roles = [r.role for r in frappe.get_all("Has Role", filters={"parent": user}, fields=["role"], limit_page_length=0)]
manager = ("Sales Manager" in roles) or ("Higher Management" in roles) or ("System Manager" in roles) or ("SAP Sync Bot" in roles)

bp = ""
cname = ""
if lead:
    party = frappe.db.get_value("Lead", lead, ["name", "custom_sales_person"], as_dict=True)
    if not party:
        frappe.throw("No such lead: " + lead)
    rep_name = party.custom_sales_person
    customer = ""
else:
    party = frappe.db.get_value("Customer", customer, ["name", "customer_name", "custom_bp_code", "custom_assigned_reps"], as_dict=True)
    if not party:
        frappe.throw("No such customer: " + customer)
    rep_name = party.custom_assigned_reps
    bp = (party.custom_bp_code or "").strip()
    cname = party.customer_name or ""
rep = None
if rep_name:
    rep = frappe.db.get_value("Sales Person", rep_name, ["custom_user", "custom_company"], as_dict=True)
if not manager and not (rep and rep.custom_user == user):
    frappe.throw("You can only see the rates of your own customers and leads.")

out = {"customer": customer, "lead": lead, "bp_code": bp, "synced_at": "", "rates": {}, "note": "", "list_only": 1 if lead else 0}
if rep and rep.custom_company and rep.custom_company != TREADS:
    out["note"] = "Not a Manna Treads " + ("lead" if lead else "customer") + " - there are no Manna Treads SAP rates for it."
else:
    doc = frappe.get_doc("SAP Pricing Control")
    snap = json.loads(doc.snapshot_json) if doc.snapshot_json else None
    if not snap or int(snap.get("version") or 0) < 3:
        out["note"] = "There is no copy of Manna Treads' SAP prices yet."
    else:
        out["synced_at"] = snap.get("syncedAt") or ""
        list_no = int((snap.get("priceList") or {}).get("no") or 1)
        bp_list = None
        sap_name = ""
        if bp:
            for cu in snap.get("customers") or []:
                if cu.get("code") == bp:
                    bp_list = int(cu.get("priceList") or 0)
                    sap_name = cu.get("name") or ""
                    break
        trusted = False
        if bp and bp_list is not None:
            same_name = " ".join(sap_name.lower().split()) == " ".join(cname.lower().split())
            holders = frappe.get_all("Customer", filters={"custom_bp_code": bp}, fields=["name"], limit_page_length=2)
            trusted = same_name and len(holders) == 1
        cols = snap.get("specialCols") or []
        special = {}
        if trusted and "card" in cols and "item" in cols and "price" in cols:
            ci = cols.index("card")
            ii = cols.index("item")
            pi = cols.index("price")
            vi = cols.index("valid") if "valid" in cols else -1
            for row in snap.get("specialRows") or []:
                if row[ci] == bp and (vi < 0 or row[vi] == 1):
                    special[row[ii]] = float(row[pi] or 0)
        for it in snap.get("items") or []:
            if ONLY_GROUP and it.get("groupName") != ONLY_GROUP:
                continue
            code = it.get("twin")
            if not code:
                continue
            lp = float(it.get("listPrice") or 0)
            sp = special.get(it.get("code")) or 0
            if sp > 0:
                out["rates"][code] = {"rate": sp, "source": "special", "list": lp if lp > 0 else None}
            elif lp > 0 and (lead or bp_list is None or bp_list == list_no):
                out["rates"][code] = {"rate": lp, "source": "list", "list": lp}
        if lead:
            pass
        elif not bp:
            out["note"] = "This customer has no Manna Treads SAP code, so only list prices are shown."
        elif bp_list is None:
            out["note"] = "This customer's code is not in Manna Treads' SAP, so only list prices are shown."
        elif not trusted:
            out["note"] = ("This customer's name or code does not match Manna Treads' SAP record for " + bp
                           + ", so only list prices are shown. Ask the office to correct it.")
frappe.response["message"] = out
