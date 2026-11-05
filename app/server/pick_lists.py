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
# The doctypes are only System Manager's, so this is the way in.

user = frappe.session.user
so_name = (frappe.form_dict.get("sales_order") or "").strip()

u = frappe.db.get_value(
    "User", user, ["custom_managed_team", "custom_is_general_manager"], as_dict=True
) or {}
is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1
))
is_gm = is_sys or frappe.utils.cint(u.get("custom_is_general_manager")) == 1

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
if is_gm:
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
            "sap_pick_list", "hitech_invoice", "mt_goods_receipt", "mt_delivery", "sap_sync_error"],
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
                "ordered_qty", "available_qty", "picked_qty", "picked_kg"],
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
            "picked_kg": frappe.utils.flt(r.picked_kg),
        })

out = []
for h in heads:
    out.append({
        "name": h.name,
        "sales_order": h.sales_order,
        "customer": h.customer or "",
        "customer_name": h.customer_name or "",
        "sales_person": h.sales_person or "",
        "team": h.team or "",
        "status": h.status or "Submitted",
        "picked_on": str(h.picked_on or ""),
        "picked_by": h.picked_by or "",
        "items": items.get(h.name, []),
        "sap_pick_list": h.sap_pick_list or "",
        "hitech_invoice": h.hitech_invoice or "",
        "mt_goods_receipt": h.mt_goods_receipt or "",
        "mt_delivery": h.mt_delivery or "",
        "sap_sync_error": h.sap_sync_error or "",
    })

frappe.response["message"] = out
