# Frappe Server Script
#   Name          : manna_order_seen
#   Script Type   : API
#   API Method    : manna_order_seen
#   Args (POST)   : order (Sales Order name)
#
# The manager has opened an order waiting for them (10 Nov 2026). The rep's
# app shows it as a double tick, the way a chat shows a message as read.
#
# Written once, by a sales manager, GM or System Manager, only while the order
# waits for the manager. Written with update_modified=False: opening an order
# is not a change, and a new `modified` would make the rep's next save of
# their own order fail as "changed by someone else".
#
# Needs two Custom Fields on Sales Order (order_seen_fields.json):
#   custom_manager_seen_on (Datetime), custom_manager_seen_by (Data).
#
# safe_exec: no frappe.get_roles / parse_json / hasattr.

user = frappe.session.user
order = (frappe.form_dict.get("order") or "").strip()
if not order or not frappe.db.exists("Sales Order", order):
    frappe.throw("No such order.")

roles = frappe.get_all("Has Role", filters={"parent": user, "parenttype": "User"}, pluck="role")
allowed = (
    user == "Administrator"
    or "System Manager" in roles
    or "Sales Manager" in roles
    or frappe.utils.cint(frappe.db.get_value("User", user, "custom_is_general_manager")) == 1
)
if not allowed:
    frappe.throw("Only a manager can mark an order seen.", frappe.PermissionError)

row = frappe.db.get_value("Sales Order", order,
                          ["custom_po_status", "custom_manager_seen_on", "custom_sales_person"], as_dict=True)
waiting = row.custom_po_status in ("Pending Approval", "PO Uploaded - Pending Approval", "Pending Rate Approval")

# A manager opening their own order as its rep is not a manager reading it.
mine = frappe.get_all("Sales Person", filters={"custom_user": user, "is_group": 0}, pluck="name", limit=1)
own = bool(mine) and mine[0] == row.custom_sales_person

if waiting and not own and not row.custom_manager_seen_on:
    now = frappe.utils.now()
    who = frappe.db.get_value("User", user, "full_name") or user
    frappe.db.set_value("Sales Order", order,
                        {"custom_manager_seen_on": now, "custom_manager_seen_by": who},
                        update_modified=False)
    frappe.response["message"] = {"seen_on": now, "seen_by": who}
else:
    frappe.response["message"] = {"seen_on": row.custom_manager_seen_on, "unchanged": True}
