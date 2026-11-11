# Putting the ERPNext packages into B1if (TEST companies)

Five packages, built by `build_packages.py` into `out/`:

| Package (step) | Sender (TEST SLD id) | Trigger | Posts to |
|---|---|---|---|
| `Z.erpcust` (`Z.erpcustbp`) | Manna Treads `0010000119` | B1 event, Business Partner (2) | `manna_sap_customers` |
| `Z.erpitem` (`Z.erpitemit`) | Manna Treads `0010000119` | B1 event, Item (4) | `manna_sap_items` |
| `Z.erpstock` (`Z.erpstockht`) | Hi-Tech `0010000120` | **Timer**, 5 min | `manna_sap_stock` |
| `Z.erpstatht` (`Z.erpstathtso`) | Hi-Tech `0010000120` | **Timer**, 5 min | `manna_sap_status` |
| `Z.erpstatmt` (`Z.erpstatmtso`) | Manna Treads `0010000119` | **Timer**, 5 min | `manna_sap_status` |

Each step is: atom1 writes the SQL → atom2 Call SQL on the sender → atom3
turns the rows into the JSON body → **an HTTP call you add by hand** → atom0.
Every body says `"dry_run":1` until you change it (step 7), so the first runs
only report.

Proved offline on 9 Nov 2026 (`Test-Packages.ps1`, `test_bodies.py`): each
atom1 writes SQL that runs on the local copies of the companies, and each atom3
writes JSON that the local ERPNext accepts. **Not yet proved:** the import
itself, the timer channel, and the HTTP call — that is what tomorrow is for.

Two things are deliberately not in the zips, because no export of ours shows
their XML and a guessed one could break the import: the **Timer** channel
(timer packages are imported on a B1 event channel and switched in step 4), and
the **HTTP call** (step 5).

## Today, over RDP: import and configure (nothing runs)

1. **Copy** the five zips from `out/` to the SAP server.
2. **Import** each: B1if Control Center → **Scenarios → Export/Import → Import**
   (as with `Z.mannaic`). If one is refused, stop and send me the message.
3. **Senders:** Scenarios → **Setup** → each package → *Sender*: tick the TEST
   company in the table above — Manna Treads for `Z.erpcust`, `Z.erpitem`,
   `Z.erpstatmt`; Hi-Tech for `Z.erpstock`, `Z.erpstatht`. Never both in one
   package (senders are per package).
4. **Step Design**, every step (save it once even if nothing changes — B1if
   leaves the internal/parallel flags empty otherwise):
   - `Z.erpcustbp`, `Z.erpitemit`: Inbound already B1 Event, object 2 and 4.
   - `Z.erpstockht`, `Z.erpstathtso`, `Z.erpstatmtso`: change **Inbound** to
     **Timer**, every **5 minutes**, Outbound **Void** — the way `Z.mannaicpk`'s
     step is set (open it beside for comparison).
5. **The HTTP call** — first an SLD system for ERPNext, then one atom per step.
   - **SLD → create a system** of the HTTP kind (in B1if 1.x it is under
     *Undefined* / *HTTP*): name `ERPNEXT_LOCAL`, host = this PC's office IP,
     port `8000`, protocol `http`. Note the SysId it is given.
   - **Each step → Process Flow** → after **atom3**, insert the **HTTP call**
     atom (B1if lists it with the other calls: *Call HTTP* / *HTTP Call*):
     | Setting | Value |
     |---|---|
     | SysId | the `ERPNEXT_LOCAL` id |
     | Method | `POST` |
     | Path / URL | `/vpf:Msg/vpf:Body/vpf:Payload[@id='atom3']/Http/Endpoint` (or type it: `/api/method/<endpoint>` from the table) |
     | Payload / body | `/vpf:Msg/vpf:Body/vpf:Payload[@id='atom3']/Http/Body`, sent as **text** |
     | Content-Type | `application/json` |
     | Header | `Authorization` = the line in `erpnext/.sapsync-local-key.txt` (on Melvin's PC — not in git, not in chat) |
     | Timeout | **60000 ms** (a large stock change takes ~25 s) |
     | Throw exception | `true` |
     If the atom has none of these fields, screenshot its settings and stop —
     I will fit the XSL to what it does take.
6. **Error handling**, each package: not *"stop processing of following
   messages"* — one bad message must not stop the ones after it.

Leave all five **inactive** tonight.

## Tomorrow, on the office network

1. On Melvin's PC, as admin — the firewall rules, for the SAP server only:
   ```powershell
   New-NetFirewallHyperVRule -Name "ERPNext-from-SAP" -DisplayName "ERPNext 8000 from SAP server" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 8000 -RemoteAddresses 192.168.100.200 -Action Allow
   New-NetFirewallRule -DisplayName "ERPNext 8000 from SAP server" -Direction Inbound -Protocol TCP -LocalPort 8000 -RemoteAddress 192.168.100.200 -Action Allow
   ```
   and `bench use manna.localhost` in WSL, ERPNext started.
2. On the SAP server: `Invoke-RestMethod http://<PC IP>:8000/api/method/ping`
   must answer `pong`. If the IP changed overnight, change it in the SLD.
3. **Activate one package at a time**, `Z.erpcust` first: change a test
   customer in TEST Manna Treads (a phone number), then **Monitoring → Message
   Log**. The HTTP atom's answer is ERPNext's `count` / `results`. Then
   `Z.erpitem`, then the three timers.
4. **Writes on** for a package once its dry runs read right: in its atom3.xsl
   change `select="'1'"` (variable `dryRun`) to `'0'` — XML editor, or
   export → edit → import.
5. **Stock's first write** after the code conversion may be refused as
   "more than half … would go to 0". Then add `"force":1` for one run (or ask me).

## Not built yet

- The **nightly full send** for customers and items (events only cover
  changes from now on; the first full load can be a one-off run of the SQL
  posted by `erpnext/try_local.py`-style script).
- **Live**: same zips; on import re-point atom2's SysId and the sender to the
  LIVE company systems, the HTTP system to the live site, a live key.

## Rebuilding

`python build_packages.py` → `powershell -File Test-Packages.ps1` →
`python test_bodies.py`. The SQL inside is copied from `../customers`,
`../items`, `../stock`, `../status`; change both together.

## Pick lists: confirmed in SAP, not approved in ERPNext (9 Nov 2026)

Nobody approves a pick list in ERPNext any more. The order sync (PASS K) sends
every submitted list to Hi-Tech, where it only reserves stock until the store
**ticks Confirmed** on it. Only then does `Z.mannaicpk` make the Hi-Tech
invoice, the Manna goods receipt and the delivery — for the **picked** kilos
when the store entered any on the list (a line picked as 0 is left off all
three), else for the released kilos. And only then does the status sync call
the line **Picked**.

**In this order** — the new query names a field that must exist first:

1. **The field**, Hi-Tech TEST (later live), logged in alone (SAP asks everyone
   else to log off for a new field): Tools → Customization Tools →
   User-Defined Fields – Management → **Inventory → Pick List** (the header,
   not the rows) → Add:
   | Setting | Value |
   |---|---|
   | Title | `Confirmed` (SAP makes it `U_Confirmed`) |
   | Description | `Confirmed - invoice it` |
   | Type | Alphanumeric, length 1 |
   | Valid values | `Y` Yes, `N` No — **default `N`** |
2. **`Z.mannaicpk`**: export it (Scenarios → Export/Import), copy the zip to
   Melvin's PC, run
   `python patch_pick_package.py "<the zip>"`, import the
   `… - confirmed.zip` it writes back. It swaps only the pick-list query.
3. **The order sync**: do NOT copy the new `Sync-SapOrders.ps1` to the SAP
   server - that copy runs against live, and the new one also carries the
   Manna-first flow that is not live yet. On TEST, run PASS K from Melvin's PC:
   `node localdev/sap/run-order-sync.mjs --pass K --pick-since <today>`
   (add `--apply` once the dry run reads right).
4. **`Z.erpstatht`**: the zip in the Downloads folder is already the new one.

**For the store**: open the pick list (Inventory → Pick and Pack → Pick
List), enter the weighed kilos in **Picked** for each line (0 for a product
not sent), *Update*, then set **Confirmed = Yes** and *Update*. Within a
minute the invoice, goods receipt and delivery are made. Confirm only when the
kilos are final — after it, changes go through the documents, not the list.

## Z.erpmore: the rest of the syncs, one package of seven timer steps (10 Nov 2026)

Built by `build_more.py`; proved offline by `Test-More.ps1` + `test_more_bodies.py`
(every step: its SQL on the local copies, its JSON accepted by the local ERPNext).
All bodies go to the one address `/api/method/manna_sap_in`; `"kind"` picks the endpoint.

| Step | From | Clock (Setup -> clock icon) | Posts |
|---|---|---|---|
| `Z.erpcustall` | Manna Treads | Minute `10`, Hour `1` | every customer (what an event missed) |
| `Z.erpitemall` | Manna Treads | Minute `20`, Hour `1` | every sales item |
| `Z.erpweight` | Hi-Tech | Minute `14,44` | roll figures, fills blanks only |
| `Z.erpcredit` | Manna Treads | Minute `4,19,34,49` | credit limit, outstanding, ageing, terms, overdue |
| `Z.erpinv` | Manna Treads | Minute `9,24,39,54` | the SAP Invoice mirror |
| `Z.erppay` | Manna Treads | Minute `3,8,13,18,23,28,33,38,43,48,53,58` | the SAP Payment mirror |
| `Z.erpprice` | Manna + Hi-Tech | Minute `29,59` | the price snapshot (two SQL calls, one post) |

Hour, Day, Month, Day Of Week, Year stay `*` except the two nightly steps' Hour.
Import, Setup -> Steps (tick all seven), no Sender (timer package), each step's
Inbound -> Channel -> timer (`INB_AY_TIMR_ASYN_BIU`) unless the zip already
carries it, the clock for each step, Activate.

ERPNext needs, beside the endpoints: the doctype `SAP Payment`
(`app/server/sap_payment_doctypes.json`), and for a "payment received" action a
Server Script on SAP Payment, After Insert, acting only when `new_payment = 1`.

## The 11 Nov 2026 build: send time on every batch, schedules in the packages

Two changes, in all six `Z.erp...` packages (`Z.mannaic` and `Z.mannaicpk` are
not touched):

1. **Every query stamps SAP's UTC time on its rows and atom3 sends it as
   `"sent_at"`.** ERPNext ignores a whole-state batch older than ten minutes
   (`../erpnext/README.md`, "A batch that is old is ignored"). The ERPNext side
   is already installed locally and takes the older packages' bodies as before,
   so the order of the two does not matter.
2. **Each timer step's schedule is in its channel**
   (`<Scheduler min=".." hour=".." .../>`, as B1if's export of `Z.mannaicpk`
   holds its own): stock `0,5,..`, status Hi-Tech `1,6,..`, status Manna
   `2,7,..`, and the table above for `Z.erpmore`. Not proved until one import
   shows it: after importing, open one clock in Setup and read it.

To take the build, for each of the six packages: Setup -> Deactivate;
Scenarios -> Import the zip; Step Design -> each step -> save once; Setup ->
the steps still ticked, the sender still there on `Z.erpcust` and `Z.erpitem`
only, one look at a clock; Activate.

Proof it landed: SAP Sync Control -> "B1iF: last answers" - each kind's entry
gains `age_seconds` (a few seconds on a healthy run).
