# Frappe Server Script
#   Name          : manna_sales_target_guard
#   Script Type   : DocType Event
#   Reference Doc : Sales Target
#   DocType Event : Before Save
#
# Only a rep's own team manager sets that rep's target (3 Nov 2026), and only
# a rep has one — a manager is never given a target.
#
# `Sales User` carries create/write on Sales Target, so before this a rep could
# set their own target from a browser console, and any manager anybody's. The
# apps only offer the manager's own team; this is the backstop.
#
# The manager is matched the way manna_sales_targets matches them:
# User.custom_managed_team, or a Sales Person whose name begins with its own
# team token. System Manager (the integration user, Desk) is let through.
#
# Also: one target per rep per month, a known month, a known unit, no
# negative amount. set_by is stamped with the team token.

MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

user = frappe.session.user
is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1
))

if doc.month not in MONTHS:
    frappe.throw("Month must be one of Jan..Dec.")
if frappe.utils.cint(doc.year) < 2000:
    frappe.throw("Year must be a four-digit year.")
if (doc.target_unit or "Currency") not in ["Currency", "Tonnes"]:
    frappe.throw("Target unit must be Currency or Tonnes.")
if frappe.utils.flt(doc.target_amount) < 0:
    frappe.throw("A target cannot be negative.")

rep = frappe.db.get_value(
    "Sales Person", doc.sales_person, ["custom_team_manager", "custom_user"], as_dict=True
) or {}
rep_team = (rep.get("custom_team_manager") or "").strip()

# Targets are for reps only: a team's own manager never gets one.
rep_user_team = (frappe.db.get_value("User", rep.get("custom_user"), "custom_managed_team") or "").strip() \
    if rep.get("custom_user") else ""
if rep_team and (rep_user_team == rep_team
                 or doc.sales_person.strip().lower().startswith(rep_team.lower())):
    frappe.throw("%s manages the %s team; targets are set for reps only." % (doc.sales_person, rep_team))

if not is_sys:
    managed = (frappe.db.get_value("User", user, "custom_managed_team") or "").strip()
    if not managed:
        mine = frappe.get_all(
            "Sales Person",
            filters={"custom_user": user, "is_group": 0},
            fields=["name", "custom_team_manager"],
            limit=1,
        )
        if mine:
            tok = (mine[0].custom_team_manager or "").strip()
            if tok and mine[0].name.strip().lower().startswith(tok.lower()):
                managed = tok
    if not managed or managed != rep_team:
        frappe.throw("Only %s's team manager can set their target." % doc.sales_person)

dupe = frappe.get_all(
    "Sales Target",
    filters={"sales_person": doc.sales_person, "month": doc.month,
             "year": doc.year, "name": ["!=", doc.name or ""]},
    limit=1,
)
if dupe:
    frappe.throw("%s already has a target for %s %s (%s)."
                 % (doc.sales_person, doc.month, doc.year, dupe[0].name))

doc.set_by = rep_team
