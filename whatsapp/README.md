# WhatsApp messages to customers

The customer gets a WhatsApp message from the company's number at three points:

| # | When | Template | Who triggers it |
|---|---|---|---|
| 1 | A manager approves the order | `manna_order_confirmed` | Manager, from the dashboard or the app |
| 2 | The factory creates a **delivery** for it in SAP | `manna_order_dispatched` | The SAP order sync, once it sees the delivery note |
| 3 | A **payment** is posted against an invoice in SAP (10 Nov 2026) | `manna_payment_received` | The credit sync, or B1if's `Z.erpinv`, updating `SAP Invoice.paid` |

Nothing is sent when the rep places the order. The customer hears nothing
until a manager has approved it (decided 5 November 2026).

Both are sent **by ERPNext**, through Meta's WhatsApp Cloud API. Neither
app and not the SAP server holds the WhatsApp token. Nothing in `client/`,
`app/` or `sap-order-sync/` changes.

```
Sales Order saved ──► manna_whatsapp_queue (After Save) ──► Manna WhatsApp Message (Queued)
                                                                     │
                       manna_whatsapp_sender (every minute) ◄────────┘
                                     │
                                     └──► graph.facebook.com ──► customer's WhatsApp
```

**How the delivery is noticed.** The SAP order sync (PASS B) already writes
every live delivery note against an order line into
`custom_hitech_delivery_refs` — `"DN 4 (18-09-2026), DN 7 (...)"` — and that
write saves the Sales Order. The queue script compares the delivery notes
before and after the save. A new DN number is a new message. A cancelled
delivery never appears there (the sync skips `CancelStatus` other than `csNo`).

**Rules it keeps:**

- One message per order per event, and one per delivery note, ever (`dedupe_key`
  is unique). A rejected order sent back for approval does not message twice.
- `DEMO - …` customers are never messaged. See the demo team note.
- No phone number, or one that isn't a valid Indian mobile: **Skipped**, with
  the reason. The phone comes from the customer's `custom_phone` (then
  `mobile_no`).
- **Test mode** (on by default): only numbers in *Test Numbers* are messaged.
  Every other message is Skipped, so the queue logic can be watched on real
  orders before any customer is sent anything.
- A failure never blocks an order save. Meta's refusal is stored in `error`,
  retried up to 3 times, then **Failed**.

---

## 1. Meta: get the WhatsApp Business account (one-time, by the owner)

1. **Meta Business account** at business.facebook.com. Use the company's legal
   name and verify the business (*Security Centre → Start verification*). Use
   the GST certificate or the incorporation document. Verification takes 1–3 days.
2. **A phone number used only for the API.** A number already on the WhatsApp
   or WhatsApp Business *app* cannot be used until it is deleted from that app.
   Most firms take a new SIM or a landline (verification is by voice call).
3. developers.facebook.com → **Create app** → type *Business* → add the
   **WhatsApp** product → *API Setup* → add the number and verify it.
4. Note two values from *API Setup*: **Phone number ID** and **WhatsApp
   Business Account ID**.
5. **Permanent token:** business.facebook.com → *Settings → Users → System
   users* → add one (Admin) → *Assign assets* → the app and the WhatsApp
   account (full control) → *Generate token* with the permissions
   `whatsapp_business_messaging` and `whatsapp_business_management`, expiry
   **Never**. The temporary token on the API Setup page dies in 24 hours, so
   don't use it.
6. Add a payment method (*WhatsApp Manager → Payment settings*). Every
   template in this guide is **Utility** category, which is the cheap rate in
   India.
7. Set the display name and profile picture (*WhatsApp Manager → Phone numbers*).

**Customers must have agreed to get WhatsApp messages from you.** That is
Meta's policy. A rep asking at the first order ("We'll send order updates on
WhatsApp to this number, OK?") is enough. If customers block or report the
number, Meta lowers its quality rating and then its sending limit.

## 2. Meta: the two message templates

*WhatsApp Manager → Message templates → Create template.* Category
**Utility**, language **English** (`en`). The names must be exactly these. The
`{{n}}` order is fixed by the queue script.

**`manna_order_confirmed`**: sent on approval
```
Dear {{1}}, thank you for your order with {{2}}.

Order: {{3}}
Date: {{4}}
Items: {{5}}
Amount: {{6}}

Your order is confirmed. We will message you again when the goods are dispatched.
```
Sample values for review: `Sri Murugan Tyres`, `Manna Treads`,
`SAL-ORD-2026-00123`, `05-11-2026`, `PCR 165 Tread - 10 rolls`, `₹ 45,000.00`

**`manna_order_dispatched`**: sent when SAP has a delivery
```
Dear {{1}}, the goods for your order {{2}} have been dispatched.

Delivery note: {{3}}
Date: {{4}}
Items: {{5}}

Thank you for your business.
```
Samples: `Sri Murugan Tyres`, `SAL-ORD-2026-00123`, `4`, `18-09-2026`, `PCR 165 Tread`

Meta usually approves these within minutes to a day. To add a Malayalam
version, create the same names in language `ml` and set *Language Code* in the
settings. Changing the wording of an approved template is fine. Changing the
number or order of `{{n}}` means changing the queue script too.

**`manna_payment_received`**: sent when SAP records a payment
```
Dear {{1}}, we have received your payment of {{2}} against invoice {{3}}.

Balance on this invoice: {{4}}

Thank you.
```
Samples: `Sri Murugan Tyres`, `₹ 25,000.00`, `624`, `₹ 4,905.00`

## 3. ERPNext: two DocTypes (System Manager, Desk or the Composio connector)

**`Manna WhatsApp Settings`**: *Is Single* ✓, module *Selling*.
Permissions: System Manager only.

| Field | Type | Notes |
|---|---|---|
| `enabled` | Check | Master switch. Off = nothing is queued at all |
| `test_mode` | Check | Default **1** |
| `test_numbers` | Small Text | One number per line. Only these get messages while test mode is on |
| `phone_number_id` | Data | From Meta API Setup |
| `waba_id` | Data | WhatsApp Business Account ID. For reference only |
| `access_token` | Password | The permanent system-user token |
| `api_version` | Data | Default `v21.0` |
| `language_code` | Data | Default `en` |

**`Manna WhatsApp Message`**: module *Selling*, naming `hash`, *Track
Changes* off, sort by `creation` desc. Permissions: System Manager full; Sales
Manager read. Nobody else needs it, because the scripts insert with
`ignore_permissions`.

| Field | Type | Notes |
|---|---|---|
| `dedupe_key` | Data | **Unique** ✓, read only. `order\|event\|DN` |
| `sales_order` | Link → Sales Order | In list view, in standard filter |
| `customer` | Link → Customer | In list view |
| `event` | Select | `Order Approved` / `Delivery Created` / `Payment Received`. In list view |
| `delivery_note` | Data | SAP DN number, for event 3 |
| `phone` | Data | As it was on the customer when queued |
| `template` | Data | |
| `params` | Code (JSON) | The `{{1}}…` values, frozen at queue time |
| `status` | Select | `Queued` / `Sending` / `Sent` / `Failed` / `Skipped`, default `Queued`. In list view, in standard filter |
| `attempts` | Int | |
| `wa_message_id` | Data | Meta's id, once sent |
| `sent_at` | Datetime | |
| `error` | Small Text | Meta's refusal, or why it was skipped |

Both are also in `doctypes.json`, ready for `frappe.client.insert`.

## 4. ERPNext: three Server Scripts

Desk → *Server Script → New*, pasting the files in `server-scripts/` exactly.
The settings for each are in the comment at the top of the file.

- `manna_whatsapp_queue.py`: DocType Event, Sales Order, **After Save**
- `manna_whatsapp_payment.py`: DocType Event, SAP Invoice, **After Save**
- `manna_whatsapp_sender.py`: Scheduler Event, **Cron** `* * * * *`

**A safe_exec trap the first version fell into (found 10 Nov 2026).** A
Server Script's own names live in a separate locals dict, so a function
defined in the script cannot call another function defined there, and cannot
see `doc`. The queue script's `item_summary` called `qty_text` and failed with
"name 'qty_text' is not defined" on every approval, so nothing was ever
queued. Every helper is now a leaf (its arguments and `frappe` only) and the
work is done at the top level. Keep it that way.

The scheduler has to be enabled on the site (Frappe Cloud: it is, by default).
The queue script uses `frappe.utils.formatdate`, `fmt_money` and
`doc.get_doc_before_save()`, and avoids the safe_exec traps listed in the root
`CLAUDE.md`.

## 5. Going live, in this order

1. Create both DocTypes. Leave `enabled` **off**.
2. Paste both Server Scripts.
3. Fill the settings: Phone number ID, token, `test_mode` **on**, your own
   number in Test Numbers. Then turn `enabled` **on**.
4. **First test without touching an order:** in Desk, create a *Manna WhatsApp
   Message* by hand: customer any real one, phone = your number, template
   `manna_order_confirmed`, params
   `["Test", "Manna Treads", "SAL-ORD-TEST", "05-11-2026", "Test item - 1 roll", "₹ 100.00"]`,
   status Queued. Within a minute it should read **Sent** and arrive on your
   phone. If it reads Failed, `error` holds Meta's reason.
5. Leave it on test mode for a few days of normal orders. The *Manna WhatsApp
   Message* list shows what **would** have gone to each customer (Skipped, with
   the reason "test mode"). Check the names, items and amounts read right.
6. Untick `test_mode`. From then on, real customers get the messages.

To stop everything immediately: untick `enabled`. Already queued rows wait;
nothing new is queued.

## What it does not do

- **Replies.** A customer who replies reaches the WhatsApp number, not the rep.
  Reading replies needs a webhook, which this doesn't set up. Until then, check
  the number on WhatsApp Manager or point customers to their rep in the
  templates.
- **Invoices / PDFs.** Sending the proforma or invoice PDF needs a *document*
  header template and a public link to the file. That's a later step.
- **Old orders.** Nothing is sent for orders approved or delivered before the
  scripts were switched on, because the script only reacts to a change.
