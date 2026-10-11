/**
 * A2 — Order review. Where the order decision is made, and nowhere else.
 *
 * Approving fixes a price permanently, commits stock, and for a lead converts
 * the party. That decision needs the lines, the stock position and the credit
 * picture in front of it, which an inbox row cannot carry — so this screen
 * exists and the approvals inbox deliberately has no orders in it.
 *
 * The blocks are in a fixed order, top to bottom, and each is where it is for
 * a reason:
 *
 *   1. Header — who and when.
 *   2. "Cannot approve yet" (leads only) — above everything, because it is the
 *      one thing that will stop the approval and the manager should meet it
 *      before they have read the lines and made up their mind.
 *   3. Credit — the money risk, before the detail.
 *   4. Lines, each with its stock position and fulfilment choice.
 *   5. Order total.
 *   6. Edit the line-up.
 *   7. The decision.
 *
 * **There are no Server Scripts.** Every gate here is the only thing standing
 * between a manager and a state the phone would have refused, so each one is
 * re-checked against the order *as stored* at the moment of the write, never
 * against what the page happened to load.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { MinStockLine, OrderDetail, OrderLine, SalesCustomer } from '@/domain/types';
import {
  isApproved,
  isGeneralManager,
  rateEditable,
  editOpenNote,
  escalationLockReason,
  statusAllowsEdit,
  PO_STATUS,
} from '@/domain/orderStatus';
import { hasCommitment, orderActions } from '@/domain/creditCommitment';
import { agingOf, creditEscalates, escalationOf, escalationReason } from '@/domain/credit';
import {
  describeSplit,
  modeLabel,
  modeTone,
  servedFrom,
  poolByItem,
  positionFor,
  splitOf,
  type Qty,
} from '@/domain/minimumStock';
import {
  changedLineIds,
  changesSince,
  describeChange,
  loadSeen,
  saveSeen,
  snapshotOf,
  stageText,
} from '@/domain/stageWatch';
import { lineStatusFromSap, reachedSap } from '@/domain/sapOrderState';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Button, Card, Empty, Field, Input, Textarea } from '@/components/ui';
import { money } from '@/components/common/format';
import { RefreshButton } from '@/components/common/RefreshButton';
import { AgingBoxes } from '@/components/common/AgingBoxes';
import { StatusPill } from '@/components/common/StatusPill';
import { CommitmentThread } from './CommitmentThread';
import { OrderLinesEditor } from './OrderLinesEditor';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import './orders.css';

/** "4 rolls + 2 belts", or "—" when there is nothing. */
function qty(q: Qty): string {
  const parts: string[] = [];
  if (q.rolls) parts.push(`${q.rolls} roll${q.rolls === 1 ? '' : 's'}`);
  if (q.belts) parts.push(`${q.belts} belt${q.belts === 1 ? '' : 's'}`);
  return parts.join(' + ') || '—';
}

/** "9 of 10 rolls dispatched", named against what was ordered, not what remains. */
function dispatchedLabel(l: OrderLine): string {
  const parts: string[] = [];
  if (l.rolls) parts.push(`${l.dispatchedRolls ?? 0} of ${l.rolls} roll${l.rolls === 1 ? '' : 's'}`);
  if (l.looseBelts) {
    parts.push(`${l.dispatchedLooseBelts ?? 0} of ${l.looseBelts} belt${l.looseBelts === 1 ? '' : 's'}`);
  }
  return parts.join(', ') || '—';
}

export function OrderDetailPage() {
  const { orderId = '' } = useParams();
  const user = useAppSelector(selectUser);

  const [order, setOrder] = useState<OrderDetail | null>(null);
  const [customer, setCustomer] = useState<SalesCustomer | null>(null);
  const [pool, setPool] = useState<MinStockLine[]>([]);
  const [rateEdits, setRateEdits] = useState<Record<string, number>>({});
  /** Lines are open in the editor; the decision waits until they are saved. */
  const [editing, setEditing] = useState(false);
  /** A note for the GM, sent as a comment on the rep's commitment with Send to GM. */
  const [gmNote, setGmNote] = useState('');
  /** Bumped when this page posts a comment, so the thread re-reads. */
  const [threadKey, setThreadKey] = useState(0);
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  /**
   * The banner after a decision or a save.
   *
   * It carries its own tone. Until 18 September 2026 this was a bare string
   * rendered as `tone="ok"` whatever had happened, so rejecting an order
   * announced it in green under a tick — the one outcome on this screen that
   * is not an approval, dressed as one.
   */
  const [done, setDone] = useState<{ text: string; tone: 'ok' | 'danger' } | null>(null);

  /**
   * What production moved since this browser last opened the order.
   *
   * Computed once per load and held, so it does not vanish the moment the
   * snapshot is written back. The first look reports nothing — it establishes
   * the baseline rather than dumping every stage as news.
   */
  const [stageNews, setStageNews] = useState<ReturnType<typeof changesSince>>([]);

  /**
   * Refresh re-reads this order from ERPNext, and nothing else.
   *
   * Until 11 Oct 2026 it also raised the SAP order flag, so Refresh and the
   * header's Sync did the same thing and neither said which was which. The
   * user split them: Sync talks to SAP and shows when it last did
   * (`SyncAllButton`); Refresh is the instant ERPNext re-read.
   */
  const reload = useCallback(() => {
    setTick((t) => t + 1);
  }, []);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    setRateEdits({});
    Api.sales
      .getOrder(orderId)
      .then(async (o) => {
        if (!live) return;
        setOrder(o);

        // Diff before the snapshot is overwritten, then record what is now on
        // screen. Keyed on the child row name, which survives an edit.
        // The made portion's movement comes from SAP, so that is what the
        // "moved since you last looked" notice reports: the line's SAP status,
        // Pushed to SAP -> Dispatched, since there are no production stages
        // from 24 Sep 2026. Fed in under the old key so the watcher itself is
        // unchanged — only the source of truth moved.
        const orderSap = { salesOrder: o.sapSalesOrder, invoice: o.sapInvoice };
        const rows = o.lines.map((l) => ({
          name: l.id,
          item_name: l.itemName,
          custom_production_stage: lineStatusFromSap({ invoice: l.sapInvoice }, orderSap),
          custom_stock_stage: l.stockStage,
        }));
        setStageNews(changesSince(loadSeen(o.id), rows));
        saveSeen(o.id, snapshotOf(rows));
        const [parties, stock] = await Promise.all([
          Api.sales.listCustomers().catch(() => []),
          Api.sales.listMinimumStock().catch(() => [] as MinStockLine[]),
        ]);
        if (!live) return;
        setCustomer(parties.find((c) => c.id === o.customer) ?? null);
        setPool(stock);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read this order.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [orderId, tick]);

  /*
   * The customer as the credit helpers want it — raw ERPNext field names, the
   * same shape the phone reads and the shape `shared/fixtures/credit.json` is
   * written in. Built here rather than widening `SalesCustomer`, so there is
   * one translation point instead of one per screen.
   */
  const customerRow = useMemo(
    () => ({
      custom_outstanding_balance: customer?.outstanding ?? 0,
      custom_credit_limit: customer?.creditLimit ?? 0,
      custom_outstanding_0_30: customer?.outstanding0_30 ?? 0,
      custom_outstanding_30_60: customer?.outstanding30_60 ?? 0,
      custom_outstanding_60_90: customer?.outstanding60_90 ?? 0,
      custom_outstanding_90_plus: customer?.outstanding90Plus ?? 0,
      custom_overdue_past_terms: customer?.overduePastTerms ?? 0,
      custom_payment_terms: customer?.paymentTerms ?? '',
      custom_overdue_days: customer?.overdueDays ?? 0,
    }),
    [customer],
  );

  const movedLines = useMemo(() => changedLineIds(stageNews), [stageNews]);

  const stock = useMemo(() => poolByItem(pool), [pool]);
  const approved = order ? isApproved(order.poStatus) : false;
  /*
   * Read off the stored status, like `approved` above it. A rejection is the
   * one decision that leaves the order still awaiting a manager — see
   * `awaitingManager` — so without this the decision block cannot tell an
   * order nobody has looked at from one that has already been turned down.
   */
  const rejected = (order?.poStatus ?? '').trim() === PO_STATUS.rejected;

  /**
   * Whether the line-up may still be changed.
   *
   * **Approval ends editing, for everyone.** An approved order is pushed to
   * SAP and lives there from then on; changes go through the manufacturing
   * team, who reduce or drop a line that has not been made and ship what has.
   *
   * That is also the only honest answer. `Sync-SapOrders` has only ever
   * CREATED a SAP order — nothing anywhere updates one — so an edit saved here
   * after approval changed the ERPNext document, showed a new quantity, and
   * left the factory building the old one.
   *
   * The status alone decides (`statusAllowsEdit`). Until 11 Oct 2026 an order
   * also froze at 13:00 on its delivery date; that cutoff is gone.
   */

  /**
   * The order total as it stands on screen.
   *
   * Rebuilt from the lines rather than read off `order.total`, because a rate
   * the manager has typed is not saved until the decision — and an approval
   * screen showing yesterday's total is how a manager signs off money they did
   * not intend.
   *
   * It carried a before-and-after pair until 17 September 2026, when the
   * discount feature was removed from both apps. The rate the rep types is now
   * the rate after discount, so there is one total.
   */
  const preview = useMemo(() => {
    if (!order) return { total: 0, changed: false };
    let changed = false;
    let total = 0;
    for (const l of order.lines) {
      const edited = rateEdits[l.id];
      const rateMoved = edited != null && edited > 0 && edited !== l.ratePerKg;
      if (rateMoved) changed = true;
      total += rateMoved ? l.totalWeight * edited : l.amount;
    }
    return { total, changed };
  }, [order, rateEdits]);

  // ------------------------------------------------------------ actions ---

  const decide = async (decision: 'approve' | 'reject' | 'escalate') => {
    if (!order) return;
    setBusy(decision);
    setError(null);
    try {
      /*
       * The note goes first. If it lands and the escalation does not, the
       * manager presses Send again and the note is already there; the other
       * way round would leave the GM deciding without it.
       */
      if (decision === 'escalate' && gmNote.trim()) {
        await Api.sales.addCreditComment({
          salesOrder: order.id,
          comment: gmNote,
          role: user?.role,
          author: user?.name || user?.id || 'Sales Manager',
        });
        setGmNote('');
        setThreadKey((k) => k + 1);
      }
      const saved = await Api.sales.decideOrder({
        id: order.id,
        decision,
        // A rate the manager corrected travels to the GM with the order rather
        // than being dropped on the way. Only an approval locks it.
        rateEdits: decision === 'reject' ? undefined : rateEdits,
        role: user?.role,
      });
      setOrder(saved);
      setRateEdits({});
      setDone(
        decision === 'approve'
          ? {
              text: gmApproved ? 'Pushed to SAP. Rates are final.' : 'Approved. Rates are final.',
              tone: 'ok',
            }
          : decision === 'reject'
            ? { text: 'Rejected. Returned to the rep.', tone: 'danger' }
            : { text: 'Sent to the General Manager.', tone: 'ok' },
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the decision.');
    } finally {
      setBusy(null);
    }
  };

  /**
   * Take back a rejection, so the order can be decided again.
   *
   * This is a correction, not a second opinion: nothing on the lines moved
   * when the order was rejected, so nothing is restored here beyond the
   * status. What the manager gets back is the Approve/Reject pair.
   */
  const undoRejection = async () => {
    if (!order) return;
    setBusy('undo');
    setError(null);
    try {
      const saved = await Api.sales.undoOrderRejection(order.id);
      setOrder(saved);
      setDone({ text: 'Rejection undone. Awaiting decision.', tone: 'ok' });
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not undo the rejection.');
    } finally {
      setBusy(null);
    }
  };

  /*
   * Escalation is on the CUSTOMER's credit limit, not the rep's outstanding.
   * When it trips, the manager's Approve becomes Send to GM — they no longer
   * have the power to finalise this one.
   */
  // Read the way overCreditLimit reads it — the stored total, or the buckets
  // when SAP left it at zero — so this page offers exactly what the save will
  // accept (26 Sep 2026). The stored total alone offered Approve on an order
  // decideOrder then refused, and never Send to GM.
  const owed = agingOf(customerRow).total;
  // "Over limit" here means "needs the GM": the limit, or overdue past the
  // payment terms (11 Oct 2026). The two reasons are told apart for display.
  const overLimit = order ? creditEscalates(customerRow, order.total) : false;
  const why = order ? escalationOf(customerRow, order.total) : { overLimit: false, pastTerms: false };
  const whyText = order ? escalationReason(customerRow, order.total) : '';

  /** The GM is exempt from the rate lock. */
  const role = user?.role;

  /*
   * What this login may do, from the same rule `Api.sales.decideOrder`
   * re-checks. A sales manager meeting an over-limit order gets Send to GM
   * and Reject — never Approve — and once it is with the GM, only a comment.
   */
  const acts = orderActions(role, order?.poStatus, overLimit);
  const withGm = (order?.poStatus ?? '').trim() === PO_STATUS.pendingGm;
  /**
   * The GM approved the credit and handed it back: the sales manager's one
   * move is Push to SAP, at the GM's figures.
   */
  const gmApproved = (order?.poStatus ?? '').trim() === PO_STATUS.finalApproval;

  return (
    <div>
      {/* ---------------------------------------------- Block 1 — header --- */}
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">
            {order ? order.customerName : 'Loading…'}
          </div>
          <div className="page-head__sub">
            {order ? (
              <>
                {order.rep || 'Unassigned'} · Delivery{' '}
                {order.deliveryDate ? formatDate(order.deliveryDate) : 'not set'} ·{' '}
                {/*
                  Once SAP has the order, SAP's number is the one everyone
                  quotes — the factory, the delivery note, the invoice all
                  carry it. The ERPNext name stays visible but small: it is an
                  internal id, and support still needs to find the document by
                  it.

                  They are NOT interchangeable and must never be merged. SAP
                  restarts DocNum per series and per year — 399 has been issued
                  four times in this company, twice in 2024 alone — so it is
                  only unique alongside its series and date, while an ERPNext
                  name must be unique forever.
                */}
                {order.sapSalesOrder ? (
                  <>
                    <b className="mono">SAP {order.sapSalesOrder}</b>{' '}
                    <span className="tiny dim">({order.id})</span>
                  </>
                ) : (
                  <span className="mono">{order.id}</span>
                )}
              </>
            ) : (
              orderId
            )}
          </div>
        </div>
        <div className="cal__nav ordhead__actions">
          {/* When SAP was last read is on the header's Sync button (11 Oct 2026). */}
          {order && <StatusPill status={order.poStatus} sapStatus={order.sapSalesOrderStatus} />}
          <RefreshButton onClick={reload} loading={loading} />
          <Link to="/orders" className="btn btn--ghost btn--sm">
            ← Team Orders
          </Link>
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read or save">
          {error}
        </Alert>
      )}
      {done && !error && (
        <div style={{ marginBottom: 14 }}>
          <Alert
            tone={done.tone}
            icon={done.tone === 'danger' ? '✕' : undefined}
            title={done.text}
          />
        </div>
      )}
      {loading && !error && <Empty icon="◔" title="Reading order…" />}

      {!loading && order && (
        <>
          {order.changedAfterApproval && (
            <div style={{ marginBottom: 14 }}>
              <Alert tone="danger" title="Changed after approval">
                Production may be working to the old quantities.
              </Alert>
            </div>
          )}

          {/* -------------------------------------------- Block 3 — credit --- */}
          <div style={{ marginBottom: 14 }}>
            <Alert
              tone={overLimit ? 'danger' : customer?.creditLimit ? 'ok' : 'info'}
              title={
                !customer
                  ? 'Customer not found'
                  : why.overLimit && why.pastTerms
                    ? 'Over credit limit and overdue past terms'
                    : why.overLimit
                      ? 'Over credit limit'
                      : why.pastTerms
                        ? 'Overdue past payment terms'
                        : !customer.creditLimit
                          ? 'No credit limit'
                          : 'Within credit limit'
              }
            >
              {/* Why it needs the GM, in one sentence (11 Oct 2026). */}
              {whyText && <p style={{ margin: '0 0 8px' }}>{whyText}</p>}
              {/* No limit set: deliberately no green tick and no figures. A
                  reassurance nobody earned reads as a check that passed rather
                  than one that was never run. */}
              {customer?.creditLimit ? (
                <div className="credit__figs">
                  <span>
                    Outstanding <b className="num">{money(owed, 0)}</b>
                  </span>
                  <span>
                    This order <b className="num">{money(order.total, 0)}</b>
                  </span>
                  <span>
                    Projected <b className="num">{money(owed + order.total, 0)}</b>
                  </span>
                  <span>
                    Limit <b className="num">{money(customer.creditLimit, 0)}</b>
                  </span>
                </div>
              ) : null}

              {/*
                How old the debt is, under the figure it is part of. The four
                age buckets are displayed, not enforced. What escalates since
                11 Oct 2026 is the separate "overdue past payment terms" figure
                the SAP sync writes, which AgingBoxes also shows.
              */}
              {customer && <AgingBoxes customer={customerRow} />}
            </Alert>
          </div>

          {/*
            Straight under the credit picture it answers. The rep wrote it at
            the counter; the sales manager reads it before sending the order
            on, and may add to it.
          */}
          <CommitmentThread order={order} overLimit={overLimit} reloadKey={threadKey} />

          {/*
            What production moved since this browser last had the order open.
            Above the lines, because it is the thing the reader did not know —
            and the rep is the one who has to ring the customer about it.
          */}
          {stageNews.length > 0 && (
            <div style={{ marginBottom: 14 }}>
              <Alert
                tone="info"
                title={`${stageNews.length} ${
                  stageNews.length === 1 ? 'update' : 'updates'
                } since last viewed`}
              >
                <ul className="stagenews">
                  {stageNews.map((c) => (
                    <li key={`${c.lineId}-${c.part}`}>{describeChange(c)}</li>
                  ))}
                </ul>
              </Alert>
            </div>
          )}

          {/* --------------------------------------------- Block 4 — lines --- */}
          <Card title="Lines" flush>
            {order.lines.length === 0 ? (
              <Empty icon="—" title="No lines" />
            ) : (
              <div className="scroll-x">
                <table className="table ordlines">
                  <thead>
                    <tr>
                      <th>Item</th>
                      <th className="right">Qty</th>
                      <th className="right">Rate / kg</th>
                      <th className="right">Amount</th>
                      <th>Status</th>
                      <th>Stock</th>
                      <th>Served from</th>
                    </tr>
                  </thead>
                  <tbody>
                    {order.lines.map((l) => {
                      const edited = rateEdits[l.id];
                      /*
                       * One figure per line. It was three — a rate before
                       * discount, a percentage and a net rate — and the row was
                       * shaped as a raw ERPNext row so it went through the same
                       * helpers the phone used. The discount feature went on
                       * 17 September 2026 and the rep's rate is already net.
                       */
                      const rateMoved = edited != null && edited > 0 && edited !== l.ratePerKg;
                      const lineTotal = rateMoved ? l.totalWeight * edited : l.amount;
                      const pos = positionFor(l.itemCode, stock);
                      const split = splitOf(l, pos.available, stock.get(l.itemCode)?.beltsPerRoll ?? 0);
                      const mode = servedFrom(l);
                      const freeOnShelf = pos.available.rolls > 0 || pos.available.belts > 0;
                      const movedHere = movedLines.has(l.id);
                      return (
                        <tr key={l.id}>
                          <td>
                            <div>{l.itemName}</div>
                            <div className="tiny dim">{l.packingNote || l.category || '—'}</div>
                          </td>
                          <td className="right num">
                            {l.rolls ? `${l.rolls} roll${l.rolls === 1 ? '' : 's'}` : `${l.qty}`}
                            {l.looseBelts ? ` + ${l.looseBelts} belt${l.looseBelts === 1 ? '' : 's'}` : ''}
                            <div className="tiny dim">{l.totalWeight} kg</div>
                          </td>
                          <td className="right">
                            {/* Read-only once the GM has approved: the push goes
                                at the figures the GM approved. And while it is
                                with the GM, since only the GM may change it
                                (26 Sep 2026) and there is nothing here to
                                save the rates with. */}
                            {!rateEditable(role, l.rateApproved) ||
                            approved ||
                            gmApproved ||
                            !statusAllowsEdit(order.poStatus, role) ? (
                              <span className="num">{money(l.ratePerKg, 2)}</span>
                            ) : (
                              <Input
                                numeric
                                compact
                                type="number"
                                min={0}
                                step="0.01"
                                aria-label={`Rate for ${l.itemName}`}
                                value={edited ?? l.ratePerKg}
                                onChange={(e) =>
                                  setRateEdits((cur) => ({
                                    ...cur,
                                    [l.id]: Number(e.target.value) || 0,
                                  }))
                                }
                              />
                            )}
                          </td>
                          <td className="right num">
                            {/*
                              A Discount column stood between the rate and this
                              one: a per-line concession the manager could give,
                              change or withdraw, shown as "10% off - 875.00 to
                              787.50. Final." once the order was signed off.

                              Removed 17 September 2026. The sales team types
                              the rate AFTER discount, so the rate column beside
                              this one is the whole price story and this is
                              simply what it comes to. Lines saved before that
                              keep their stored percentage; nothing re-applies
                              it, and their `amount` was always the net figure.
                            */}
                            {rateMoved ? (
                              <b className="exp__corrected">{money(lineTotal, 0)}</b>
                            ) : (
                              money(lineTotal, 0)
                            )}
                          </td>
                          <td className="small">
                            {/*
                              SAP owns the floor, so the made portion's stage is
                              read from SAP below and nowhere else.

                              The "Being made" line that used to sit here showed
                              `custom_production_stage`, set by hand on the
                              production board. It was removed on 16 Sep 2026:
                              once SAP raises a production order per item, two
                              stages appear side by side on the same line and the
                              hand-set one is the stale one. Showing both is worse
                              than showing neither — a manager cannot tell which
                              to believe.

                              A "From stock" portion used to appear below with
                              its own stage, because stock served off the
                              minimum-stock pool never reached a SAP production
                              order. The pool is gone; every line is made
                              against a SAP production order or it is not
                              started.
                            */}
                            <div className={movedHere ? 'stagecell is-moved' : 'stagecell'}>
                              {l.stockStage && (
                                <div>
                                  <span className="stagecell__part">From stock</span>
                                  <b>{stageText(l.stockStage ?? '')}</b>
                                </div>
                              )}
                              {/*
                                What SAP says about THIS line: Pushed to SAP
                                until the line itself is invoiced, then
                                Dispatched with its invoice. Per line, because
                                an order can be invoiced in parts.

                                Derived, never string-matched here — see
                                domain/sapOrderState.ts.
                              */}
                              {reachedSap({ salesOrder: order.sapSalesOrder }) && (
                                <div className="stagecell__sap">
                                  <span className="stagecell__part">SAP</span>
                                  <b>
                                    {lineStatusFromSap(
                                      { invoice: l.sapInvoice },
                                      { salesOrder: order.sapSalesOrder },
                                    )}
                                  </b>
                                  {l.sapInvoice && (
                                    <div className="tiny dim">
                                      {[`Invoice ${l.sapInvoice}`, l.sapInvoiceDate].filter(Boolean).join(' · ')}
                                    </div>
                                  )}
                                </div>
                              )}
                              {!l.stockStage &&
                                !reachedSap({ salesOrder: order.sapSalesOrder }) &&
                                !l.sapInvoice && <span className="dim">—</span>}
                              {movedHere && <div className="stagecell__flag">Updated</div>}
                              {/*
                                Dispatch is separate from stage: a line can sit
                                at Packed while part of it has already gone
                                out. Shown only once something has actually
                                left, so an untouched line stays silent here.
                              */}
                              {(l.dispatchedRolls || l.dispatchedLooseBelts || l.dispatchShortReason) && (
                                <div className="stagecell__dispatch">
                                  <span className="stagecell__part">Dispatched</span>
                                  <b>{dispatchedLabel(l)}</b>
                                  {l.dispatchShortReason && (
                                    <div className="tiny dim">{l.dispatchShortReason}</div>
                                  )}
                                </div>
                              )}
                            </div>
                          </td>
                          <td className="small">
                            {/*
                              Two figures, from five.

                              The five were "on the shelf", "booked by other
                              orders", "free — nobody has booked it", "minimum
                              to hold" and what this order held, because four
                              of them had once been collapsed into "booked by
                              this order: 4 rolls + 2 belts" and nothing said
                              the order was for eight or that four had to be
                              made.

                              Four of the five no longer exist. SAP reports
                              available to promise, already net of every open
                              order including this one; there is no separate
                              shelf figure, no attribution of who holds what,
                              and no minimum (all 129 pool rows held zero).
                              What is left is what the manager decides on.
                            */}
                            {!pos.stocked ? (
                              <span className="dim tiny">Not stocked</span>
                            ) : !pos.weightsKnown ? (
                              <span className="dim tiny" title="No roll weight in the item master">
                                Weights not set
                              </span>
                            ) : (
                              <table className="stockpos">
                                <tbody>
                                  <tr>
                                    <td>Ordered</td>
                                    <td className="num">{qty(split.ordered)}</td>
                                  </tr>
                                  <tr className={freeOnShelf ? 'ok' : 'dim'}>
                                    <td>Available</td>
                                    <td className="num">{qty(pos.available)}</td>
                                  </tr>
                                  <tr
                                    className={
                                      split.toMake.rolls > 0 || split.toMake.belts > 0
                                        ? 'warn'
                                        : 'dim'
                                    }
                                  >
                                    <td>To make</td>
                                    <td className="num">{qty(split.toMake)}</td>
                                  </tr>
                                </tbody>
                              </table>
                            )}

                            {/*
                              One thing that still catches a reader out, said
                              plainly: once this order has reached SAP, its own
                              lines are inside the deduction above. A line can
                              therefore read as short by exactly what it
                              ordered, and that is correct — the rolls are
                              spoken for, by this order.
                            */}
                            {pos.stocked &&
                              pos.weightsKnown &&
                              !freeOnShelf &&
                              order.sapSalesOrder && (
                                <div className="stockpos__why">Committed to this order in SAP</div>
                              )}
                          </td>
                          <td>
                            {/*
                              Read-only, and deliberately so. A chooser here was
                              the wrong question to put to a sales manager: two
                              orders wanting more than the pool holds cannot both
                              be served from it however anybody picks, because the
                              stock belongs to whoever booked first — that booking
                              is already holding it. Offering the choice invited a
                              manager to "switch" a line and quietly take stock
                              off a rep.
                            */}
                            <div className={`served served--${modeTone(mode)}`}>
                              {modeLabel(mode)}
                            </div>
                            {split.isSplit && (
                              <div className="tiny dim">{describeSplit(split)}</div>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          {/*
            One total.

            It was three rows when the order carried a discount — before, the
            concession, and after — so somebody could see what had been given
            away. The discount feature went on 17 September 2026 and the rate
            the rep types is already net, so there is one figure and nothing
            hidden behind it.
          */}
          <div className="order__total">
            <span>Order total</span>
            <b>{money(preview.changed ? preview.total : order.total, 0)}</b>
          </div>
          {preview.changed && (
            <p className="order__was">Was {money(order.total, 0)} · new rates save on approval</p>
          )}

          {/* ------------------------------------- Block 6 — edit line-up --- */}
          <OrderLinesEditor
            order={order}
            role={user?.role}
            pool={pool}
            disabled={!!busy}
            lockedReason={
              approved ? (
                <>
                  This order is approved and is with the factory. It cannot be changed here
                  {order.sapSalesOrder ? ` — quote SAP order ${order.sapSalesOrder}` : ''}. To drop
                  or reduce an item, ring the manufacturing team: anything already made is
                  delivered and the rest of the order stays open.
                </>
              ) : !statusAllowsEdit(order.poStatus, user?.role) ? (
                // With the GM, or approved by them (26 Sep 2026): the sales
                // manager no longer changes it.
                (escalationLockReason(order.poStatus, user?.role) ??
                'Locked at this stage of approval.')
              ) : null
            }
            openNote={editOpenNote(order.poStatus)}
            onEditingChange={setEditing}
            onError={setError}
            onSaved={() => {
              setDone({
                text: 'Lines saved. The order needs a new decision.',
                tone: 'ok',
              });
              // A full reload, not the saved document: the stock column has to
              // be re-read against the new quantities too.
              reload();
            }}
          />

          {/* ------------------------------------------ Block 7 — decision --- */}
          {approved ? (
            <div className="mt-16">
              <Alert tone="ok" title="Approved · rates final" />
            </div>
          ) : rejected ? (
            /*
             * A rejected order shows its answer rather than the buttons that
             * produced it. Offering Approve and Reject again under the word
             * "Rejected" invites a second decision on an order the rep is
             * already correcting.
             *
             * Undo is the way back from this screen. The other is the rep's
             * own edit in the field app, which returns the order to Pending on
             * its own — so this state ends either when the manager changes
             * their mind or when the order itself changes, and not otherwise.
             */
            <div className="mt-16">
              <Alert
                tone="danger"
                icon="✕"
                title="Rejected · returned to the rep"
                actions={
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={undoRejection}
                    loading={busy === 'undo'}
                    disabled={!!busy || editing}
                  >
                    Undo rejection
                  </Button>
                }
              />
            </div>
          ) : isGeneralManager(role) ? (
            /*
             * The GM decides from their own review, which carries the
             * condition the approval creates. Deciding here would approve
             * without it, and the API would refuse an order with a commitment.
             */
            <div className="mt-16">
              <Alert
                tone="info"
                title="Decided in the GM review"
                actions={
                  <Link to={`/gm/orders/${order.id}`} className="btn btn--sm">
                    Open GM review
                  </Link>
                }
              />
            </div>
          ) : gmApproved && acts.approve ? (
            /*
             * Back from the GM, approved. The GM decided the credit and does
             * not push; the push is the sales manager's, and it is the only
             * move left — refusing what the GM approved is the GM's call.
             */
            <Card title="Approved by the General Manager" className="mt-16">
              <p className="decide__fact">
                Credit approved by <b>{order.gmApprovedBy || 'the GM'}</b>
                {order.gmApprovedOn ? ` on ${formatDate(order.gmApprovedOn.slice(0, 10))}` : ''}
                {hasCommitment(order.creditCommitment)
                  ? " · the rep's commitment is now a condition"
                  : ''}
              </p>
              <div className="decide__bar">
                <Button
                  variant="primary"
                  onClick={() => decide('approve')}
                  loading={busy === 'approve'}
                  disabled={!!busy || editing}
                >
                  Push to SAP
                </Button>
                {editing ? (
                  <span className="decide__hint is-warn">Save or cancel the line edits first</span>
                ) : (
                  <span className="decide__hint">Rates become final on push</span>
                )}
              </div>
            </Card>
          ) : withGm && !acts.approve ? (
            /*
             * With the GM, this is no longer the sales manager's to decide —
             * offering Send to GM again here used to re-escalate an order
             * already escalated. They can still add what they know, above.
             */
            <div className="mt-16">
              <Alert tone="info" title="With the General Manager for credit approval" />
            </div>
          ) : (
            <Card title="Decision" className="mt-16">
              {acts.escalate && (
                <>
                  <div className="decide__warn">
                    <Alert tone="warn" title="Over credit limit · GM approval required" />
                  </div>
                  <Field label="Note for GM (optional)">
                    <Textarea
                      rows={2}
                      value={gmNote}
                      onChange={(e) => setGmNote(e.target.value)}
                      placeholder="Context for the General Manager"
                      disabled={!!busy || editing}
                    />
                  </Field>
                </>
              )}
              <div className="decide__bar">
                {acts.approve && (
                  <Button
                    variant="primary"
                    onClick={() => decide('approve')}
                    loading={busy === 'approve'}
                    disabled={!!busy || editing}
                  >
                    Approve
                  </Button>
                )}
                {acts.escalate && (
                  <Button
                    variant="primary"
                    onClick={() => decide('escalate')}
                    loading={busy === 'escalate'}
                    disabled={!!busy || editing}
                  >
                    Send to GM
                  </Button>
                )}
                {acts.reject && (
                  <Button
                    variant="ghost"
                    onClick={() => decide('reject')}
                    loading={busy === 'reject'}
                    disabled={!!busy || editing}
                  >
                    Reject
                  </Button>
                )}
                {/* The decision applies to what is stored, not to what is on
                    screen, so it waits while lines are open in the editor. */}
                {editing ? (
                  <span className="decide__hint is-warn">Save or cancel the line edits first</span>
                ) : (
                  acts.approve && (
                    <span className="decide__hint">Rates become final on approval</span>
                  )
                )}
              </div>
            </Card>
          )}
        </>
      )}

      {!loading && !order && !error && <Empty icon="—" title="Order not found" />}
    </div>
  );
}
