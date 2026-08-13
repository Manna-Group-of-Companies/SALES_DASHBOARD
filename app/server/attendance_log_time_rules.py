# Frappe Server Script
#   Script Type   : DocType Event
#   Reference Doc : Attendance Log
#   DocType Event : Before Save
#
# The app blocks these windows too, but the app runs on a phone whose clock the
# rep controls. This is the copy that counts: every time written here comes from
# the server's own clock, so moving the phone forward or back changes nothing.
#
# Mirrors lib/core/attendance_rules.dart — change the two numbers in both places.
#
# Deliberately written as straight-line code with no helper functions: server
# scripts are exec'd with `doc` in *locals*, so a nested `def` would not be able
# to see it.

PUNCH_IN_FROM = 5 * 60           # 05:00
PUNCH_OUT_UNTIL = 21 * 60 + 30   # 21:30

server_now = frappe.utils.now_datetime()
now_stamp = server_now.strftime("%Y-%m-%d %H:%M:%S")
minute_now = server_now.hour * 60 + server_now.minute

# What this row already holds, read straight from the database so we are
# comparing against the stored day rather than anything the phone sent.
stored_in = None
stored_out = None
if not doc.is_new():
    stored = frappe.db.get_value(
        "Attendance Log", doc.name, ["punch_in_time", "punch_out_time"], as_dict=True
    )
    if stored:
        stored_in = stored.get("punch_in_time")
        stored_out = stored.get("punch_out_time")

# Compare to the second — the database keeps microseconds, the app does not.
stored_out_key = str(stored_out or "")[:19]
sent_out_key = str(doc.punch_out_time or "")[:19]

# The rules bind self-service only: a rep stamping their own attendance. An
# approver writing someone else's log is an approved Attendance Regularization,
# whose whole purpose is to record times other than "now", and which carries its
# own audit trail. The second check lets an approver fix their own day the same
# way.
linked_user = None
if doc.sales_person:
    linked_user = frappe.db.get_value("Sales Person", doc.sales_person, "custom_user")

self_service = linked_user and linked_user == frappe.session.user

if self_service and frappe.db.exists(
    "Attendance Regularization",
    {
        "sales_person": doc.sales_person,
        "attendance_date": doc.attendance_date,
        "status": "Approved",
    },
):
    self_service = False

if self_service:
    # ---- punch in ---------------------------------------------------------
    # Only the first stamp of the day is a punch-in; the punch-out later saves
    # this same row and must not be mistaken for one.
    #
    # Nothing here looks at yesterday: a day left open never blocks today's
    # punch-in. The app raises a banner for it the next morning instead.
    if doc.punch_in_time and not stored_in:
        if minute_now < PUNCH_IN_FROM:
            frappe.throw("Punch-in opens at 5:00 AM.")
        doc.punch_in_time = now_stamp
        doc.attendance_date = server_now.strftime("%Y-%m-%d")
        doc.status = "Punched In"

    # ---- punch out --------------------------------------------------------
    # Punching out again is allowed while the window is open, and the later
    # stamp simply replaces the earlier one as the official punch-out.
    if doc.punch_out_time and sent_out_key != stored_out_key:
        if minute_now > PUNCH_OUT_UNTIL:
            frappe.throw(
                "Punch-out closed at 9:30 PM. "
                "Request an Attendance Regularization for this day instead."
            )
        doc.punch_out_time = now_stamp
        doc.status = "Punched Out"

    # A rep cannot quietly erase a punch-out they already made.
    if stored_out and not doc.punch_out_time:
        doc.punch_out_time = stored_out
        doc.status = "Punched Out"

# ---- working hours --------------------------------------------------------
# Recomputed from whatever the two stamps ended up being, so a second punch-out
# (or an approved regularization) always leaves the hours consistent.
if doc.punch_in_time and doc.punch_out_time:
    started = frappe.utils.get_datetime(doc.punch_in_time)
    ended = frappe.utils.get_datetime(doc.punch_out_time)
    doc.working_hours = max(0, round((ended - started).total_seconds() / 3600.0, 2))
