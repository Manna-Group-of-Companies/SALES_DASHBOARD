# Frappe Server Script
#   Name          : manna_pick_list_approve
#   Script Type   : API
#   API Method    : manna_pick_list_approve
#   Args (POST)   : name — the pick list (PICK-00001)
#
# The Production Manager approves a pick list (5 Nov 2026). A rep makes the
# list on the phone (manna_pick_list_submit); it then waits as "Pending" until
# a production manager approves it on the dashboard (Production → Pick Lists).
# The rep's phone shows which of their lists are approved.
#
# Refused unless:
#   - the caller is a production manager (User.custom_is_production_manager)
#     or System Manager — not the rep, not the sales manager;
#   - the list is Submitted (a cancelled list cannot be approved);
#   - it is not already approved (the first approval stands; nobody's name is
#     overwritten by a second click from another screen).
#
# The doctypes are only System Manager's; this script saves with
# ignore_permissions after its own checks. safe_exec: see CLAUDE.md.

user = frappe.session.user
name = (frappe.form_dict.get("name") or "").strip()

if not name or not frappe.db.exists("Manna Pick List", name):
    frappe.throw("Pick list %s was not found." % name)

is_sys = user == "Administrator" or bool(frappe.get_all(
    "Has Role", filters={"parent": user, "parenttype": "User", "role": "System Manager"}, limit=1
))
is_prod = frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_production_manager")) == 1
if not (is_sys or is_prod):
    frappe.throw("Only a Production Manager can approve a pick list.")

doc = frappe.get_doc("Manna Pick List", name)
if (doc.status or "Submitted") != "Submitted":
    frappe.throw("Pick list %s is cancelled and cannot be approved." % name)
if doc.approval_status == "Approved":
    who = frappe.db.get_value("User", doc.approved_by, "full_name") or doc.approved_by
    frappe.throw("Pick list %s was already approved by %s." % (name, who))

doc.approval_status = "Approved"
doc.approved_by = user
doc.approved_on = frappe.utils.now()
doc.save(ignore_permissions=True)

frappe.response["message"] = {
    "name": doc.name,
    "approval_status": doc.approval_status,
    "approved_by": user,
    "approved_by_name": frappe.db.get_value("User", user, "full_name") or user,
    "approved_on": str(doc.approved_on),
}
