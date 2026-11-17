# Payment commitments: the 10-day ladder on an order

Built 17 November 2026 to the user's spec ("Customer Outstanding and 10-Day
Payment Commitment workflow"). Everything happens in ERPNext. SAP only receives
approved orders, with the commitment written in the order's Comments.

The rules are in [`shared/fixtures/payment_commitment.json`](../shared/fixtures/payment_commitment.json).
They are enforced by three Server Scripts and tested in both apps.

## The user's choices (17 Nov 2026)

| Question | Choice |
|---|---|
| What "outstanding exceeds 30 days" means | Overdue **more than 30 days past the payment terms** (SAP's overdue-days figure) |
| Overdue 1–30 days past terms | An ordinary Manager approval. Before this, every such order went to the GM |
| The temporary credit extension | **Merged** into this ladder. SAP credit limits are no longer changed |
| Over the credit limit | The Manager approves with a commitment if the excess is within their approval authority; above it, the GM decides |
| When a commitment counts as kept | **Nothing is overdue past terms** on SAP figures synced after the approval, on or before the payment date |
| After a miss | Orders go to the GM **until the overdue is cleared** |
| SAP | **Only approved orders** are pushed (`order_flow.require_approval`, on by default), with the commitment in the Comments |

## The flow

1. **The order is raised.** If only the GM may decide it (route GM in step 2:
   a missed commitment not cleared, over the limit beyond the Manager's
   authority, or the Manager's limit of commitments reached), the order goes
   straight to *Pending GM Approval*, bypassing the Manager. The Manager and
   the GM are notified. The Manager still sees the order, with the reason, and
   may write a **Note for GM** on it, but may not decide it.
2. **Where the order goes:**
   - Ordinary Manager approval: nothing needs a decision.
   - Manager, with a commitment: the customer is overdue more than 30 days past
     terms, or the order takes them over the limit within the Manager's
     authority.
   - GM: over the limit beyond the authority, the Manager's limit of 2
     commitments in 90 days for this customer, or a missed commitment not
     cleared.
3. **The Manager approves with a commitment.** On the Decision card they enter
   the payment date (at most 10 days away) and remarks, or they reject. The
   commitment is created as *Pending*. It becomes *Running* when the approval
   saves. The order shows **Payment Pending**.
4. **The GM approves.** The condition and its due date are the commitment, also
   limited to 10 days. The order shows **GM Approved** and goes back to the
   Manager, who pushes it to SAP. A rejection cancels the commitment.
5. **Tracking, every hour at :15.** The `manna_payment_commitment_watch` script
   reads the overdue figure the credit sync copied into ERPNext, and the time
   of the last sync:
   - **Kept:** nothing is overdue on figures synced after the approval, by the
     payment date.
   - **Missed:** figures synced after the date still show something overdue.
     The Manager and the GM are told, and the customer's next orders go to the
     GM.
   - **Unchecked:** there are no figures from after the date yet. The credit
     sync is asked for, and nothing is marked missed on stale figures.
   - **Cleared:** a later sync shows nothing overdue. The customer's orders
     follow the normal route again. The miss stays in the history.
6. **SAP.** PASS M sends an order to Manna Treads only once it is *PO Approved
   - Ready for SAP*. Its Comments carry `payment commitment PC-#####: pays by
   <date> (Manager|GM)`.

## Statuses on the dashboards

**Pending Manager Approval · Sent to GM · GM Approved · Rejected · Payment
Pending · SAP Pushed**, plus *Approved* for the short time before the push.

- On **Team Orders**, the stage shows beside the existing status pill, with the
  customer's outstanding. This is in both apps.
- In the **GM queue**, each card shows the customer's commitment count, misses,
  days given and latest commitment, and says when an order came straight to
  the GM after a miss.
- The **Payment Commitments** page (dashboard and phone) replaces Temporary
  Credit. It has every commitment, a history per customer, the alerts, and the
  approval authority.

## Files

| Where | What |
|---|---|
| `shared/fixtures/payment_commitment.json` | The rules |
| `app/server/payment_commitment.py` | API `manna_payment_commitment`: `route`, `approve`, `history`, `list`, `orders`, `alerts`, `seen` |
| `app/server/payment_commitment_order.py` | DocType Event on Sales Order, *Before Save*. The backstop: routes a locked customer's order to the GM, refuses an approval without its commitment, cancels the commitment on rejection |
| `app/server/payment_commitment_watch.py` | Scheduler (Cron `15 * * * *`): kept, missed, unchecked, cleared |
| `app/server/payment_commitment_doctypes.json` | Manna Payment Commitment (+ Log) |
| `app/server/install_payment_commitment_local.py` | Installs on the local ERPNext only |
| `client/src/domain/paymentCommitment.ts`, `app/lib/core/payment_commitment.dart` | The rule in each app, with tests |
| `sap-order-sync/Sync-SapOrders.ps1` | `require_approval`, and the commitment in the Comments |

Changed rules, in the same change: `credit.json` (`past_terms` now means more
than 30 days), plus one case each in `credit_commitment.json` and
`proforma_release.json`.

## Live install, each step with the user's go-ahead

1. The doctypes, from `payment_commitment_doctypes.json`.
2. The three Server Scripts.
3. Manna Credit Extension Settings: the Managers' authority amounts (live is
   currently 0) and the cap of 2 commitments in 90 days.
4. The office server's `Sync-SapOrders.ps1`. Note that `require_approval`
   matters only under `manna_first`; `hitech_direct` already pushes on approval.
5. The dashboard deploy and a phone build.
