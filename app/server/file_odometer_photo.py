# Frappe Server Script
#   Name          : manna_file_odometer_photo
#   Script Type   : DocType Event
#   Reference Doc : File
#   DocType Event : After Insert
#
# The other half of manna_trip_odometer_photos (Trip, Before Save): the photo
# that arrives AFTER the leg was saved.
#
# On a weak signal the phone gives up waiting for upload_file and saves the leg
# with no photo; Frappe finishes storing the file seconds or minutes later
# (TRP-00615: 14 s, TRP-00630: 32 s, TRP-00290: 3½ min). Nothing on the phone
# is listening by then, so the file is attached to the Trip and to no leg.
#
# When a rep's start_odo*/end_odo* photo lands on their own Trip, it goes onto
# the trip's LAST leg if that leg is an odometer leg missing exactly that photo
# and the trip was saved in the last 10 minutes — started and still running
# for a start photo, ended for an end photo.
#
# Only the last leg, because the happy path passes through here too: every
# photo is uploaded while its dialog is still open, before the leg is started
# or ended. At that moment an OLDER leg that ended without a photo is still
# lying there, and handing it the new leg's photo would put a wrong picture on
# a pay claim — worse than a missing one. The late arrivals seen so far all
# belonged to the last leg. Anything this leaves, HR attaches by hand.
#
# Written with frappe.db.set_value on the child row rather than a Trip save, so
# it does not re-run the Trip's validation or move its `modified` under a
# phone that is about to write. A later stale write from the phone cannot wipe
# it: manna_trip_odometer_photos keeps any photo already on a leg.
#
# This runs for EVERY file uploaded to the site, so it leaves at the first test
# that fails and never raises: a broken photo link must not break uploads.

try:
    fname = doc.file_name or ""
    slot = None
    if fname.startswith("start_odo"):
        slot = "start_odometer_photo"
    elif fname.startswith("end_odo"):
        slot = "end_odometer_photo"

    if (
        slot
        and doc.attached_to_doctype == "Trip"
        and doc.attached_to_name
        and not doc.attached_to_field
        and doc.file_url
    ):
        trip = frappe.db.get_value(
            "Trip", doc.attached_to_name, ["owner", "modified"], as_dict=True
        )
        if trip and trip.owner == doc.owner:
            since = frappe.utils.add_to_date(frappe.utils.now_datetime(), minutes=-10)
            legs = frappe.get_all(
                "Trip Vehicle Leg",
                filters={"parent": doc.attached_to_name, "parenttype": "Trip"},
                fields=[
                    "name", "idx", "has_odometer", "end_odometer",
                    "start_odometer_photo", "end_odometer_photo",
                ],
                order_by="idx asc",
                limit_page_length=0,
            )

            already = False
            for l in legs:
                if l.start_odometer_photo == doc.file_url or l.end_odometer_photo == doc.file_url:
                    already = True

            # When did the last leg start or end? Neither is on the row: a
            # child's `creation` is copied from the Trip, so it is when the
            # TRIP began, and custom_end_time is the phone's clock. The Trip's
            # own `modified` is the server's record of the save that did it.
            recent = frappe.utils.get_datetime(trip.modified) >= since

            target = None
            if legs and not already and recent:
                last = legs[-1]
                is_open = not (last.end_odometer or 0) > 0
                if last.has_odometer and not last.get(slot):
                    # A start photo belongs to a leg still running; an end
                    # photo to one that has just closed. The reverse — a start
                    # photo arriving for an ended leg — is the next leg's
                    # photo, uploaded before that leg is saved.
                    if slot == "start_odometer_photo" and is_open:
                        target = last.name
                    if slot == "end_odometer_photo" and not is_open:
                        target = last.name

            if target:
                frappe.db.set_value(
                    "Trip Vehicle Leg", target, slot, doc.file_url,
                    update_modified=False,
                )
except Exception:
    frappe.log_error(title="manna_file_odometer_photo")
