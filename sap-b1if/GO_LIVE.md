# Going live: the order flow and B1if on the live companies

Written 13 November 2026, for a start on 14 November. Everything here was built
and proved on `TEST_MANNA_TREADS` / `TEST_HITECH_PRETREADS` and a local ERPNext.
**Nothing in it has run against live.** Each phase ends with a check; do not
start the next phase until the check passes.

Who does what: every step in SAP, DTW, B1if's console and the live ERPNext is
done by a person. The tools in this repository read the live companies only
where a step says so, and write to SAP only as DTW files a person imports.

## What is proved, and what is not

| Piece | On TEST | Risk on the first live day |
|---|---|---|
| Order → Manna Treads SO → PO → Hi-Tech SO | Proved many times | Low, once the series and settings are right |
| Pick list → *Confirmed* → Hi-Tech invoice, goods receipt, delivery | Proved, with the released kilos | **Picked kilos lower than released has never been run** |
| Order status back to ERPNext | Proved | Low |
| Customers, items, stock, credit, invoices, payments, weights | Proved, posting to a PC on the office network | **B1if has never posted to the live ERPNext (HTTPS, over the internet)** |
| The two nightly full sends (customers, items) | Never seen to run | Unknown |
| Price snapshot, groups from ticked properties | Rule and tools tested; **the import of the ticks was never done**, nor files 2 and 3 of the price test | High if it is the first time anywhere |
| B1if's error handling | Still the default, "stop processing of following messages" | One bad message can hold every one after it |
| A bulk change to items | Seen twice: it delays purchase orders for hours | High on a day items are being changed |

**Recommended for day one:** the order flow (phases 1 to 6), and of B1if's data
syncs only **items** writing - it is what puts the new item codes into ERPNext,
and nothing else does. The rest are imported but not writing (phase 7), while
the tasks that fill customers, stock, credit and invoices on live today keep
doing so. Each is then switched to B1if one at a time and its old task
disabled the same hour (phase 8).

## Phase 0. What to have in hand

Read these off the live systems and write them down. Nothing below can be
filled in without them.

| What | Where | TEST's value, for comparison |
|---|---|---|
| SysId of the live Manna Treads system | B1if console → SLD | `0010000119` |
| SysId of the live Hi-Tech system | B1if console → SLD | `0010000120` |
| Manna Treads: sales order series for ERPNext orders | Administration → System Initialization → Document Numbering | 189 |
| Manna Treads: purchase order series, branch, location | same | 199, 1, 2 |
| Manna Treads: a **delivery** series for Kerala | same - TEST had none and one was made | 211 |
| Hi-Tech: sales order series | same | 179 |
| Supplier `S-1010` in Manna Treads, customer `10118` in Hi-Tech | Business Partner Master Data: active, not frozen | |
| The SAP user B1if signs in as (`B1i`) is assigned to the branch | Administration → Setup → General → Users → Branches | |

Check with Paul that the 14 Nov release (`live-release`) is on the live ERPNext
and in the app before phase 6: its Server Scripts, doctypes and fields are his.

## Phase 1. The live SAP companies

Log in alone: SAP asks everybody else to log off to add a field.

**Hi-Tech Pretreads (live)**, Tools → Customization Tools → User-Defined Fields - Management:

| Under | Title | Type | Description |
|---|---|---|---|
| Marketing Documents → Title | `MannaMtPo` | Alphanumeric 11 | Manna Treads PO DocEntry (B1if) |
| Marketing Documents → Title | `MannaMtSoNo` | Alphanumeric 20 | Manna Treads SO No. |
| Inventory → Pick List (the header, not the rows) | `Confirmed` | Alphanumeric 1, valid values `Y` Yes / `N` No, **default `N`** | Confirmed - invoice it |

**Manna Treads (live):**

| Under | Title | Type | Description |
|---|---|---|---|
| Marketing Documents → Title (it shows on purchase orders) | `MannaMtSo` | Alphanumeric 11 | Manna Treads SO DocEntry (B1if) |

**Both companies:** Tools → Customization Tools → User-Defined Tables - Setup:
table `MANNA_IC`, "Manna inter-company", **No Object**. Then a field on it,
`Value`, Alphanumeric 100. Then the rows (Tools → User-Defined Windows), Code =
Name = the setting:

| Manna Treads | Value | | Hi-Tech | Value |
|---|---|---|---|---|
| `ENABLED` | **`N`** | | `ENABLED` | **`N`** |
| `START_DATE` | the first day, `2026-11-14` | | `CUSTOMER` | `10118` |
| `MARGIN` | `20` (the same as ERPNext's inter-company margin) | | `SO_SERIES` | phase 0 |
| `VENDOR` | `S-1010` | | `SO_WHS` | `01` |
| `PO_SERIES` | phase 0 | | `HOME_STATE` | `KL` |
| `PO_BRANCH` | phase 0 | | `TAX_IN_STATE` | `CG+SG@18` |
| `PO_WHS` | `01` | | `TAX_OUT_STATE` | `IGST@18` |
| `PO_LOCATION` | phase 0 | | | |
| `HOME_STATE` | `KL` | | | |
| `TAX_IN_STATE` | `CG+SG@18` | | | |
| `TAX_OUT_STATE` | `IGST@18` | | | |
| `ERP_PREFIX` | `SAL-ORD-` | | | |
| `DN_SERIES` | phase 0 (the delivery series) | | | |

**Check.** In SSMS on the SAP server, in each live company:

```sql
SELECT Code, U_Value FROM [@MANNA_IC] ORDER BY Code
```

Manna Treads returns 13 rows, Hi-Tech 7, and `ENABLED` is `N` in both. Then, in
Hi-Tech, `SELECT TOP 1 U_Confirmed FROM OPKL` must run without an error: the
pick-list package names that field every minute and fails without it.

**The items.** The flow only takes an item that has the **same code and the
same name** in both companies, and ERPNext must hold that code. An order on an
old code is refused, not mapped. Before phase 6, in SSMS (it reads both):

```sql
SELECT COUNT(*) AS SameCodeAndName
FROM [MANNA_TREADS_LIVE].dbo.OITM M
JOIN [HITECH_PRETREADS_LIVE].dbo.OITM H ON H.ItemCode = M.ItemCode AND UPPER(LTRIM(RTRIM(H.ItemName))) = UPPER(LTRIM(RTRIM(M.ItemName)))
WHERE M.validFor = 'Y' AND H.validFor = 'Y' AND M.SellItem = 'Y'
```

It should be about the number of finished goods the app sells. If the live
ERPNext still lists the old item codes, the app cannot place an order that goes
through: that has to be settled first, and it is not something B1if does.

## Phase 2. The price groups in Manna Treads (live)

Since 12 Nov 2026 an item is in a price group only when that group's property
is ticked on it in SAP, and **the phone can order only items that are in a
group**. On 6 Nov the live company had the ten properties named and no item
ticked. So this phase is not optional if the new price rule goes live; it is
`../sap-pricing/README.md`, *Ticking the groups*.

**Do it on TEST first** (the file is ready: `Downloads\price-groups-20261112\`,
1,511 rows). It has never been imported anywhere, and the live import is the
same steps.

**Do it before phase 4 switches events on for the live company, and the evening
before, not the morning.** Every item changed is an item event; B1if cleared
about 155 an hour on TEST, and a new order's purchase order waits behind them.

1. On the SAP server: `.\New-PropertySheet.ps1 -ConfigPath <the sync's config.json>`
   (it defaults to `MANNA_TREADS_LIVE`, and only reads).
2. Check the sheet. Colour codes are read: DOUBLE BLUE = Black Pearl, BLUE =
   Platinum, ROX = Silver, VERDO = Polygold. Items of a quality with no property
   (Bike SF, Medium, Tractor Gold, Polymer) come out empty: they stay out of the
   app until a property is named for them.
3. `.\New-PropertyDtw.ps1 -ConfigPath <the same> -Sheet <the corrected sheet>`
4. DTW, logged in to `MANNA_TREADS_LIVE`: Items → Update Existing Data, the file
   in the **Items** slot, Simulate first.

**Check.** Item Master Data → any ticked tread → Properties tab. And the count:

```sql
SELECT COUNT(*) FROM OITM WHERE validFor = 'Y' AND 'Y' IN (QryGroup1, QryGroup2, QryGroup3, QryGroup4, QryGroup5, QryGroup6, QryGroup7, QryGroup8, QryGroup9, QryGroup10)
```

It equals the number of rows the DTW log says it updated.

## Phase 3. The live ERPNext

These are added to the live site by hand, in Desk, from the files in
`erpnext/`. `install_local.py` refuses any site but a local one, on purpose.

1. **Custom fields**, the seven in `erpnext/custom_fields.json` (order and line
   status on Sales Order, and on *SAP Sync Control* the two B1iF fields).
2. **Server Scripts**, type API, name = API method = the file's name, the body
   the file as it is: `manna_sap_in`, `manna_sap_customers`, `manna_sap_items`,
   `manna_sap_stock`, `manna_sap_status`, `manna_sap_weights`,
   `manna_sap_payments`, `manna_sap_credit`, `manna_sap_invoices`,
   `manna_sap_pricing`.
3. **Doctype `SAP Payment`** (`app/server/sap_payment_doctypes.json`), if the
   release has not already made it.
4. **Two permission rows** for the role *SAP Sync Bot* (they are permission
   changes on live; decide them knowingly): Stock Reconciliation - read, write,
   create, submit; Item - read, select. Only where the doctype's permissions
   are already custom rows; a first custom row switches the standard ones off.
5. **The key B1if signs in with.** A user with the role *SAP Sync Bot*, an API
   key and its secret. **Do not press Generate Keys on a user something else
   already signs in as**: it replaces the secret, and whatever held the old one
   stops that second (11 Nov 2026, on the local site). If in doubt, make a new
   user for B1if with that one role.
6. **Leave "B1iF: syncs that write" (`custom_b1if_writes`) empty.** Empty means
   every post is answered with what it would do and nothing is written.

The order flow's own fields and trigger are `../sap-order-sync/erpnext-setup.md`,
section *When `order_flow.mode` is `manna_first`*:

- two fields on Sales Order, `custom_mt_purchase_order` and
  `custom_mt_purchase_order_entry`. The sync's PASS P fails outright without
  them, because Frappe refuses a whole list on a field it does not know;
- the trigger widened so a run starts when an order is **created**, not only
  when it is approved. Without it an order still goes, but only on the
  15-minute task.

The pick list's SAP fields (`sap_pick_list`, `hitech_invoice`,
`mt_goods_receipt`, `mt_delivery`) belong to the release's *Manna Pick List*
doctype: confirm with Paul that live has them.

**Check.** From any PC: `GET https://<the live site>/api/method/manna_sap_in`
with the key answers "kind must be one of: …" - the script is there and the
key signs in. A 401 is the key; a 404 is the script.

## Phase 4. B1if

The console is `http://127.0.0.1:8080` on the SAP server, user B1iadmin.

1. **SLD.** The two live company systems, each with *Test Connection* passing.
   A third system for the live ERPNext, of the HTTP kind: protocol `https`,
   host the live site's name, port `443`, path `/api/method/manna_sap_in`,
   basic authentication with the key (user) and the secret (password) from
   phase 3. Note its SysId.
2. **Prove B1if can reach the live ERPNext before importing anything real.**
   It never has: every test posted to a PC on the office network over plain
   HTTP. If the first post fails on the certificate, B1if's Java does not trust
   the site's certificate authority; that is fixed in B1if's Java trust store
   and needs the B1if service restarted. Stop and settle it before going on.
3. **The live zips.** B1if names a system by its SysId inside each package, so
   every package is re-pointed, on Melvin's PC:

   ```powershell
   python retarget_package.py --manna <id> --hitech <id> --erpnext <id> out\Z.erpcust.zip out\Z.erpitem.zip out\Z.erpstock.zip out\Z.erpstatht.zip out\Z.erpstatmt.zip out\Z.erpmore.zip
   ```

   `Z.mannaic` and `Z.mannaicpk` are not built here: **export both from B1if as
   they run on TEST today** (Scenarios → Export), copy the two zips over, and
   run the same command on them (`--erpnext` is not needed for those two). It
   prints, per package, which systems it re-pointed. Read that before importing.
4. **Give the live copies their own names, so the TEST packages stay** (decided
   13 Nov 2026). Add `--rename Z.mannaic=Z.LIVEmannaic` for the two order-flow
   packages and `--rename Z.erp=Z.LIVEerp` for the six data packages: one prefix
   renames a package and all its steps together. The live ones then import
   beside the TEST ones, which keep following the TEST companies. Without
   `--rename` a live zip has the TEST package's name and importing it replaces
   that package. From here on a fix has to be made to both sets.
5. For each package: Scenarios → Import the live zip; Setup → the steps
   ticked. **Sender**: the live Manna Treads system on `Z.LIVEmannaic`,
   `Z.LIVEerpcust` and `Z.LIVEerpitem`, and on nothing else. Never Hi-Tech as a
   sender of `Z.LIVEmannaic`, and never a live company as a sender of a TEST
   package, which would then act on live orders. The timer packages have no
   sender; open one clock and read it (the schedule travels in the zip).
6. **Error handling**, every package: not "stop processing of following
   messages".
7. **Leave `Z.erpitem` inactive on the first days.** A change to an item is then
   picked up by the nightly `Z.erpitemall` (01:20) instead of an event, and a
   bulk change to items cannot hold purchase orders back. Bring it in once the
   properties, prices and item codes have stopped moving.
8. Activate `Z.LIVEmannaic` and `Z.LIVEmannaicpk` - only once phase 1 is done:
   without the settings table their first query fails, and the pick-list one
   runs every minute. With `ENABLED = N` they decide "skip" on everything.

**Check.** Monitoring → Message Log, sender = the live Manna Treads system:
after any sales order is added in Manna Treads, a message appears and its
reason is `skip: @MANNA_IC ENABLED is not Y`. That proves the event reaches
the package and the package reads the live company.

## Phase 5. The order sync on the SAP server

1. Copy the new `sap-order-sync/Sync-SapOrders.ps1` over the server's copy
   **only now**: the old one makes purchase orders itself, and with B1if on as
   well both would.
2. In the server's `config.json`:
   - `order_sync.line_warehouse`: `"01"`
   - `manna_treads`: the live series, branch, warehouse `01`, tax code and
     location from phase 0
   - `order_flow`: `"mode": "manna_first"`, `"since": "2026-11-14"`,
     `"pick_lists_since": "2026-11-14"`, `"b1if_wait_minutes": 30`
3. Run it once with `-DryRun` and read the log: no error, and "0 new Manna
   Treads order(s)" before the first order exists.

The app still reads the fields this script writes (the pick list's delivery
number, `custom_sap_sales_order_status`). Its linking passes stay on; B1if's
status sync does not replace them yet.

## Phase 6. Switching the order flow on

1. `ENABLED = Y` in Manna Treads' `@MANNA_IC`, then in Hi-Tech's.
2. **The first real order, watched end to end by one person:**
   order in the app → the sync's next run → Manna Treads sales order → within a
   minute a purchase order to `S-1010` and a Hi-Tech order to `10118` → pick
   list in the app → Hi-Tech's SAP pick list → the store enters the picked
   kilos and sets *Confirmed* → Hi-Tech invoice, Manna goods receipt, delivery.
3. **Look at that first invoice's kilos.** Picked kilos lower than released has
   never been run. If the invoice carries the released kilos and not what the
   store picked, stop confirming pick lists and say so; the documents are
   corrected in SAP, and the query is `step3-pick/sql-ht.xsl`.

**If a purchase order does not appear within five minutes:** Message Log, the
message for that sales order, atom2's or atom4's `Decision/Reason`. Then B1
Event Monitor: an event still waiting means a queue, not a refusal.

## Phase 7. B1if's data syncs, not writing

Import and activate the six `Z.erp…` live zips (phase 4, step 5), with
"B1iF: syncs that write" still empty.

**Check.** On the live site, *SAP Sync Control → B1iF: last answers* fills in
within five minutes: each kind with a time of now, `age_seconds` near 0, and
`dry_run: true`. Read each one's counts against what the old script reports.

**Items, on day one.** Put `items` in "B1iF: syncs that write". The nightly
`Z.erpitemall` (01:20) then creates every shared code ERPNext lacks; to have
them before the first order, move that step's clock to a few minutes ahead
once (Setup → the clock), let it run, and put the clock back. Only the shared
finished-goods codes are written (`PMD…`, `PMB…`, `PV…`, `PR…`, `HMD…`, `BM…`,
`SM…`): any other code is skipped, because Manna Treads' `I-` codes and
Hi-Tech's are different items. Read the answer: `created` is the new codes.

An item is skipped, with the reason beside it, when ERPNext lacks what it
needs: its Item Group (`FG`, `HOT`, `Bonding Gum`, `Vulcanizing Solution` -
make any that is missing first), its HSN code, or its unit. Run it dry once
before `items` goes into the switch and read the skips; a dry run lists them
without creating anything.

## Phase 8. Retiring the tasks B1if replaces

The server runs its syncs as scheduled tasks that wait for a flag in ERPNext
(`sap-order-sync/Register-FlagWatchTasks.ps1`). **List what is really there
first**, in an elevated PowerShell - unelevated, the SYSTEM-owned tasks are
invisible:

```powershell
Get-ScheduledTask | Where-Object { $_.TaskName -like 'SAP-*' } | ForEach-Object { '{0,-24} {1,-9} {2}' -f $_.TaskName, $_.State, ($_.Actions.Arguments -join ' ') }
```

| Task | What it runs | B1if's replacement | What to do |
|---|---|---|---|
| `SAP-Watch-Orders` | `Sync-SapOrders.ps1` | None. B1if only makes the purchase order, Hi-Tech's order and the pick list's three documents; the script still makes the Manna Treads order, sends the pick list and writes the fields the app reads | **Keep**, on the new script (phase 5) |
| `SAP-Watch-Stock` | Items and roll figures, then stock, from Hi-Tech (`Sync-HitechProductsToTreads.ps1`, `Sync-HitechStockToTreads.ps1`) | `items`, `weights`, `stock` | Disable once all three write |
| `SAP-Watch-Credit` | `Sync-SapCreditLimits.ps1`: credit limit, outstanding, terms, overdue, the invoice mirror, new customers | `customers`, `credit`, `invoices` (and `payments`, which is new) | Disable once all four write |
| `SAP-Watch-Pricing` | `Sync-SapPricingSnapshot.ps1`, when the MD presses *Sync from SAP* | `pricing`, every 30 minutes | **Keep for now**: B1if does not write the run stamps the rates screen shows, and the button would do nothing. Copy the new `sap-pricing/` files to the server so both follow the 12 Nov rule |
| `SAP-Watch-Categories` | CMMS item edits → SAP (`Manna_CMMS/sap-sync`) | None - it is not a sales sync | **Keep** |

Any task the list shows that is not in this table is an older timer the
watchers were meant to replace: read its action before touching it.

**One task at a time, in this order: credit, then stock.**

1. Put the kinds that replace the task in "B1iF: syncs that write", comma
   separated with what is already there (`items, customers, credit, invoices, payments`).
2. Wait for each to answer once with `dry_run: false` and compare one customer
   or one item with SAP by eye.
3. Disable the task - **disable, not delete**, so going back is one command:

   ```powershell
   Disable-ScheduledTask -TaskName 'SAP-Watch-Credit'
   ```

4. Leave it a working day before the next one.

Never two writers for one kind for longer than the hour it takes to compare
them. `all` in the switch is for the day every kind has been through this.

**Stock's first write** may be refused as "more than half … would go to 0":
the conversion moved the stock to codes ERPNext did not hold. Read the answer;
if the figures are right, B1if's body takes `"force": 1` for one run
(`packages/SETUP.md`).

**The Sync buttons.** The apps' stock and credit Sync buttons raise a flag that
the disabled task no longer answers. Nothing breaks - B1if refreshes stock
every 5 minutes and credit every 15 - but the button will look as if it never
finishes. Tell Paul before the task is disabled, so the button goes or changes.

**After two weeks with a task disabled** and nothing missed, its folder on the
server (`C:\Users\eldhose\sap-credit-sync` and the stock scripts) can be zipped
away. The stock and products scripts were never in this repository: keep that
zip.

## Going back

| To stop | Do |
|---|---|
| B1if making purchase orders and Hi-Tech orders | `ENABLED = N` in either company's `@MANNA_IC`. Takes effect on the next order |
| The new order route | `order_flow.mode` back to `hitech_direct` in the server's `config.json` |
| A B1if sync writing | Take its name out of "B1iF: syncs that write"; `Enable-ScheduledTask` its old task |
| Everything B1if does | Setup → Deactivate, each package |
| The live packages altogether | Setup → Deactivate each `Z.LIVE…` package. The TEST ones were never touched |

Orders made while it was on stay as they are in SAP. After `ENABLED = N` the
sync puts an error on each ERPNext order still without a purchase order after
30 minutes, and those are made by hand.

## Known gaps on the day

- An order edited, rejected or cancelled after its Manna Treads sales order
  exists is not followed into SAP.
- B1if writes its reasons nowhere but its message log. `alert.sql` holds two
  queries for SAP's Alerts Management that list what it has not followed.
- TEST and live now run side by side in one B1if, as two sets of packages. A
  bulk change to items in a TEST company still fills the same event queue a
  live order waits in.
- A delivery date production moves in Hi-Tech's sales order stays in Hi-Tech.
  The step that carries it to Manna Treads and ERPNext (`step6-dates/`,
  13 Nov 2026) is being proved on TEST and is not part of this go-live; its
  live switch, Manna Treads' `DATE_SYNC`, goes in as `N`.
