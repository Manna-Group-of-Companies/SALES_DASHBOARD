# Frappe Server Script
#   Name          : manna_trip_odometer_photos
#   Script Type   : DocType Event
#   Reference Doc : Trip
#   DocType Event : Before Save
#
# A rep's odometer photo must never be stored on the Trip and yet missing from
# the leg — HR then sees "No photo" beside a picture that is sitting in the
# Trip's attachments. Until Sep 2026 that happened on about one leg in fifty
# (TRP-00260, 00290, 00307, 00328, 00615, 00616, 00630), in three ways:
#
#   1. The upload outlived the phone's 20 s timeout. Frappe kept the file, the
#      phone never heard its url, and saved the leg without it.
#   2. The rep ended the wrong leg — photo and all — then deleted that leg.
#   3. A photo that uploaded fine was dropped when the rep cancelled the leg
#      dialog, reopened it and did not retake it.
#
# Phones in the field run several app versions and are updated by side-loading,
# so this is the copy that fixes all of them at once. Three rules, all limited
# to the rep saving their OWN trip — HR's edits pass through untouched, so an
# HR "Delete photo" stays deleted:
#
#   KEEP   A rep's save can never blank a photo already on a leg. The phone
#          writes the whole legs table from what it last loaded; a photo that
#          arrived since (from HR, or from manna_file_odometer_photo) would be
#          wiped by that stale copy. No phone screen offers "remove photo", so
#          a blank from the rep is never deliberate.
#
#   MISFILED  (added 19 Nov 2026) A new start photo on an ENDED leg, with the
#          start reading unchanged, is the end photo in the wrong box: the
#          leg keeps its start photo and the new one goes to the end slot.
#
#   ADOPT  When a leg starts or ends in this save with no photo, take the
#          newest photo of that kind the rep uploaded to this Trip in the last
#          30 minutes that no leg is using. That is the photo the dialog was
#          for; it only failed to reach the leg.
#
# The late-arriving case — the file lands after this save — is handled by
# manna_file_odometer_photo (File, After Insert).
#
# Straight-line code, no helper functions: server scripts are exec'd with `doc`
# in *locals*, so a nested `def` could not see it. Wrapped whole in try/except:
# a photo link is worth recovering but never worth refusing a rep's save for.

try:
    if frappe.session.user == doc.owner and not doc.is_new():
        stored = {}
        for r in frappe.get_all(
            "Trip Vehicle Leg",
            filters={"parent": doc.name, "parenttype": "Trip"},
            fields=[
                "name", "start_odometer", "start_odometer_photo",
                "end_odometer_photo", "end_odometer",
            ],
            limit_page_length=0,
        ):
            stored[r.name] = r

        # KEEP
        for leg in doc.legs:
            was = stored.get(leg.name) if leg.name else None
            if was:
                if was.start_odometer_photo and not leg.start_odometer_photo:
                    leg.start_odometer_photo = was.start_odometer_photo
                if was.end_odometer_photo and not leg.end_odometer_photo:
                    leg.end_odometer_photo = was.end_odometer_photo

        # MISFILED — a start photo sent for a leg that has ended is its END
        # photo. A camera cannot photograph the morning's reading in the
        # evening, so a "new start photo" on an ended leg is the closing
        # reading put in the wrong box. That is what the phone's Edit leg
        # dialog let happen: it showed "Start odometer photo" first, and a rep
        # who ended the leg without a photo opened Edit, photographed the
        # odometer into that first box, and replaced the morning's photo with
        # the evening's (TRP-00828, TRP-00849 three times, TRP-01098). HR then
        # saw an evening picture as the start and "no photo" at the end.
        #
        # So: keep the start photo the leg already had, and put the new one in
        # the end slot if that is empty. If the end slot is already filled the
        # new photo stays in the Trip's attachments, where HR's pages list it.
        # A deliberate start correction changes the start READING too
        # (TRP-00883), and that passes through untouched.
        for leg in doc.legs:
            was = stored.get(leg.name) if leg.name else None
            if (
                was
                and was.start_odometer_photo
                and leg.start_odometer_photo
                and leg.start_odometer_photo != was.start_odometer_photo
                and (leg.end_odometer or 0) > 0
                and frappe.utils.flt(leg.start_odometer) == frappe.utils.flt(was.start_odometer)
            ):
                sent = leg.start_odometer_photo
                leg.start_odometer_photo = was.start_odometer_photo
                if not leg.end_odometer_photo:
                    leg.end_odometer_photo = sent

        # ADOPT
        used = set()
        for leg in doc.legs:
            if leg.start_odometer_photo:
                used.add(leg.start_odometer_photo)
            if leg.end_odometer_photo:
                used.add(leg.end_odometer_photo)

        since = frappe.utils.add_to_date(frappe.utils.now_datetime(), minutes=-30)
        recent = frappe.get_all(
            "File",
            filters=[
                ["attached_to_doctype", "=", "Trip"],
                ["attached_to_name", "=", doc.name],
                ["owner", "=", doc.owner],
                ["creation", ">=", since],
            ],
            fields=["file_url", "file_name"],
            order_by="creation desc",
            limit_page_length=50,
        )

        for leg in doc.legs:
            if not leg.has_odometer:
                continue
            was = stored.get(leg.name) if leg.name else None

            # A leg that did not exist before this save has just been started.
            if not was and not leg.start_odometer_photo:
                for f in recent:
                    if (f.file_name or "").startswith("start_odo") and f.file_url not in used:
                        leg.start_odometer_photo = f.file_url
                        used.add(f.file_url)
                        break

            # A closing reading appearing in this save means the leg just ended.
            ended_now = (leg.end_odometer or 0) > 0 and (not was or not (was.end_odometer or 0) > 0)
            if ended_now and not leg.end_odometer_photo:
                for f in recent:
                    if (f.file_name or "").startswith("end_odo") and f.file_url not in used:
                        leg.end_odometer_photo = f.file_url
                        used.add(f.file_url)
                        break
except Exception:
    frappe.log_error(title="manna_trip_odometer_photos")
