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


def qty_text(it):
    # "2 rolls", not "2.0 rolls": whole numbers without the decimal.
    rolls = frappe.utils.flt(it.get("custom_rolls"), 2)
    if rolls:
        n = ("%d" % rolls) if rolls == int(rolls) else ("%s" % rolls)
        return n + (" roll" if rolls == 1 else " rolls")
    kg = frappe.utils.flt(it.get("custom_total_weight"), 2)
    if kg:
        return (("%d" % kg) if kg == int(kg) else ("%s" % kg)) + " kg"
    q = frappe.utils.flt(it.get("qty"), 2)
    return (("%d" % q) if q == int(q) else ("%s" % q)) + " " + (it.get("uom") or "")


# safe_exec runs this with the script's names in a separate locals dict: a
# function here cannot see `doc` or call another function defined here (found
# 10 Nov 2026 — "name 'qty_text' is not defined", so nothing was ever queued).
# So every helper above is a leaf that uses only its arguments and frappe, and
# the work below is done at the top level.
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

        # Every delivery note on the order now and before this save.
        now_dns = {}
        line_dns = []
        for it in doc.get("items") or []:
            found = dn_numbers(it.get("custom_hitech_delivery_refs"))
            line_dns.append([it, found])
            for k in found:
                now_dns[k] = found[k]
        old_dns = {}
        if before:
            for it in before.get("items") or []:
                found = dn_numbers(it.get("custom_hitech_delivery_refs"))
                for k in found:
                    old_dns[k] = found[k]

        # [event, ref, template, params]
        wanted = []

        # 1. Approved: thank the customer, with the order's number, items
        # and amount.
        if status == APPROVED and old != APPROVED:
            parts = []
            for pair in line_dns:
                it = pair[0]
                parts.append("%s - %s" % (it.get("item_name") or it.get("item_code"), qty_text(it)))
            wanted.append(["Order Approved", "", TEMPLATE_APPROVED, [
                customer_name,
                company,
                doc.name,
                order_date,
                clean("; ".join(parts), 700),
                clean(frappe.utils.fmt_money(doc.get("grand_total"), currency="INR"), 40),
            ]])

        # 2. A delivery note SAP did not have the last time this order saved.
        if status == APPROVED and before:
            for num in now_dns:
                if num in old_dns:
                    continue
                names = []
                for pair in line_dns:
                    if num in pair[1]:
                        names.append(pair[0].get("item_name") or pair[0].get("item_code"))
                wanted.append(["Delivery Created", num, TEMPLATE_DELIVERY, [
                    customer_name,
                    doc.name,
                    num,
                    clean(now_dns[num], 20),
                    clean("; ".join(names), 700),
                ]])

        if wanted:
            cust = frappe.db.get_value(
                "Customer", doc.customer, ["customer_name", "custom_phone", "mobile_no"], as_dict=True
            ) or {}
            phone = cust.get("custom_phone") or cust.get("mobile_no") or ""
            for w in wanted:
                key = "%s|%s|%s" % (doc.name, w[0], w[1] or "")
                if frappe.db.exists("Manna WhatsApp Message", {"dedupe_key": key}):
                    continue
                frappe.get_doc({
                    "doctype": "Manna WhatsApp Message",
                    "dedupe_key": key,
                    "sales_order": doc.name,
                    "customer": doc.customer,
                    "event": w[0],
                    "delivery_note": w[1] or "",
                    "phone": phone,
                    "template": w[2],
                    "params": json.dumps(w[3]),
                    "status": "Queued",
                    "attempts": 0,
                }).insert(ignore_permissions=True)
except Exception as e:
    frappe.log_error(title="manna_whatsapp_queue %s" % doc.name, message="%s" % e)
