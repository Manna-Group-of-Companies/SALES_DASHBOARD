# Server Script — paste into ERPNext Desk exactly as it is here.
#
#   Script Type    DocType Event
#   Reference Doc  SAP Invoice
#   Event          After Save
#   Name           manna_whatsapp_payment
#
# Queues "payment received" for the customer (10 Nov 2026) when an SAP
# Invoice's `paid` goes up. Both the credit sync and B1if's Z.erpinv
# (manna_sap_invoice_sync, the moment an incoming payment is posted in SAP)
# save that row, so this hears every payment SAP records, whichever arrived
# first. Like manna_whatsapp_queue it never calls WhatsApp itself;
# manna_whatsapp_sender sends it within the minute.
#
# Only a change is messaged. The first time a row is created (the first sync
# of an invoice that was already part-paid) there is nothing "before" to
# compare, so nothing is sent: old payments are never announced.
#
# One message per invoice per paid total, ever: the dedupe key carries the new
# paid figure, so a re-sync of the same payment is not a second message, and
# a later part-payment is.
#
# safe_exec: no f-strings, no frappe.get_single. A failure is logged and
# swallowed — a WhatsApp message is never worth failing a sync over.

TEMPLATE_PAYMENT = "manna_payment_received"


def clean(text, limit):
    s = " ".join(("%s" % (text or "")).split())
    if len(s) > limit:
        s = s[: limit - 3] + "..."
    return s or "-"


try:
    enabled = frappe.db.get_value(
        "Manna WhatsApp Settings", "Manna WhatsApp Settings", "enabled"
    )
    before = doc.get_doc_before_save()
    if enabled and before:
        old_paid = frappe.utils.flt(before.get("paid"), 2)
        new_paid = frappe.utils.flt(doc.get("paid"), 2)
        received = frappe.utils.flt(new_paid - old_paid, 2)
        # Rounding noise from SAP's decimals is not a payment.
        if received >= 1:
            key = "%s|Payment Received|%s" % (doc.name, new_paid)
            if not frappe.db.exists("Manna WhatsApp Message", {"dedupe_key": key}):
                cust = frappe.db.get_value(
                    "Customer", doc.customer,
                    ["customer_name", "custom_phone", "mobile_no"], as_dict=True
                ) or {}
                frappe.get_doc({
                    "doctype": "Manna WhatsApp Message",
                    "dedupe_key": key,
                    "customer": doc.customer,
                    "event": "Payment Received",
                    "delivery_note": "",
                    "phone": cust.get("custom_phone") or cust.get("mobile_no") or "",
                    "template": TEMPLATE_PAYMENT,
                    "params": json.dumps([
                        clean(cust.get("customer_name") or doc.customer, 100),
                        clean(frappe.utils.fmt_money(received, currency="INR"), 40),
                        clean(doc.get("invoice_no"), 20),
                        clean(frappe.utils.fmt_money(doc.get("balance"), currency="INR"), 40),
                    ]),
                    "status": "Queued",
                    "attempts": 0,
                }).insert(ignore_permissions=True)
except Exception as e:
    frappe.log_error(title="manna_whatsapp_payment %s" % doc.name, message="%s" % e)
