# B1if: Manna Treads SO → Manna Treads PO → Hi-Tech SO

Added 4 November 2026. When a **sales order is added in Manna Treads**, B1if makes
Manna Treads' **purchase order to Hi-Tech** for it, and when that purchase order
is added, Hi-Tech's **sales order to Manna Treads**.

**Only sales orders that came from ERPNext** (decided 4 Nov 2026). A sales order
keyed directly in SAP gets no purchase order and no Hi-Tech order from B1if. It
is recognised as an ERPNext order by what the sync's PASS M writes on it, and
both must be true:

- NumAtCard starts with `ERP_PREFIX` (`SAL-ORD-`), the ERPNext order's name;
- the remarks start with "From ERPNext " followed by that same name.

```
ERPNext order ──PASS M──▶ MT sales order ──B1if step 1──▶ MT purchase order ──B1if step 2──▶ Hi-Tech sales order
                            event 17 / A                    event 22 / A
MT sales order keyed in SAP ──B1if step 1──▶ "skip: not an order from ERPNext", nothing made
```

**B1if is the only thing that makes these two documents.** The sync script's
code for making them was removed on 4 Nov 2026, so the two cannot conflict.
PASS P and PASS H only **find** what B1if made, by NumAtCard (the ERPNext
order's name, which B1if copies across), and write it back to ERPNext. PASS B
keeps following Hi-Tech's order as before. An order B1if has not followed in
`order_flow.b1if_wait_minutes` (30) gets an error on the ERPNext order.

## What it decides

The rules are PASS P's and PASS H's, so a document looks the same whichever of
the two made it.

**Step 1: the purchase order (in Manna Treads)**

- **Supplier:** `VENDOR` (S-1010), with series `PO_SERIES`, branch `PO_BRANCH`,
  and warehouse and location `PO_WHS` and `PO_LOCATION`.
- **Lines:** the same items and kilos as the sales order.
- **Price:** the sales order's rate including GST, less a header discount if
  there is one, less `MARGIN` ₹/kg. GST is then taken back off. Gross is rounded
  to 2 places and net to 6.
- **Tax:** decided by the supplier's state against `HOME_STATE`: `TAX_IN_STATE`
  if they match, `TAX_OUT_STATE` if not. It is never copied from the sales
  order, because a Karnataka customer is IGST while Hi-Tech is in Kerala.
- **NumAtCard:** the ERPNext order's name.
- **Comment:** "For Manna Treads SO n". It never names the end customer.
- **Link:** `U_MannaMtSo` holds the sales order's DocEntry. A second event for
  the same order finds it and makes nothing.

**Step 2: Hi-Tech's sales order (in Hi-Tech)**

- **Which purchase orders:** only those step 1 made (`U_MannaMtSo` set). Hand-made
  purchase orders already have their hand-made Hi-Tech order.
- **Customer:** `CUSTOMER` (10118), with series `SO_SERIES` and warehouse `SO_WHS`.
- **Lines:** the purchase order's items, kilos and net prices, as SAP holds them.
- **Tax:** decided by the customer's state, the same way as step 1.
- **Sales person:** the Manna Treads order's sales person, matched by name.
- **NumAtCard:** the purchase order's NumAtCard, else "MT PO n".
- **Manna Treads SO No.:** `U_MannaMtSoNo` holds the number on Manna Treads'
  sales order, e.g. 557, so Hi-Tech's orders can be searched by it. Only the
  number is stored, and the same number can recur in another series. Add the
  field to the sales order list's form settings to see it there.
- **Link:** `U_MannaMtPo` holds the purchase order's DocEntry.

**When it refuses**

It refuses rather than guesses in these cases:

- no margin
- an item that can't be bought (step 1) or sold (step 2)
- a supplier or customer that is missing or inactive
- no tax code for a state
- a rate not above the margin

A purchase order at the wrong price is an inter-company invoice somebody has to
unpick. A missing one is a line on `alert.sql`.

## Files

| File | What |
|---|---|
| `step1-mt-po/sql.xsl` | Builds step 1's query from the event's DocEntry: the order, its lines, the settings, the supplier, and any existing PO |
| `step1-mt-po/final.xsl` | The decision, and the purchase order as DI XML (`oPurchaseOrders`) |
| `step2-ht-so/sql-mt.xsl` | Builds the query that reads the purchase order from Manna Treads |
| `step2-ht-so/sql-ht.xsl` | Builds Hi-Tech's query: settings, customer, items, sales person, any existing order |
| `step2-ht-so/final.xsl` | The decision, and Hi-Tech's sales order (`oOrders`) |
| `alert.sql` | Sales orders with no PO, and B1if POs with no Hi-Tech order, after 30 minutes |
| `tests/Test-B1ifXsl.ps1` | 80 offline checks of the four transforms. No SAP, no B1if |
| `tests/try-in-ssms.sql` | The three queries as B1if will run them, against the test orders. Paste into SSMS |

The queries are built by an xform and run by the next atom, rather than written
into the SQL atom. B1if does not substitute values into the SQL atom's own text,
and SAP Community's answer is this two-atom pattern. The DocEntry goes in only as
a number. Item codes and the sales person's name are quoted.

## 1. In SAP: the settings table and the two fields

On the test companies this is already done (4 Nov 2026, with
`MannaHRM/localdev/sap/b1if-setup.mjs`). On live, do the same by hand in
**Tools → Customization Tools**, logged in to each company:

| Company | What | Detail |
|---|---|---|
| Both | User-defined table `MANNA_IC` | "Manna inter-company", **No Object** |
| Both | Field on `@MANNA_IC` | `Value`, Alphanumeric 100 |
| Manna Treads | Field on **Purchasing documents → Title** | `MannaMtSo`, Alphanumeric 11, "Manna Treads SO DocEntry (B1if)" |
| Hi-Tech | Field on **Marketing documents → Title** | `MannaMtPo`, Alphanumeric 11, "Manna Treads PO DocEntry (B1if)" |
| Hi-Tech | Field on **Marketing documents → Title** | `MannaMtSoNo`, Alphanumeric 20, "Manna Treads SO No." |

Then add rows to `@MANNA_IC` (Code = Name = the setting) under
**Tools → User-Defined Windows**:

| Manna Treads | Value | | Hi-Tech | Value |
|---|---|---|---|---|
| `ENABLED` | `N` until it is tested | | `ENABLED` | `N` |
| `START_DATE` | the first day, `yyyy-mm-dd` | | `CUSTOMER` | `10118` |
| `MARGIN` | `20` | | `SO_SERIES` | `179` |
| `VENDOR` | `S-1010` | | `SO_WHS` | `07` |
| `PO_SERIES` | `199` | | `HOME_STATE` | `KL` |
| `PO_BRANCH` | `1` | | `TAX_IN_STATE` | `CG+SG@18` |
| `PO_WHS` | `01` | | `TAX_OUT_STATE` | `IGST@18` |
| `PO_LOCATION` | `2` | | | |
| `HOME_STATE` | `KL` | | | |
| `TAX_IN_STATE` | `CG+SG@18` | | | |
| `TAX_OUT_STATE` | `IGST@18` | | | |
| `ERP_PREFIX` | `SAL-ORD-` | | | |

Series numbers differ between companies and sometimes between test and live.
Check `PO_SERIES` and `SO_SERIES` against **Administration → System
Initialization → Document Numbering** in each live company.

**`MARGIN` is now a second copy of the margin.** ERPNext's *SAP Pricing Control
→ Inter-company margin* still prices Hi-Tech's price list (sap-pricing). Change
both together.

Before B1if, paste `tests/try-in-ssms.sql` into SSMS on the SAP server. All three
SELECTs should return rows without an error. The Service Layer could not check
them from outside, because its query endpoint accepts only a subset of SQL.

## 2. In B1if: the two systems and the event sender

B1if's console is `http://localhost:8080/B1iXcellerator/exec/dummy` **on the SAP
server**. From any other PC it answers 403. Log in as B1iadmin.

1. **SLD.** Each company B1if writes to needs a B1 system. Add one for
   `TEST_MANNA_TREADS` and one for `TEST_HITECH_PRETREADS`, with a SAP user and the
   SQL login. Use **Test Connection** on both. Note each system's **SysId**.
2. **Events.** Step 1 and step 2 both start from Manna Treads events, so Manna
   Treads' system must send them. In the SLD entry for the Manna Treads system,
   set up the **Event Sender** (it may be under **Maintenance → Cfg Event
   Sender**, depending on the version), and confirm events are flowing in
   **Monitoring → Message Log** after adding any document there.

## 3. In B1if: the scenario package

**Scenarios → Design**: create package `vPac.manna.ic`. Then create the two
steps below.

### Step `vBIU.manna.ic.mtpo`: SO → PO

| Part | Setting |
|---|---|
| Inbound | Type **SAP Business One**, Channel **Event**. Identification: Object **17** (Sales Order); Transaction Type filter **A** (add only). Retrieval **none** (the query reads the order) |
| Outbound | Type **void** / no outbound. The B1 Object atom below writes |

**Processing** (atoms in this order; the ids are what `final.xsl` expects):

| Atom | Type | Setting |
|---|---|---|
| atom0 | xform | `step1-mt-po/sql.xsl` |
| atom1 | Call SQL | SysId = Manna Treads. Statement from XPath `/vpf:Msg/vpf:Body/vpf:Payload[@id='atom0']/Sql/Statement` |
| atom2 | xform | `step1-mt-po/final.xsl` |
| atom3 | if / condition | `/vpf:Msg/vpf:Body/vpf:Payload[@id='atom2']/Decision/Make = 'Y'` |
| atom4 | Call B1 Object, inside the condition | SysId = Manna Treads, method **add**. Object from XPath `/vpf:Msg/vpf:Body/vpf:Payload[@id='atom2']/Decision/BOM` |

### Step `vBIU.manna.ic.htso`: PO → Hi-Tech SO

| Part | Setting |
|---|---|
| Inbound | B1 Event, Object **22** (Purchase Order), Transaction Type **A**, from the Manna Treads system. Retrieval none |
| Outbound | void |

**Processing**:

| Atom | Type | Setting |
|---|---|---|
| atom0 | xform | `step2-ht-so/sql-mt.xsl` |
| atom1 | Call SQL | SysId = **Manna Treads**. Statement `/vpf:Msg/vpf:Body/vpf:Payload[@id='atom0']/Sql/Statement` |
| atom2 | xform | `step2-ht-so/sql-ht.xsl` |
| atom3 | Call SQL | SysId = **Hi-Tech**. Statement `/vpf:Msg/vpf:Body/vpf:Payload[@id='atom2']/Sql/Statement` |
| atom4 | xform | `step2-ht-so/final.xsl` |
| atom5 | if / condition | `/vpf:Msg/vpf:Body/vpf:Payload[@id='atom4']/Decision/Make = 'Y'` |
| atom6 | Call B1 Object, inside the condition | SysId = **Hi-Tech**, method add. Object `/vpf:Msg/vpf:Body/vpf:Payload[@id='atom4']/Decision/BOM` |

**If your B1if numbers atoms differently**, change the `xsl:param` at the top of
each `final.xsl` (`sqlAtom`, `mtAtom`, `htAtom`) and of `sql-ht.xsl` (`mtAtom`)
to match.

**Scenarios → Setup**: select the package, set the **sender** to the Manna
Treads system for both steps, then **Activate**.

## 4. Testing on the test companies

Everything here runs against the test copies only.

1. In the test companies, set `ENABLED = Y` in both `@MANNA_IC` tables. You can
   use `node localdev/sap/b1if-setup.mjs --apply --enable` from MannaHRM.
2. Create an order in the local ERPNext copy on one of the new item codes, then
   run `node localdev/sap/run-order-sync.mjs --apply --pass M,P,H` from
   MannaHRM. PASS M makes the Manna Treads sales order. Within a minute there
   should be a PO to S-1010 with `U_MannaMtSo` set, and a Hi-Tech order to 10118
   with `U_MannaMtPo` and `U_MannaMtSoNo` set. Run the sync again and PASS P and
   H link both in ERPNext.
3. If either is missing, go to **Monitoring → Message Log**, open the message,
   and look at atom2's or atom4's `Decision/Reason`.
   - A `skip:` reason means nothing was wrong; there was just nothing to do.
   - Anything else is a refusal.
   - If the B1 Object atom itself failed, its DI error names the field. The DI
     XML field names here (`WhsCode`, `LocCode`, `BPLId`, `DiscPrcnt`) are SAP's
     database names, and the first real run is what proves them.
4. Key a sales order directly in TEST_MANNA_TREADS. The message log should say
   `skip: not an order from ERPNext`, and no PO should be made.
5. Re-send the first order's event from the message log. It should say
   `skip: … already carries this …` and make nothing.

## 5. Going live, in this order

1. Copy the new `Sync-SapOrders.ps1` to the SAP server first. The copy there
   today still has the old PASS P and H that make documents; with B1if on as
   well, both would make purchase orders.
2. Do sections 1–3 on the live companies, with `ENABLED = N`. Set `START_DATE`
   to the day of the switch.
3. Set `ENABLED = Y` in Manna Treads, then in Hi-Tech.
4. Turn on `order_flow.mode = "manna_first"` with `since` the same day in
   `config.json` on the SAP server.
5. Point the alert queries in `alert.sql` at the right people.

To switch off, set `ENABLED = N` in either company. The script will not take
over: after 30 minutes PASS P puts an error on each ERPNext order still
without a purchase order, and those are made by hand until B1if is back on.

## Not covered yet

- **Edits and cancellations.** If a sales order is changed or cancelled in Manna
  Treads after its PO exists, nothing follows it. That is the same gap as the
  script has.
- **Approvals.** If Manna Treads sales orders go through an approval procedure,
  the add event comes when the approved draft becomes an order. That is what we
  want, but it is untested.
- **Write-back of refusals into SAP.** B1if's reasons are only in its message
  log. `alert.sql` is how they are noticed. In ERPNext, PASS P and H refuse an
  order B1if hasn't followed after `b1if_wait_minutes` (30).
