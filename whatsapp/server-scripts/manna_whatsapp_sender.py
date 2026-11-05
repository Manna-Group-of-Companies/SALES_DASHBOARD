# Server Script — paste into ERPNext Desk exactly as it is here.
#
#   Script Type       Scheduler Event
#   Event Frequency   Cron
#   Cron Format       * * * * *          (every minute)
#   Name              manna_whatsapp_sender
#
# Sends what `manna_whatsapp_queue` queued, through the WhatsApp Cloud API
# (Meta). The access token is read from `Manna WhatsApp Settings` here and
# nowhere else — never in the PWA, never in the APK, never on the SAP server.
#
# Status of a `Manna WhatsApp Message`:
#   Queued   waiting for this script
#   Sending  claimed by a run. Left alone if a run dies mid-send, so a
#            customer is never sent the same message twice. Fix by hand.
#   Sent     Meta accepted it; wa_message_id is Meta's id
#   Failed   3 attempts refused; `error` holds Meta's own words
#   Skipped  never sent, on purpose; `error` says why (no phone, demo
#            customer, test mode, invalid number)

MAX_ATTEMPTS = 3
BATCH = 20


def normalise(phone):
    # Indian numbers to Meta's format: country code, digits only, no "+".
    digits = "".join([c for c in (phone or "") if c in "0123456789"])
    if len(digits) == 10 and digits[0] in "6789":
        return "91" + digits
    if len(digits) == 11 and digits[0] == "0":
        return "91" + digits[1:]
    if len(digits) == 12 and digits.startswith("91"):
        return digits
    if len(digits) == 13 and digits.startswith("091"):
        return digits[1:]
    return ""


def finish(name, values):
    frappe.db.set_value("Manna WhatsApp Message", name, values)
    frappe.db.commit()


s = frappe.get_doc("Manna WhatsApp Settings")
if s.enabled:
    token = s.get_password("access_token", raise_exception=False)
    version = (s.api_version or "v21.0").strip()
    lang = (s.language_code or "en").strip()
    allowed = []
    for line in (s.test_numbers or "").replace(",", "\n").split("\n"):
        n = normalise(line)
        if n:
            allowed.append(n)

    rows = frappe.get_all(
        "Manna WhatsApp Message",
        filters={"status": "Queued"},
        fields=["name", "customer", "phone", "template", "params", "attempts"],
        order_by="creation asc",
        limit_page_length=BATCH,
    )
    for r in rows:
        to = normalise(r.phone)
        why = ""
        if (r.customer or "").startswith("DEMO -"):
            why = "demo customer - never messaged"
        elif not to:
            why = "no usable phone number on the customer (%s)" % (r.phone or "empty")
        elif s.test_mode and to not in allowed:
            why = "test mode - %s is not in the test numbers" % to
        elif not token or not s.phone_number_id:
            why = "settings incomplete - no access token or phone number id"
        if why:
            finish(r.name, {"status": "Skipped", "error": why})
            continue

        finish(r.name, {"status": "Sending", "attempts": (r.attempts or 0) + 1})

        params = json.loads(r.params or "[]")
        body = {
            "messaging_product": "whatsapp",
            "to": to,
            "type": "template",
            "template": {
                "name": r.template,
                "language": {"code": lang},
                "components": [{
                    "type": "body",
                    "parameters": [{"type": "text", "text": p} for p in params],
                }],
            },
        }
        try:
            res = frappe.make_post_request(
                "https://graph.facebook.com/%s/%s/messages" % (version, s.phone_number_id),
                headers={
                    "Authorization": "Bearer " + token,
                    "Content-Type": "application/json",
                },
                data=json.dumps(body),
            )
            msg_id = ""
            if res and res.get("messages"):
                msg_id = res["messages"][0].get("id") or ""
            finish(r.name, {
                "status": "Sent",
                "wa_message_id": msg_id,
                "sent_at": frappe.utils.now_datetime(),
                "error": "",
            })
        except Exception as e:
            # Meta puts the reason in the response BODY; the exception only
            # has the status code.
            detail = "%s" % e
            resp = frappe.flags.integration_request
            if resp is not None:
                try:
                    detail = resp.text[:1000]
                except Exception:
                    pass
            done = ((r.attempts or 0) + 1) >= MAX_ATTEMPTS
            finish(r.name, {"status": "Failed" if done else "Queued", "error": detail})
