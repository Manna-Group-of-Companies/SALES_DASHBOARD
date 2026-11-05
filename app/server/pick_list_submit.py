# Frappe Server Script
#   Name          : manna_pick_list_submit
#   Script Type   : API
#   API Method    : manna_pick_list_submit
#   Args (POST)   : sales_order, lines = JSON [{sales_order_item, picked_qty, available_qty}]
#
# A pick list: which products of an approved order are to go from Hi-Tech's
# stock now (3 Nov 2026). The rep ticks what Hi-Tech has in stock — five of an
# order's ten, say — and the rest can be picked later on another list. The
# sales manager sees every list for their team (manna_pick_lists).
#
# Refused unless:
#   - the order is approved by the manager (custom_po_status) and not cancelled;
#   - the caller is the order's rep, that rep's team manager, or System Manager;
#   - every line is a line OF THIS ORDER — nothing from outside it;
#   - each quantity is above zero and no more than what is still unpicked on
#     that line: ordered, less what earlier Submitted lists for it hold;
#   - each line's kilos can be worked out (5 Nov 2026). Nobody types them: they
#     are the picked rolls x the weight per roll the ORDER was priced at (its
#     kilos over its rolls; the item's custom_weight_per_roll only for a line
#     with loose belts), and the rolls that finish a line take exactly the
#     kilos left. A line counted in kg takes its qty. Never more than the line's
#     kilos not yet on a list - SAP refuses a pick list line released over its
#     order line. SAP's pick list, Hi-Tech's invoice and Manna Treads' goods
#     receipt and delivery are made from them the moment the list reaches SAP.
#     Any picked_kg the phone sends is ignored. Same rule as
#     app/lib/core/pick_list.dart (pickKg), pinned by shared/fixtures/pick_list.json.
#
# Ordered is counted in the stock unit Hi-Tech's stock is shown in: whole rolls
# for tread rubber, else the line's qty (kg, cans). Loose belts are not picked.
# Same rule as app/lib/core/pick_list.dart, pinned by
# shared/fixtures/pick_list.json. That Hi-Tech has the stock is checked on the
# phone against the synced SAP figure, which is recorded on each row; it is
# not re-checked here.
#
# The doctypes are only System Manager's; this script inserts with
# ignore_permissions after its own checks. safe_exec: see CLAUDE.md.

APPROVED = "PO Approved - Ready for SAP"
KG_TOLERANCE = 0  # SAP: "Released quantity exceeds open quantity"

user = frappe.session.user
so_name = (frappe.form_dict.get("sales_order") or "").strip()
raw = frappe.form_dict.get("lines") or "[]"
lines = json.loads(raw) if isinstance(raw, str) else raw

if not so_name or not frappe.db.exists("Sales Order", so_name):
    frappe.throw("Order %s was not found." % so_name)

so = frappe.get_doc("Sales Order", so_name)
if so.docstatus == 2:
    frappe.throw("Order %s is cancelled." % so_name)
if so.custom_po_status != APPROVED:
    frappe.throw("A pick list can only be made once the manager has approved the order.")

is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1
))
mine = frappe.get_all("Sales Person", filters={"custom_user": user, "is_group": 0},
                      fields=["name", "custom_team_manager"], limit=1)
me = mine[0] if mine else None
managed = (frappe.db.get_value("User", user, "custom_managed_team") or "").strip()
if not managed and me:
    tok = (me.custom_team_manager or "").strip()
    if tok and me.name.strip().lower().startswith(tok.lower()):
        managed = tok
rep = so.custom_sales_person or ""
rep_team = (frappe.db.get_value("Sales Person", rep, "custom_team_manager") or "").strip() if rep else ""

if not (is_sys or (me and me.name == rep) or (managed and managed == rep_team)):
    frappe.throw("Only the order's rep or their manager can make its pick list.")


def ordered_of(it):
    rolls = frappe.utils.cint(it.custom_rolls)
    if rolls > 0:
        return rolls
    if frappe.utils.cint(it.custom_loose_belts) > 0:
        return 0
    return frappe.utils.flt(it.qty)


def kg_follows_qty(it):
    if frappe.utils.cint(it.custom_rolls) > 0:
        return False
    return (it.stock_uom or it.uom or "").strip().lower() in ("kg", "kgs")


def ordered_kg(it):
    w = frappe.utils.flt(it.custom_total_weight)
    if w > 0:
        return w
    return frappe.utils.flt(it.qty) if kg_follows_qty(it) else 0


def kg_per_roll(it):
    rolls = frappe.utils.cint(it.custom_rolls)
    if rolls <= 0:
        return 0
    total = frappe.utils.flt(it.custom_total_weight)
    if frappe.utils.cint(it.custom_loose_belts) == 0 and total > 0:
        return total / rolls
    return frappe.utils.flt(frappe.db.get_value("Item", it.item_code, "custom_weight_per_roll"))


already = {}
already_kg = {}
for pl in frappe.get_all("Manna Pick List",
                         filters={"sales_order": so_name, "status": "Submitted"}, pluck="name"):
    for r in frappe.get_all("Manna Pick List Item",
                            filters={"parent": pl, "parenttype": "Manna Pick List"},
                            fields=["sales_order_item", "picked_qty", "picked_kg"]):
        already[r.sales_order_item] = already.get(r.sales_order_item, 0) + frappe.utils.flt(r.picked_qty)
        already_kg[r.sales_order_item] = already_kg.get(r.sales_order_item, 0) + frappe.utils.flt(r.picked_kg)

by_name = {}
for it in so.items:
    by_name[it.name] = it

rows = []
seen = {}
for l in lines:
    key = str(l.get("sales_order_item") or "")
    if key not in by_name:
        frappe.throw("A product that is not on order %s cannot be picked." % so_name)
    if key in seen:
        frappe.throw("%s is on the list twice." % by_name[key].item_name)
    seen[key] = 1
    it = by_name[key]
    q = frappe.utils.flt(l.get("picked_qty"))
    remaining = ordered_of(it) - already.get(key, 0)
    if q <= 0:
        frappe.throw("Enter how much of %s to pick." % it.item_name)
    if q > remaining + 0.0001:
        frappe.throw("%s: only %s left to pick on this order." % (it.item_name, remaining))
    left_kg = max(ordered_kg(it) - already_kg.get(key, 0), 0)
    if kg_follows_qty(it):
        kg = q
    elif frappe.utils.cint(it.custom_loose_belts) == 0 and abs(q - remaining) < 0.0001:
        kg = left_kg
    else:
        kg = q * kg_per_roll(it)
    kg = frappe.utils.flt(kg, 3)
    if kg <= 0:
        frappe.throw("%s has no weight per roll - set it on the item before picking." % it.item_name)
    max_kg = frappe.utils.flt(left_kg * (1 + KG_TOLERANCE), 3)
    if kg > max_kg + 0.0005:
        frappe.throw("%s: %s kg is more than this order has left (%s kg). SAP cannot invoice more than the order holds."
                     % (it.item_name, kg, max_kg))
    rows.append({
        "sales_order_item": key,
        "item_code": it.item_code,
        "item_name": it.item_name,
        # Tread rubber's stock_uom is Kg while its qty is rolls.
        "unit": "rolls" if frappe.utils.cint(it.custom_rolls) > 0 else (it.stock_uom or it.uom or ""),
        "ordered_qty": ordered_of(it),
        "available_qty": frappe.utils.flt(l.get("available_qty")),
        "picked_qty": q,
        "picked_kg": frappe.utils.flt(kg, 3),
    })

if not rows:
    frappe.throw("Tick at least one product to pick.")

doc = frappe.get_doc({
    "doctype": "Manna Pick List",
    "sales_order": so_name,
    "customer": so.customer,
    "customer_name": so.customer_name,
    "sales_person": rep,
    "team": rep_team,
    "status": "Submitted",
    "picked_on": frappe.utils.now(),
    "picked_by": user,
    "items": rows,
})
doc.insert(ignore_permissions=True)
frappe.response["message"] = {"name": doc.name}
