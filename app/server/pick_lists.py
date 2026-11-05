# Frappe Server Script
#   Name          : manna_pick_lists
#   Script Type   : API
#   API Method    : manna_pick_lists
#   Args (GET)    : sales_order (optional) — only that order's lists
#
# Pick lists, newest first, with their products (3 Nov 2026). Scoped to the
# caller the way manna_sales_targets is:
#   GM (User.custom_is_general_manager) or System Manager: every team.
#   A team manager: every list for their team's orders.
#   Anyone else with a Sales Person: their own orders' lists.
#   A production manager (User.custom_is_production_manager, 5 Nov 2026):
#     every list, to approve them (manna_pick_list_approve) — but WITHOUT the
#     customer. Production sees the order, the SAP number and the rep, never
#     the customer (the user, 26 Sep 2026); customer and customer_name come
#     back blank unless the list is also their own team's.
# Each list carries its approval (Pending / Approved, who and when) and its
# order's SAP number and company (custom_company, the unit).
# The doctypes are only System Manager's, so this is the way in.

user = frappe.session.user
so_name = (frappe.form_dict.get("sales_order") or "").strip()

u = frappe.db.get_value(
    "User", user,
    ["custom_managed_team", "custom_is_general_manager", "custom_is_production_manager"],
    as_dict=True,
) or {}
is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1
))
is_gm = is_sys or frappe.utils.cint(u.get("custom_is_general_manager")) == 1
is_prod = frappe.utils.cint(u.get("custom_is_production_manager")) == 1

mine = frappe.get_all("Sales Person", filters={"custom_user": user, "is_group": 0},
                      fields=["name", "custom_team_manager"], limit=1)
me = mine[0] if mine else None
managed = (u.get("custom_managed_team") or "").strip()
if not managed and me:
    tok = (me.custom_team_manager or "").strip()
    if tok and me.name.strip().lower().startswith(tok.lower()):
        managed = tok

filters = {}
if so_name:
    filters["sales_order"] = so_name
if is_gm or is_prod:
    pass
elif managed:
    filters["team"] = managed
elif me:
    filters["sales_person"] = me.name
else:
    filters["name"] = "__nobody__"

heads = frappe.get_all(
    "Manna Pick List",
    filters=filters,
    fields=["name", "sales_order", "customer", "customer_name", "sales_person",
            "team", "status", "picked_on", "picked_by",
            "approval_status", "approved_by", "approved_on"],
    order_by="creation desc",
    limit_page_length=200,
)
names = [h.name for h in heads]
items = {}
if names:
    for r in frappe.get_all(
        "Manna Pick List Item",
        filters={"parent": ["in", names], "parenttype": "Manna Pick List"},
        fields=["parent", "idx", "sales_order_item", "item_code", "item_name", "unit",
                "ordered_qty", "available_qty", "picked_qty"],
        order_by="parent asc, idx asc",
        limit_page_length=0,
    ):
        items.setdefault(r.parent, []).append({
            "sales_order_item": r.sales_order_item,
            "item_code": r.item_code,
            "item_name": r.item_name or "",
            "unit": r.unit or "",
            "ordered_qty": frappe.utils.flt(r.ordered_qty),
            "available_qty": frappe.utils.flt(r.available_qty),
            "picked_qty": frappe.utils.flt(r.picked_qty),
        })

orders = {}
people = {}
if heads:
    for r in frappe.get_all(
        "Sales Order",
        filters={"name": ["in", list(set([h.sales_order for h in heads]))]},
        fields=["name", "custom_sap_sales_order", "custom_company"],
        limit_page_length=0,
    ):
        orders[r.name] = r
    approvers = list(set([h.approved_by for h in heads if h.approved_by]))
    if approvers:
        for r in frappe.get_all("User", filters={"name": ["in", approvers]},
                                fields=["name", "full_name"], limit_page_length=0):
            people[r.name] = r.full_name or r.name

out = []
for h in heads:
    so = orders.get(h.sales_order) or {}
    # A production manager sees no customer, save on their own team's lists.
    hide = is_prod and not is_gm and not (managed and h.team == managed)
    out.append({
        "name": h.name,
        "sales_order": h.sales_order,
        "sap_sales_order": so.get("custom_sap_sales_order") or "",
        "company": so.get("custom_company") or "",
        "customer": "" if hide else (h.customer or ""),
        "customer_name": "" if hide else (h.customer_name or ""),
        "sales_person": h.sales_person or "",
        "team": h.team or "",
        "status": h.status or "Submitted",
        "picked_on": str(h.picked_on or ""),
        "picked_by": h.picked_by or "",
        # Blank on lists made before the field existed: those are Pending too.
        "approval_status": h.approval_status or "Pending",
        "approved_by": h.approved_by or "",
        "approved_by_name": people.get(h.approved_by, "") if h.approved_by else "",
        "approved_on": str(h.approved_on or ""),
        "items": items.get(h.name, []),
    })

frappe.response["message"] = out
