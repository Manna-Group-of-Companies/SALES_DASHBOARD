# Server Script — paste into ERPNext Desk exactly as it is here.
#
#   Script Type    DocType Event
#   Reference Doc  Sales Order
#   Event          After Save
#   Name           manna_whatsapp_queue
#
# Puts a WhatsApp message for the customer in the queue
# (`Manna WhatsApp Message`) when an order:
#
#   1. is approved          custom_po_status moves to PO Approved - Ready for SAP
#                           -> "thank you for your order": number, items, amount
#   2. gets a SAP delivery  a new "DN <n> (<date>)" appears in any line's
#                           custom_hitech_delivery_refs (written by the SAP
#                           order sync, PASS B — no change to the sync needed)
#
# Nothing is sent when the rep places the order — only once it is approved
# (decided 5 Nov 2026).
#
# It never calls WhatsApp itself. `manna_whatsapp_sender` does that, once a
# minute, so a slow or failing Meta API can never slow or break a rep's save.
# Every message is also a row a manager can read in Desk.
#
# One message per (order, event, delivery note), ever: `dedupe_key` is unique.
# A rejected order sent back for approval does not tell the customer twice.
#
# Runs in safe_exec. No `re`, no `set`, no f-strings, no frappe.get_single —
# see CLAUDE.md's traps. Anything that goes wrong here is swallowed: a
# WhatsApp message is never worth failing an order save over.

APPROVED = "PO Approved - Ready for SAP"

TEMPLATE_APPROVED = "manna_order_confirmed"
TEMPLATE_DELIVERY = "manna_order_dispatched"


def clean(text, limit):
    # Meta refuses a parameter with a newline, a tab or more than four spaces
    # in a row, and an empty one.
    s = " ".join(("%s" % (text or "")).split())
    if len(s) > limit:
        s = s[: limit - 3] + "..."
    return s or "-"


def dn_numbers(refs):
    # "DN 4 (18-09-2026), DN 7 (20-09-2026)" -> {"4": "18-09-2026", "7": "20-09-2026"}
    out = {}
    for part in (refs or "").split(","):
        p = part.strip()
        if not p.startswith("DN "):
            continue
        rest = p[3:].strip()
        num = rest.split(" ")[0].strip()
        date = ""
        if "(" in rest and ")" in rest:
            date = rest[rest.index("(") + 1 : rest.index(")")]
        if num:
            out[num] = date
    return out


def all_dns(order):
    out = {}
    if not order:
        return out
    for it in order.get("items") or []:
        found = dn_numbers(it.get("custom_hitech_delivery_refs"))
        for k in found:
            out[k] = found[k]
    return out


def qty_text(it):
    rolls = it.get("custom_rolls") or 0
    if rolls:
        return "%s rolls" % frappe.utils.flt(rolls, 2)
    kg = it.get("custom_total_weight") or 0
    if kg:
        return "%s kg" % frappe.utils.flt(kg, 2)
    return "%s %s" % (frappe.utils.flt(it.get("qty"), 2), it.get("uom") or "")


def item_summary(order, only_dn):
    parts = []
    for it in order.get("items") or []:
        if only_dn and only_dn not in dn_numbers(it.get("custom_hitech_delivery_refs")):
            continue
        name = it.get("item_name") or it.get("item_code")
        if only_dn:
            parts.append(name)
        else:
            parts.append("%s - %s" % (name, qty_text(it)))
    return "; ".join(parts)


def queue(event, ref, template, params):
    key = "%s|%s|%s" % (doc.name, event, ref or "")
    if frappe.db.exists("Manna WhatsApp Message", {"dedupe_key": key}):
        return
    cust = frappe.db.get_value(
        "Customer", doc.customer, ["customer_name", "custom_phone", "mobile_no"], as_dict=True
    ) or {}
    phone = cust.get("custom_phone") or cust.get("mobile_no") or ""
    frappe.get_doc({
        "doctype": "Manna WhatsApp Message",
        "dedupe_key": key,
        "sales_order": doc.name,
        "customer": doc.customer,
        "event": event,
        "delivery_note": ref or "",
        "phone": phone,
        "template": template,
        "params": json.dumps(params),
        "status": "Queued",
        "attempts": 0,
    }).insert(ignore_permissions=True)


try:
    enabled = frappe.db.get_value(
        "Manna WhatsApp Settings", "Manna WhatsApp Settings", "enabled"
    )
    if enabled and doc.docstatus < 2:
        before = doc.get_doc_before_save()
        status = doc.get("custom_po_status") or ""
        old = (before.get("custom_po_status") if before else "") or ""
        customer_name = clean(doc.get("customer_name") or doc.customer, 100)
        company = clean(doc.get("custom_company") or doc.get("company"), 100)
        order_date = frappe.utils.formatdate(doc.get("transaction_date"), "dd-MM-yyyy")

        # 1. Approved: thank the customer, with the order's number, items
        # and amount.
        if status == APPROVED and old != APPROVED:
            queue("Order Approved", "", TEMPLATE_APPROVED, [
                customer_name,
                company,
                doc.name,
                order_date,
                clean(item_summary(doc, None), 700),
                clean(frappe.utils.fmt_money(doc.get("grand_total"), currency="INR"), 40),
            ])

        # 2. A delivery note SAP did not have the last time this order saved.
        if status == APPROVED and before:
            now_dns = all_dns(doc)
            old_dns = all_dns(before)
            for num in now_dns:
                if num in old_dns:
                    continue
                queue("Delivery Created", num, TEMPLATE_DELIVERY, [
                    customer_name,
                    doc.name,
                    num,
                    clean(now_dns[num], 20),
                    clean(item_summary(doc, num), 700),
                ])
except Exception as e:
    frappe.log_error(title="manna_whatsapp_queue %s" % doc.name, message="%s" % e)
