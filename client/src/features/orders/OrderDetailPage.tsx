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
import type {
  ItemOption,
  MinStockLine,
  OrderDetail,
  OrderLine,
  SalesCustomer,
} from '@/domain/types';
import {
  isApproved,
  statusPill,
  escalates,
  rateEditable,
  boundByCutoff,
  PO_STATUS,
} from '@/domain/orderStatus';
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
import { orderLineValues } from '@/domain/productRules';
import {
  changedLineIds,
  changesSince,
  describeChange,
  loadSeen,
  saveSeen,
  snapshotOf,
  stageText,
} from '@/domain/stageWatch';
import { lineStatusFromSap } from '@/domain/sapOrderState';
import { pastCutoff, shortDate } from '@/domain/weeks';
import { serverNow } from '@/domain/serverClock';
import { formatDate } from '@/domain/orderRules';
import { Api, type OrderLineWrite, type OrderSyncState } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Button, Card, Empty, Input } from '@/components/ui';
import { money } from '@/components/common/format';
import { RefreshButton } from '@/components/common/RefreshButton';
import { AgingBoxes } from '@/components/common/AgingBoxes';
import { StatusPill } from '@/components/common/StatusPill';
import { ItemPicker, asProduct } from './ItemPicker';
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

interface Draft {
  id?: string;
  item: ItemOption;
  rolls: number;
  looseBelts: number;
  kg: number;
  tins: number;
  ratePerKg: number;
  fulfilmentMode: string;
  removed: boolean;
}

export function OrderDetailPage() {
  const { orderId = '' } = useParams();
  const user = useAppSelector(selectUser);

  const [order, setOrder] = useState<OrderDetail | null>(null);
  const [customer, setCustomer] = useState<SalesCustomer | null>(null);
  const [pool, setPool] = useState<MinStockLine[]>([]);
  const [items, setItems] = useState<ItemOption[]>([]);
  const [itemsLoading, setItemsLoading] = useState(false);
  const [rateEdits, setRateEdits] = useState<Record<string, number>>({});
  const [drafts, setDrafts] = useState<Draft[] | null>(null);
  const [picking, setPicking] = useState(false);
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  /**
   * What production moved since this browser last opened the order.
   *
   * Computed once per load and held, so it does not vanish the moment the
   * snapshot is written back. The first look reports nothing — it establishes
   * the baseline rather than dumping every stage as news.
   */
  const [stageNews, setStageNews] = useState<ReturnType<typeof changesSince>>([]);

  /** Where the SAP order sync has got to, so the manager knows how old this is. */
  const [syncState, setSyncState] = useState<OrderSyncState | null>(null);
  const [syncNote, setSyncNote] = useState<string | null>(null);

  /**
   * Refresh means two things, and the manager should get both.
   *
   * Re-reading ERPNext is instant and always happens. Re-reading SAP cannot:
   * Frappe Cloud has no route to the SAP LAN, so the request is a flag an
   * on-prem watcher picks up within about half a minute. The page therefore
   * reloads immediately with what ERPNext has now, and says separately when
   * the floor was last read and whether a fresh read is on its way.
   *
   * A refused request is a normal answer — inside the cooldown the script
   * declines — so it is reported, never thrown.
   */
  const reload = useCallback(() => {
    setTick((t) => t + 1);
    Api.sales
      .requestOrderSync()
      .then((s) => {
        setSyncState(s);
        setSyncNote(
          s.accepted
            ? 'Asked SAP for the latest. Refresh again in a moment to see it.'
            : `SAP was read very recently — next refresh available ${s.cooldownUntil ?? 'shortly'}.`,
        );
      })
      .catch(() => {
        // Never block the ERPNext reload on this: the order is still worth
        // showing when the SAP side cannot be asked.
        setSyncNote(null);
      });
  }, []);

  useEffect(() => {
    let live = true;
    Api.sales
      .getOrderSyncState()
      .then((s) => live && setSyncState(s))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [tick]);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    setRateEdits({});
    setDrafts(null);
    Api.sales
      .getOrder(orderId)
      .then(async (o) => {
        if (!live) return;
        setOrder(o);

        // Diff before the snapshot is overwritten, then record what is now on
        // screen. Keyed on the child row name, which survives an edit.
        // The made portion's movement now comes from SAP, so that is what the
        // "moved since you last looked" notice reports. Fed in under the old key
        // so the watcher itself is unchanged — only the source of truth moved.
        const rows = o.lines.map((l) => ({
          name: l.id,
          item_name: l.itemName,
          custom_production_stage: l.sapProductionStage,
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

  const loadItems = async (): Promise<ItemOption[]> => {
    if (items.length) return items;
    setItemsLoading(true);
    try {
      const list = await Api.sales.listItemOptions();
      setItems(list);
      return list;
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not read the item master.');
      return [];
    } finally {
      setItemsLoading(false);
    }
  };

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
    }),
    [customer],
  );

  const movedLines = useMemo(() => changedLineIds(stageNews), [stageNews]);

  const stock = useMemo(() => poolByItem(pool), [pool]);
  // The server's clock, not the browser's: this decides whether a change is
  // allowed, and a user controls their own clock.
  const now = useMemo(() => serverNow(), [tick, order]);
  const approved = order ? isApproved(order.poStatus) : false;
  const editing = drafts !== null;

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
   * Failing that, an order freezes at 13:00 on its delivery date. No delivery
   * date means **permanently open**, not shut — an order without a date is a
   * data problem and refusing to let anyone fix it makes it worse.
   */
  const frozenByCutoff = order
    ? pastCutoff(order.deliveryDate, now) && boundByCutoff(user?.role)
    : false;

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
      const saved = await Api.sales.decideOrder({
        id: order.id,
        decision,
        rateEdits: decision === 'approve' ? rateEdits : undefined,
        role: user?.role,
      });
      setOrder(saved);
      setRateEdits({});
      setDone(
        decision === 'approve'
          ? 'Approved. Every rate on this order is now final.'
          : decision === 'reject'
            ? 'Rejected. The rep can correct the prices and resubmit.'
            : 'Sent to the General Manager.',
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the decision.');
    } finally {
      setBusy(null);
    }
  };

  const startEditing = async () => {
    if (!order) return;
    const master = await loadItems();
    const byCode = new Map(master.map((i) => [i.code, i]));
    const next: Draft[] = [];
    const orphans: string[] = [];
    for (const l of order.lines) {
      const item = byCode.get(l.itemCode);
      if (!item) {
        orphans.push(l.itemCode);
        continue;
      }
      next.push({
        id: l.id,
        item,
        rolls: l.rolls,
        looseBelts: l.looseBelts,
        kg: item.category === 'BG' ? l.totalWeight : 0,
        tins: item.category === 'VS' ? l.qty : 0,
        ratePerKg: l.ratePerKg,
        fulfilmentMode: l.fulfilmentMode ?? '',
        removed: false,
      });
    }
    if (orphans.length) {
      setError(
        `${orphans.length} line(s) could not be opened for editing because their item is missing or disabled in the master: ${orphans.join(', ')}. Editing here would drop them, so the editor was not opened.`,
      );
      return;
    }
    setDrafts(next);
  };

  const saveLines = async () => {
    if (!order || !drafts) return;
    const kept = drafts.filter((d) => !d.removed);
    if (kept.length === 0) {
      setError('An order needs at least one line. Reject the order instead of emptying it.');
      return;
    }
    setBusy('lines');
    setError(null);
    try {
      const lines: OrderLineWrite[] = kept.map((d) => {
        const v = orderLineValues(asProduct(d.item), {
          rolls: d.rolls,
          looseBelts: d.looseBelts,
          kg: d.kg,
          tins: d.tins,
          ratePerKg: d.ratePerKg,
        });
        return {
          id: d.id,
          itemCode: d.item.code,
          category: d.item.category,
          rolls: d.rolls,
          looseBelts: d.looseBelts,
          ratePerKg: d.ratePerKg,
          /*
           * The item's OWN stock UOM, never one derived from its category.
           *
           * `uomFor('VS')` returns "L", which is a fine label for a person but
           * is not a UOM record on this site — the vulcanising solution items
           * carry `stock_uom: "Litre"`. Writing "L" made ERPNext reject the
           * entire save with "Could not find Row #2: UOM: L", so a manager
           * could not change a quantity on any order containing solution.
           *
           * An item's own stock UOM is always valid by construction, so this
           * cannot drift again when a new family is added.
           */
          uom: d.item.uom,
          fulfilmentMode: d.fulfilmentMode,
          ...v,
        };
      });
      await Api.sales.saveOrderLines({ orderId: order.id, lines });
      setDrafts(null);
      setDone(
        'Lines saved, and the stock re-held to match. Anything on the shelf has been booked to this order; only what the shelf has not got is left for production. The order went back for approval and every rate reopened, because the money changed.',
      );
      // A full reload, not the saved document. Saving also moves the holds, and
      // the returned order carries none of that — the stock column would keep
      // showing the position from before the edit.
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the lines.');
    } finally {
      setBusy(null);
    }
  };


  const patch = (idx: number, change: Partial<Draft>) =>
    setDrafts((cur) => cur?.map((d, i) => (i === idx ? { ...d, ...change } : d)) ?? cur);

  const addItem = (item: ItemOption) => {
    setPicking(false);
    setDrafts((cur) => [
      ...(cur ?? []),
      {
        item,
        rolls: item.category === 'PCTR' || item.category === 'CTR' ? 1 : 0,
        looseBelts: 0,
        kg: item.category === 'BG' ? 5 : 0,
        tins: item.category === 'VS' ? 1 : 0,
        ratePerKg: 0,
        fulfilmentMode: '',
        removed: false,
      },
    ]);
  };

  const draftTotal = useMemo(() => {
    if (!drafts) return 0;
    return drafts
      .filter((d) => !d.removed)
      .reduce(
        (sum, d) =>
          sum +
          orderLineValues(asProduct(d.item), {
            rolls: d.rolls,
            looseBelts: d.looseBelts,
            kg: d.kg,
            tins: d.tins,
            ratePerKg: d.ratePerKg,
          }).amount,
        0,
      );
  }, [drafts]);

  /*
   * Escalation is on the CUSTOMER's credit limit, not the rep's outstanding.
   * When it trips, the manager's Approve becomes Send to GM — they no longer
   * have the power to finalise this one.
   */
  const overLimit = order
    ? escalates({
        outstanding: customer?.outstanding,
        creditLimit: customer?.creditLimit,
        orderTotal: order.total,
      })
    : false;

  /** The GM is exempt from the 1 pm freeze and from the rate lock. */
  const role = user?.role;

  const pill = statusPill(order?.poStatus);

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
                Raised by {order.rep} · delivery{' '}
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
                    <b className="mono">SAP order {order.sapSalesOrder}</b>{' '}
                    <span className="tiny dim">({order.id} in ERPNext)</span>
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
        <div className="cal__nav">
          {order && <StatusPill status={order.poStatus} />}
          <RefreshButton onClick={reload} loading={loading} />
          <Link to="/orders" className="btn btn--ghost btn--sm">
            ← Team orders
          </Link>
        </div>
      </div>

      {/*
        How old the SAP half of this page is.
        Refresh re-reads ERPNext instantly but can only *ask* for SAP, so the
        manager is told when the floor was actually last read rather than being
        left to assume the figures are live. Silent until SAP has run at least
        once, so an order that never reached SAP says nothing here.
      */}
      {syncState?.lastSyncAt && (
        <p className="tiny dim" style={{ marginTop: 0 }}>
          Factory floor last read from SAP: <b>{syncState.lastSyncAt}</b>
          {syncState.status === 'Running'
            ? ' · reading now…'
            : syncState.queued
              ? ' · a fresh read is on its way'
              : ''}
          {syncState.status === 'Failed' && ' · last attempt failed'}
          {syncNote && ` — ${syncNote}`}
        </p>
      )}

      {error && (
        <Alert tone="danger" title="Could not read or save">
          {error}
        </Alert>
      )}
      {done && !error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="ok" title={done} />
        </div>
      )}
      {loading && !error && <Empty icon="◔" title="Reading order…" />}

      {!loading && order && (
        <>
          {order.changedAfterApproval && (
            <div style={{ marginBottom: 14 }}>
              <Alert tone="danger" title="Changed after approval">
                A rep edited this order after it was approved. Production may already be building
                the old quantities.
              </Alert>
            </div>
          )}

          {/* -------------------------------------------- Block 3 — credit --- */}
          <div style={{ marginBottom: 14 }}>
            <Alert
              tone={overLimit ? 'danger' : customer?.creditLimit ? 'ok' : 'info'}
              title={
                !customer
                  ? 'Party not found'
                  : !customer.creditLimit
                    ? 'New party — no credit limit recorded'
                    : overLimit
                      ? 'Over credit limit'
                      : 'Within credit limit'
              }
            >
              {customer?.creditLimit ? (
                <>
                  Owes {money(customer.outstanding, 0)} · this order {money(order.total, 0)} ·
                  projected <b>{money(customer.outstanding + order.total, 0)}</b> against a limit
                  of {money(customer.creditLimit, 0)}.
                  {overLimit && ' This is a warning, not a block — the decision is yours.'}
                </>
              ) : (
                /* No limit set: deliberately no green tick. A reassurance
                   nobody earned reads as a check that passed rather than one
                   that was never run. */
                <>No trading history or credit limit to check against.</>
              )}

              {/*
                How old the debt is, under the figure it is part of.
                Displayed, not enforced: the credit rule above is still the
                total against the limit, and nothing here blocks or escalates.
                Adding that silently would start stopping orders the day it
                shipped, on customers nobody had warned.
              */}
              {customer && <AgingBoxes customer={customerRow} />}
            </Alert>
          </div>

          {/*
            What production moved since this browser last had the order open.
            Above the lines, because it is the thing the reader did not know —
            and the rep is the one who has to ring the customer about it.
          */}
          {stageNews.length > 0 && (
            <div style={{ marginBottom: 14 }}>
              <Alert
                tone="info"
                title={`Production moved ${stageNews.length} item ${
                  stageNews.length === 1 ? 'stage' : 'stages'
                } since you last looked`}
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
          <p className="note lines__lead">
            Where each line is served from is reported, not chosen — the first booking takes the
            shelf, a claim takes a production run, and the rest is made to order.
          </p>
          <Card title="Lines" flush>
            {order.lines.length === 0 ? (
              <Empty icon="—" title="This order has no lines" />
            ) : (
              <div className="scroll-x">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Item</th>
                      <th className="right">Qty</th>
                      <th className="right">Rate / kg</th>
                      <th className="right">Disc %</th>
                      <th className="right">Amount</th>
                      <th>Stage</th>
                      <th>Minimum stock</th>
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
                            {!rateEditable(role, l.rateApproved) || (approved && boundByCutoff(role)) ? (
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
                                What SAP says about THIS line. SAP raises one
                                production order per item, so this is the only
                                place that can say which item is holding the
                                order back — the order-level stage is a roll-up
                                of the least advanced line and hides that.

                                The status is derived, never string-matched
                                here: the stage list belongs to the factory and
                                changes without a release.
                              */}
                              {(l.sapProductionOrder || l.sapProductionStage || l.sapDeliveryOrder) && (
                                <div className="stagecell__sap">
                                  <span className="stagecell__part">SAP</span>
                                  <b>
                                    {lineStatusFromSap({
                                      productionOrder: l.sapProductionOrder,
                                      productionStage: l.sapProductionStage,
                                      deliveryOrder: l.sapDeliveryOrder,
                                    })}
                                  </b>
                                  <div className="tiny dim">
                                    {[
                                      l.sapDeliveryOrder && `Delivery ${l.sapDeliveryOrder}`,
                                      l.sapDeliveryOrder && l.sapDeliveryDate && `leaves ${l.sapDeliveryDate}`,
                                      !l.sapDeliveryOrder && l.sapProductionStage,
                                      l.sapProductionOrder && `PO ${l.sapProductionOrder}`,
                                    ]
                                      .filter(Boolean)
                                      .join(' · ')}
                                  </div>
                                </div>
                              )}
                              {!l.stockStage &&
                                !l.sapProductionOrder &&
                                !l.sapProductionStage &&
                                !l.sapDeliveryOrder && <span className="dim">—</span>}
                              {movedHere && <div className="stagecell__flag">moved</div>}
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
                              <span className="dim tiny">not stocked</span>
                            ) : !pos.weightsKnown ? (
                              <span
                                className="dim tiny"
                                title="SAP holds this in kilograms and the item master has no weight per roll, so how many rolls that is cannot be worked out."
                              >
                                weights not set
                              </span>
                            ) : (
                              <table className="stockpos">
                                <tbody>
                                  <tr>
                                    <td>Ordered</td>
                                    <td className="num">{qty(split.ordered)}</td>
                                  </tr>
                                  <tr className={freeOnShelf ? 'ok' : 'dim'}>
                                    <td>Available in SAP</td>
                                    <td className="num">{qty(pos.available)}</td>
                                  </tr>
                                  <tr
                                    className={
                                      split.toMake.rolls > 0 || split.toMake.belts > 0
                                        ? 'warn'
                                        : 'dim'
                                    }
                                  >
                                    <td>Must be made</td>
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
                                <div className="stockpos__why">
                                  This order is in SAP, so the rolls it asked for are already
                                  committed to it and are not counted as available here.
                                </div>
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
            <p className="note right">
              Was {money(order.total, 0)}. Rates save when you approve.
            </p>
          )}

          {/* ------------------------------------- Block 6 — edit line-up --- */}
          {!editing && (
            <div className="line__edit-bar">
              {approved ? (
                <span className="note">
                  This order is approved and is with the factory. It cannot be changed here
                  {order.sapSalesOrder ? ` — quote SAP order ${order.sapSalesOrder}` : ''}. To drop
                  or reduce an item, ring the manufacturing team: anything already made is
                  delivered and the rest of the order stays open.
                </span>
              ) : frozenByCutoff ? (
                <span className="note">
                  Changes closed at 1 pm on {shortDate(order.deliveryDate)}, the required delivery
                  date.
                </span>
              ) : (
                <>
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={startEditing}
                    loading={itemsLoading}
                    disabled={!!busy}
                  >
                    Add / Remove / Requantify
                  </Button>
                  <span className="note grow">
                    {order.deliveryDate
                      ? `Open until 1 pm on ${shortDate(order.deliveryDate)}.`
                      : 'No delivery date set, so this order stays open to changes.'}
                  </span>
                </>
              )}
            </div>
          )}

          {editing && drafts && (
            <>
              <Card title="Editing lines" flush>
                <div className="scroll-x">
                  <table className="table">
                    <thead>
                      <tr>
                        <th>Item</th>
                        <th className="right">Quantity</th>
                        <th className="right">Weight</th>
                        <th className="right">Rate / kg</th>
                        <th className="right">Amount</th>
                        <th />
                      </tr>
                    </thead>
                    <tbody>
                      {drafts.map((d, i) => {
                        const v = orderLineValues(asProduct(d.item), {
                          rolls: d.rolls,
                          looseBelts: d.looseBelts,
                          kg: d.kg,
                          tins: d.tins,
                          ratePerKg: d.ratePerKg,
                        });
                        return (
                          <tr
                            key={d.id ?? `new-${i}`}
                            className={d.removed ? 'line--removed' : d.id ? '' : 'line--dirty'}
                          >
                            <td>
                              <div>{d.item.name}</div>
                              <div className="mono tiny dim">
                                {d.item.category}
                                {d.item.beltsPerRoll ? ` · ${d.item.beltsPerRoll} belts/roll` : ''}
                                {d.item.weightPerRoll ? ` · ${d.item.weightPerRoll} kg/roll` : ''}
                              </div>
                            </td>
                            <td>
                              <div className="line__qty">
                                {(d.item.category === 'PCTR' || d.item.category === 'CTR') && (
                                  <>
                                    <label htmlFor={`rolls-${i}`}>Rolls</label>
                                    <Input
                                      id={`rolls-${i}`}
                                      numeric
                                      compact
                                      type="number"
                                      min={0}
                                      disabled={d.removed}
                                      value={d.rolls}
                                      onChange={(e) => patch(i, { rolls: Number(e.target.value) || 0 })}
                                    />
                                  </>
                                )}
                                {d.item.category === 'PCTR' && (
                                  <>
                                    <label htmlFor={`belts-${i}`}>Belts</label>
                                    <Input
                                      id={`belts-${i}`}
                                      numeric
                                      compact
                                      type="number"
                                      min={0}
                                      disabled={d.removed}
                                      value={d.looseBelts}
                                      onChange={(e) =>
                                        patch(i, { looseBelts: Number(e.target.value) || 0 })
                                      }
                                    />
                                  </>
                                )}
                                {d.item.category === 'BG' && (
                                  <>
                                    <label htmlFor={`kg-${i}`}>Kg</label>
                                    <Input
                                      id={`kg-${i}`}
                                      numeric
                                      compact
                                      type="number"
                                      min={0}
                                      step={5}
                                      disabled={d.removed}
                                      value={d.kg}
                                      onChange={(e) => patch(i, { kg: Number(e.target.value) || 0 })}
                                    />
                                  </>
                                )}
                                {d.item.category === 'VS' && (
                                  <>
                                    <label htmlFor={`tins-${i}`}>Tins</label>
                                    <Input
                                      id={`tins-${i}`}
                                      numeric
                                      compact
                                      type="number"
                                      min={0}
                                      disabled={d.removed}
                                      value={d.tins}
                                      onChange={(e) => patch(i, { tins: Number(e.target.value) || 0 })}
                                    />
                                  </>
                                )}
                              </div>
                            </td>
                            <td className="right num">{v.totalWeight} kg</td>
                            <td className="right">
                              <Input
                                numeric
                                compact
                                type="number"
                                min={0}
                                step="0.01"
                                disabled={d.removed}
                                aria-label={`Rate for ${d.item.name}`}
                                value={d.ratePerKg}
                                onChange={(e) => patch(i, { ratePerKg: Number(e.target.value) || 0 })}
                              />
                            </td>
                            <td className="right num">{money(v.amount, 0)}</td>
                            <td>
                              <Button
                                size="sm"
                                variant="ghost"
                                onClick={() => patch(i, { removed: !d.removed })}
                              >
                                {d.removed ? 'Undo' : 'Remove'}
                              </Button>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              </Card>

              {picking && (
                <ItemPicker
                  items={items}
                  pool={pool}
                  loading={itemsLoading}
                  onPick={addItem}
                  onClose={() => setPicking(false)}
                />
              )}

              <div className="line__edit-bar">
                <Button size="sm" variant="ghost" onClick={() => setPicking((p) => !p)}>
                  {picking ? 'Close list' : '+ Add item'}
                </Button>
                <span className="grow" />
                <span className="note">
                  New total <b>{money(draftTotal, 0)}</b>, was {money(order.total, 0)}
                </span>
                <Button onClick={saveLines} loading={busy === 'lines'} disabled={!!busy}>
                  Save lines
                </Button>
                <Button
                  variant="ghost"
                  onClick={() => {
                    setDrafts(null);
                    setPicking(false);
                  }}
                  disabled={!!busy}
                >
                  Cancel
                </Button>
              </div>
              <p className="note">
                Saving replaces the order's lines — anything marked Remove is deleted. Because the
                money changes, the order goes back for approval and every rate reopens.
              </p>
            </>
          )}


          {/* ------------------------------------------ Block 7 — decision --- */}
          {approved ? (
            <div className="mt-16">
              <Alert tone="ok" title="✓ Approved. Rates on this order are final." />
            </div>
          ) : (
            <Card title="Decision" className="mt-16">
              <p className="note" style={{ marginBottom: 10 }}>
                {overLimit ? 'The General Manager decides this one.' : 'Approving fixes every rate on this order permanently.'}
              </p>
              {overLimit && (
                <div style={{ marginBottom: 10 }}>
                  <Alert tone="warn" title="This order takes the customer past their credit limit">
                    Approving sends it to the General Manager rather than finalising it.
                  </Alert>
                </div>
              )}
              <div className="lv__actions" style={{ justifyContent: 'flex-start', gap: 8 }}>
                <Button
                  onClick={() => decide(overLimit ? 'escalate' : 'approve')}
                  loading={busy === 'approve' || busy === 'escalate'}
                  disabled={!!busy || editing}
                >
                  {overLimit ? 'Send to GM' : 'Approve'}
                </Button>
                <Button
                  variant="ghost"
                  onClick={() => decide('reject')}
                  disabled={!!busy || editing}
                >
                  Reject
                </Button>

              </div>
              {editing && (
                <p className="note" style={{ marginTop: 10 }}>
                  Save or cancel your line edits first — the decision applies to what is stored,
                  not to what is on screen.
                </p>
              )}
            </Card>
          )}

          <p className="note" style={{ marginTop: 12 }}>
            Status is read from the order's own status field, not from its rate-approved flag: a rep
            editing an approved order sends it back here while the flag stays set, so the flag would
            hide work that needs doing again. Current stored value:{' '}
            <span className="mono">{order.poStatus || PO_STATUS.none}</span> — shown as “{pill.text}”.
          </p>
        </>
      )}

      {!loading && !order && !error && <Empty icon="—" title="Order not found" />}
      {user && null}
    </div>
  );
}
