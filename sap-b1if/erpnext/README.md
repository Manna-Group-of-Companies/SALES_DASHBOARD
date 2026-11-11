# What B1iF posts to in ERPNext

The SAP → ERPNext syncs that B1iF runs (built 9–10 Nov 2026 to replace the
sync scripts, which keep running on live until each is proved there). Every
step posts one batch to **one address**, `/api/method/manna_sap_in`, and
`"kind"` in the body says which endpoint it is for. Each endpoint decides
everything itself, so a B1iF step only reads SAP, posts, and is answered — no
branch atom (a step with one never runs, see `../README.md`).

| kind | Endpoint | From | B1iF step | SAP query |
|---|---|---|---|---|
| `customers` | `manna_sap_customers` | Manna Treads | `Z.erpcustbp` (BP event), `Z.erpcustall` (nightly) | `../customers/customers.sql` |
| `items` | `manna_sap_items` | Manna Treads | `Z.erpitemit` (item event), `Z.erpitemall` (nightly) | `../items/items.sql` |
| `stock` | `manna_sap_stock` | Hi-Tech | `Z.erpstockht` (5 min) | `../stock/stock.sql` |
| `status` | `manna_sap_status` | Hi-Tech **and** Manna | `Z.erpstathtso`, `Z.erpstatmtso` (5 min) | `../status/*.sql` |
| `weights` | `manna_sap_weights` | Hi-Tech | `Z.erpweight` (30 min) | `../weights/weights.sql` |
| `credit` | `manna_sap_credit` | Manna Treads | `Z.erpcredit` (15 min) | `../credit/credit.sql` |
| `invoices` | `manna_sap_invoices` | Manna Treads | `Z.erpinv` (15 min) | `../invoices/invoices.sql` |
| `payments` | `manna_sap_payments` | Manna Treads | `Z.erppay` (5 min) | `../payments/payments.sql` |
| `pricing` | `manna_sap_pricing` | Manna + Hi-Tech | `Z.erpprice` (30 min) | `../pricing/*.sql` |

The rules, and why, are at the top of each `.py`. The packages are built and
proved in `../packages/` (see its `SETUP.md`).

## Whether a sync writes is one field in ERPNext

`manna_sap_in` ignores the body's `dry_run`. A kind writes only when it is
named in **SAP Sync Control → "B1iF: syncs that write"** (`custom_b1if_writes`:
kinds separated by commas, or `all`). Anything else is a dry run that answers
what it would do. So going live, or stopping one sync, needs no stylesheet edit
and no import in B1iF, and a site nobody has told anything writes nothing.

**"B1iF: last answers"** (`custom_b1if_last`) on the same page holds what each
kind was last answered and when — read it instead of B1iF's message log.

## A batch that is old is ignored

B1iF keeps every message it could not deliver and sends them all when ERPNext
answers again: after one night with the local site down (10-11 Nov 2026), 884
arrived in ten minutes. Most kinds are the whole current state, so an old batch
written after a newer one puts yesterday's figures back.

Every query stamps SAP's UTC time on its rows (`sent_at`, added by
`../packages/build_packages.py`), atom3 puts the first row's into the body, and
`manna_sap_in` answers a batch older than ten minutes (`MAX_AGE`) with
`"stale": true` - status 200, so B1iF counts it delivered and drops it. The
next run carries the same state, fresh.

- Not for `customers` and `items`: a late one is still the newest word on that
  record.
- A batch with no `sent_at` (an older package, a result with no rows) or one
  that is not a time is let through, not refused.
- Each answer in "B1iF: last answers" records `age_seconds`; ignored batches
  are counted beside it under `<kind> (stale, ignored)`. A SAP server clock
  more than ten minutes behind ERPNext's would make every batch stale - that
  is where it would show.

## What a site needs

`install_local.py` puts all of it on the **local** site (127.0.0.1:8000, the key
in `Manna_CMMS/server/.env`) and refuses any other host; live is done by hand
from the same files:

- the Server Scripts in this folder (type API, name = method = file name);
- the fields in `custom_fields.json` (order and line status, the two control fields);
- the doctype `SAP Payment` (`app/server/sap_payment_doctypes.json`);
- the two permission rows in `custom_fields.json` → `docperms` for the sync
  user's role, **SAP Sync Bot**: Stock Reconciliation (read, write, create,
  submit) and Item (read). ERPNext's own stock code checks both while a
  reconciliation is validated, and no `ignore_permissions` stands in for them.

B1iF logs in with **basic authentication**: user = the sync user's API key,
password = its API secret (the SLD system holds them; no XSL does).

## Tests

`python run_tests.py` — the rules of every endpoint, offline (pytest is not
installed here; `python -m pytest sap-b1if/erpnext -q` works where it is).
`try_as_sync_user.py` posts as the sync user, not Administrator: Administrator
passes every permission check and hid the stock one until B1iF ran it.

## Traps, each of which cost a run

- **safe_exec**: no tuple unpacking on assignment (return a dict); no
  `frappe.get_roles` (read `Has Role`); no `strftime` (use
  `frappe.utils.nowdate()` / `nowtime()`); the request body cannot be read; a
  field must not be called `is_new` (every document has that method).
- **A Stock Reconciliation of more than 100 lines** is submitted in the
  background, so `manna_sap_stock` writes 100 at a time.
- **B1iF re-writes an imported stylesheet** and turns a character reference in
  an attribute (`'&#9;'`) into a plain space: the JSON escaper then replaced
  every space with a tab code. No stylesheet names a control character now;
  the queries replace tab, CR and LF with a space in SQL (`../packages/build_packages.py`).
- **B1iF's Call HTTP sends bare text in `<payload>` as an empty body.** It must
  be `<payload><bfa:io pltype="txt">…</bfa:io></payload>` (`../packages/atom5_http.xsl`).
