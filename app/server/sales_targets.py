# Frappe Server Script
#   Name          : manna_sales_targets
#   Script Type   : API
#   API Method    : manna_sales_targets
#   Args (GET)    : month ("Jan".."Dec"), year (int), team (optional, GM only)
#
# Monthly sales targets and what was achieved against them. Both apps call
# this and render what it returns, so the rule lives here once rather than in
# Dart and TypeScript twice (asked for 3 Nov 2026).
#
# ACHIEVED MEANS INVOICED. A line counts when SAP has raised the A/R invoice
# that carried it — `Sales Order Item.custom_sap_invoice`, written by the SAP
# order sync (sap-order-sync/README.md, PASS B) — and that invoice is dated in
# the target's month. An approved order that has not been invoiced counts for
# nothing; the month an order was placed in does not matter. Money is the
# line's `amount` (before GST); tonnes are `custom_total_weight` / 1000.
# A cancelled order (docstatus 2) never counts. Lead Orders are not read:
# they become Sales Orders before SAP sees them, and are invoiced there.
#
# WHO SEES WHAT. Read through this script because `Sales Order Item` answers
# 403 to a rep's phone, and so that nobody's scope depends on the client:
#   GM (User.custom_is_general_manager) or System Manager: every team, or the
#     one named by `team`.
#   A team manager (User.custom_managed_team, or — as the dashboard reads it —
#     a Sales Person whose name begins with its own team token): their team.
#   Anyone else with a Sales Person: themselves.
# A team's manager is never a row: targets are for reps only.
# `can_edit` says whose target this caller may set; manna_sales_target_guard
# enforces the same thing on save.
#
# safe_exec: no frappe.get_roles / parse_json / hasattr — see CLAUDE.md.

MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

user = frappe.session.user
month = (frappe.form_dict.get("month") or "").strip()
year = frappe.utils.cint(frappe.form_dict.get("year"))
want_team = (frappe.form_dict.get("team") or "").strip()

if month not in MONTHS or year < 2000:
    frappe.throw("month must be Jan..Dec and year a four-digit year")

u = frappe.db.get_value(
    "User", user, ["custom_managed_team", "custom_is_general_manager"], as_dict=True
) or {}
is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1
))
is_gm = is_sys or frappe.utils.cint(u.get("custom_is_general_manager")) == 1

mine = frappe.get_all(
    "Sales Person",
    filters={"custom_user": user, "is_group": 0},
    fields=["name", "custom_team_manager"],
    limit=1,
)
me = mine[0] if mine else None

managed = (u.get("custom_managed_team") or "").strip()
if not managed and me:
    tok = (me.custom_team_manager or "").strip()
    if tok and me.name.strip().lower().startswith(tok.lower()):
        managed = tok

people = frappe.get_all(
    "Sales Person",
    filters={"is_group": 0, "enabled": 1},
    fields=["name", "custom_team_manager", "custom_company", "custom_user"],
    order_by="name asc",
)

# Targets are set for reps only (3 Nov 2026): a team's own manager is left
# out. A manager is a Sales Person whose user manages that team, or whose name
# begins with the team token (`Pareeth Kb` for `Pareeth`) — as the apps read it.
mgr_users = {}
for m in frappe.get_all("User", filters={"custom_managed_team": ["is", "set"]},
                        fields=["name", "custom_managed_team"]):
    mgr_users[m.name] = (m.custom_managed_team or "").strip()


def is_manager(p):
    tok = (p.custom_team_manager or "").strip()
    if not tok:
        return False
    if p.custom_user and mgr_users.get(p.custom_user) == tok:
        return True
    return p.name.strip().lower().startswith(tok.lower())


people = [p for p in people if not is_manager(p)]

if is_gm:
    scope = [p for p in people if (p.custom_team_manager or "").strip()
             and (not want_team or (p.custom_team_manager or "").strip() == want_team)]
    can_edit = []
elif managed:
    scope = [p for p in people if (p.custom_team_manager or "").strip() == managed]
    can_edit = [p.name for p in scope]
elif me:
    scope = [p for p in people if p.name == me.name]
    can_edit = []
else:
    scope = []
    can_edit = []

reps = [p.name for p in scope]
mi = MONTHS.index(month) + 1
first = "%04d-%02d-01" % (year, mi)
last = str(frappe.utils.get_last_day(first))

targets = {}
if reps:
    for t in frappe.get_all(
        "Sales Target",
        filters={"sales_person": ["in", reps], "month": month, "year": year},
        fields=["name", "sales_person", "target_amount", "target_unit"],
    ):
        targets[t.sales_person] = t

lines_by_rep = {}
if reps:
    items = frappe.get_all(
        "Sales Order Item",
        filters={
            "parenttype": "Sales Order",
            "custom_sap_invoice": ["is", "set"],
            "custom_sap_invoice_date": ["between", [first, last]],
        },
        fields=["parent", "idx", "item_name", "amount", "custom_total_weight",
                "custom_sap_invoice", "custom_sap_invoice_date"],
        order_by="custom_sap_invoice_date asc, parent asc, idx asc",
        limit_page_length=0,
    )
    parents = list({i.parent: 1 for i in items}.keys())
    heads = {}
    if parents:
        for h in frappe.get_all(
            "Sales Order",
            filters={"name": ["in", parents], "docstatus": ["!=", 2],
                     "custom_sales_person": ["in", reps]},
            fields=["name", "custom_sales_person", "customer_name"],
            limit_page_length=0,
        ):
            heads[h.name] = h
    for i in items:
        h = heads.get(i.parent)
        if not h:
            continue
        lines_by_rep.setdefault(h.custom_sales_person, []).append({
            "order": i.parent,
            "customer_name": h.customer_name or "",
            "item_name": i.item_name or "",
            "invoice": i.custom_sap_invoice,
            "invoice_date": str(i.custom_sap_invoice_date),
            "amount": frappe.utils.flt(i.amount),
            "kg": frappe.utils.flt(i.custom_total_weight),
        })

rows = []
for p in scope:
    t = targets.get(p.name)
    lines = lines_by_rep.get(p.name, [])
    rows.append({
        "sales_person": p.name,
        "team": (p.custom_team_manager or "").strip(),
        "currency": "AED" if p.custom_company == "Manna Tyres UAE" else "INR",
        "target_name": t.name if t else None,
        "target_amount": frappe.utils.flt(t.target_amount) if t else 0,
        "target_unit": (t.target_unit or "Currency") if t else "Currency",
        "invoiced_amount": sum([l["amount"] for l in lines]),
        "invoiced_kg": sum([l["kg"] for l in lines]),
        "lines": lines,
    })

frappe.response["message"] = {
    "month": month,
    "year": year,
    "managed_team": managed,
    "is_gm": 1 if is_gm else 0,
    "can_edit": can_edit,
    "rows": rows,
}
