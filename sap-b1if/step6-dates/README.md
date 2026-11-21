# Step 6: delivery dates (13 Nov 2026)

The rep picks a delivery date with the order. Production moves it in
**Hi-Tech's sales order** when the plan changes, for the whole order or for
single items. Manna Treads' purchase order and sales order, and the ERPNext
order, follow it.

| | Where | What |
|---|---|---|
| Truth | Hi-Tech `RDR1.ShipDate`, the row's Delivery Date | Changing the header date in the SAP client asks whether to update the rows: **answer Yes**, or nothing moves |
| Manna Treads | B1if package `Z.mannaicdt`, step `Z.mannaicdate`, every minute | updates the PO and SO lines (by item) and their own dates |
| ERPNext | `Z.erpstatht`, every 5 minutes, now sends `date` per line | `manna_sap_status` moves the line dates and the order's date |

Rules, both legs:

- A line is matched by **item code**, like the status sync and the pick-list
  step. One item on two Hi-Tech lines takes the **later** date.
- A document's own date is the **latest** date among its open lines (the day
  the order is complete).
- Closed, delivered or cancelled lines are never touched.
- SAP wins. Once an order is in Hi-Tech, a date changed only in ERPNext or
  Manna Treads is put back to Hi-Tech's.
- ERPNext keeps the date the customer was first given in
  `custom_original_delivery_date`, written once, and adds a comment to the
  order saying what moved.

## Switches

| Switch | Off | On |
|---|---|---|
| Manna Treads `@MANNA_IC` `DATE_SYNC` | step 6 writes nothing (also off while either `ENABLED` is not `Y`) | `Y` |
| ERPNext SAP Sync Control, "B1iF: syncs that write" | dates are reported in the answer (`date_line_writes`, `date_order_writes`) but not written | add the word `dates`. **`all` does not cover it** |

## Files

| File | Atom | |
|---|---|---|
| `sql-ht.xsl` | atom1 → atom2 (Call SQL, Hi-Tech) | open orders of the flow changed in the last 7 days, the latest date per item |
| `sql-mt.xsl` | atom3 → atom4 (Call SQL, Manna Treads) | carries Hi-Tech's rows over as `VALUES`, compares in SQL, returns every line of the one PO/SO pair whose turn it is |
| `final.xsl` | atom5 | the decision, and the two updates |
| `bom.xsl` | atom6, atom8 | hands each B1 Object atom (atom7 SO, atom9 PO) its document |

`packages/build_dates.py` builds `packages/out/Z.mannaicdt.zip`.
`tests/Test-DatesStep.ps1` runs the whole step against two scratch databases
on the local SQL Server (42 checks). It cannot prove B1if's own update call.

## Proved on TEST, 13 Nov 2026

Cases A, B and C below passed in B1if on the TEST companies, each within two
minutes of the change in Hi-Tech:

- A: Hi-Tech order 570 was moved whole to 26 Nov. Manna Treads PO 256 and SO
  591 followed: the line and the documents.
- B: one item of Hi-Tech order 564 was moved to 28 Nov. Only that line moved
  on PO 250 and SO 585. The other line stayed on 18 Nov, and the documents
  went to 28 Nov.
- C: one item of Hi-Tech order 558, which has nine closed lines, was moved to
  27 Nov. Only line 7 moved on PO 244 and SO 579. The closed lines were
  unchanged, and the line count stayed at 12.

Still to see: D, a change made by hand in the SAP client.

The ERPNext half has not run on a site. The TEST B1if now posts to another
device's ERPNext, which still runs the old `manna_sap_status` and ignores
`date`. The user chose to go on from the offline tests (114). The first
place it runs is wherever the new script is installed. Until `dates` is in
the write switch it only reports, so read `date_line_writes` /
`date_order_writes` in "B1iF: last answers" there before switching it on.

## How the update finds a line

**How B1if's "Synchronous Update" matches document lines.** This is the first
step here that changes a document instead of adding one, and the matching rule
is not documented anywhere we could check. The update therefore hands SAP
every line in the order SAP shows them, each with its own `LineNum`. That
payload is correct whether B1if matches by number or by position. A closed
line goes with its number and no date. Whether SAP accepts a closed line in an
update at all is test C below.

The Service Layer accepts the same change on TEST: on 13 Nov 2026 a line date
and the document date of Manna Treads SO 585 and PO 250 were moved and put back.

## Trying it on TEST

1. On the SAP server's B1if: import `Z.mannaicdt.zip` (new) and `Z.erpstatht.zip`
   (replaces the TEST one). In Scenarios → Setup check both timers and that
   error handling is not "stop processing of following messages". Activate
   both in Scenarios → Control.
2. Message Log: `Z.mannaicdate` once a minute, Success, reason
   `skip: every delivery date in Manna Treads already agrees with Hi-Tech`
   (or `... no open Hi-Tech order of the flow was changed in the last 7 days`).
3. See the chains and what differs, from this PC:
   `node localdev/sap/sl-dates.mjs` (MannaHRM). `WANTS` marks a Manna Treads
   date the step will change.
4. Move dates in Hi-Tech, then wait a minute or two and run step 3 again. Each
   case below should end with no `WANTS`:

   | Case | Command (add `--apply`), or by hand in the SAP client | Expected in Manna Treads |
   |---|---|---|
   | A. whole order | `sl-dates.mjs --order 570 --move 2026-11-26` | SO 591 and PO 256: the line and the document on 26 Nov |
   | B. one item | `sl-dates.mjs --order 564 --move 2026-11-28 --item PMB00212508` | SO 585 and PO 250: line 1 on 28 Nov, line 0 still 18 Nov, documents 28 Nov |
   | C. closed lines | `sl-dates.mjs --order 558 --move 2026-11-27 --item HMD001210` | SO 579 and PO 244: line 7 on 27 Nov, the nine closed lines unchanged |
   | D. by hand | Hi-Tech order 563 in the SAP client: header Delivery Date to 30 Nov, Yes to updating the rows | SO 584 and PO 249: both lines and the documents on 30 Nov |

   If a case fails, the Message Log entry for `Z.mannaicdate` says why. Open
   the B1 Object atom's (atom7 or atom9) output.
5. ERPNext (local): needs the local bench running (`localdev/start.sh`),
   `python sap-b1if/erpnext/install_local.py`, and `dates` added to the write
   switch. Within 5 minutes of a move, the ERPNext order's line dates and
   order date follow, with a comment on the order.

## Going live, later

- ERPNext: Paul installs the new `manna_sap_status` on the live site. Until
  `dates` is in the switch it only reports.
- `python packages/retarget_package.py --manna 0010000103 --hitech 0010000101
  --erpnext 0010000122 --rename Z.mannaic=Z.LIVEmannaic packages/out/Z.mannaicdt.zip`
  makes `Z.LIVEmannaicdt`, and `--rename Z.erp=Z.LIVEerp ... Z.erpstatht.zip`
  makes the new `Z.LIVEerpstatht`. Both are checked to build.
- `b1if-setup-live.mjs --apply` adds `DATE_SYNC = N` to Manna Treads live. A
  person sets it to `Y`.
- The dashboard's "move delivery date" button writes ERPNext only. Once an
  order is in SAP, the next status post puts the date back. Hide the button
  for such orders, or have it explain this.
