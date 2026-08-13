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
  StockReservationRow,
} from '@/domain/types';
import {
  isApproved,
  statusPill,
  escalates,
  rateEditable,
  boundByCutoff,
  orderSignedOff,
  PO_STATUS,
} from '@/domain/orderStatus';
import {
  coverFor,
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
import {
  MAX_DISCOUNT_PERCENT,
  discountRefusal,
  discountTotals,
  discountedRate,
  isDiscounted,
  lineAfterDiscount,
  lineBeforeDiscount,
  rateAfterDiscount,
  rateBeforeDiscount,
  type PricedRow,
} from '@/domain/discount';
import { pastCutoff, shortDate } from '@/domain/weeks';
import { serverNow } from '@/domain/serverClock';
import { formatDate } from '@/domain/orderRules';
import { Api, type OrderLineWrite } from '@/api/client';
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
  const [reservations, setReservations] = useState<StockReservationRow[]>([]);
  const [items, setItems] = useState<ItemOption[]>([]);
  const [itemsLoading, setItemsLoading] = useState(false);
  const [rateEdits, setRateEdits] = useState<Record<string, number>>({});
  /** The line whose discount is being set, and the figure typed so far. */
  const [discounting, setDiscounting] = useState<{ line: OrderLine; typed: string } | null>(null);
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

  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    setRateEdits({});
    setDiscounting(null);
    setDrafts(null);
    Api.sales
      .getOrder(orderId)
      .then(async (o) => {
        if (!live) return;
        setOrder(o);

        // Diff before the snapshot is overwritten, then record what is now on
        // screen. Keyed on the child row name, which survives an edit.
        const rows = o.lines.map((l) => ({
          name: l.id,
          item_name: l.itemName,
          custom_production_stage: l.productionStage,
          custom_stock_stage: l.stockStage,
        }));
        setStageNews(changesSince(loadSeen(o.id), rows));
        saveSeen(o.id, snapshotOf(rows));
        const [parties, stock, res] = await Promise.all([
          Api.sales.listCustomers().catch(() => []),
          Api.sales.listMinimumStock().catch(() => [] as MinStockLine[]),
          Api.sales.listReservations().catch(() => [] as StockReservationRow[]),
        ]);
        if (!live) return;
        setCustomer(parties.find((c) => c.id === o.customer) ?? null);
        setPool(stock);
        setReservations(res);
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
  /*
   * The gate on discounts. NOT `rateEditable` — this one has no GM exemption,
   * because the phone has none (`orderSignedOff` in app/lib/core/order_rules.dart)
   * and a signed price that can be moved from a desk but not from a counter is
   * worse than either rule alone. Settled 13 Aug 2026 in favour of the phone.
   */
  const signedOff = order
    ? orderSignedOff({ poStatus: order.poStatus, ratesApproved: order.ratesApproved }, false)
    : false;
  const editing = drafts !== null;

  /**
   * Whether the line-up may still be changed.
   *
   * An order freezes at 13:00 on its delivery date. No delivery date means
   * **permanently open**, not shut — an order without a date is a data problem
   * and refusing to let anyone fix it makes it worse.
   */
  const editClosed = order ? pastCutoff(order.deliveryDate, now) && boundByCutoff(user?.role) : false;

  /**
   * The order total as it stands on screen, before and after discount.
   *
   * Rebuilt from the lines rather than read off `order.total`, because a rate
   * the manager has typed and a discount they have set are not saved until the
   * decision — and an approval screen showing yesterday's total is how a
   * manager signs off money they did not intend.
   */
  /**
   * The order as it stands on screen, before and after discount.
   *
   * Rebuilt from the lines rather than read off `order.total`, because a rate
   * the manager has typed is not saved until the decision — and an approval
   * screen showing yesterday's total is how a manager signs off money they did
   * not intend. Discounts, unlike rates, are already saved: they are written
   * line by line as they are given, the way the phone writes them.
   *
   * Shaped as raw ERPNext rows on purpose, so it goes through exactly the
   * helpers the phone uses rather than a second arithmetic written here.
   */
  const preview = useMemo(() => {
    if (!order) return { ...discountTotals([]), changed: false };
    let changed = false;
    const rows: PricedRow[] = order.lines.map((l) => {
      const edited = rateEdits[l.id];
      const rateMoved = edited != null && edited > 0 && edited !== l.ratePerKg;
      if (rateMoved) changed = true;
      // A retyped rate is a rate BEFORE discount, so the line's percentage is
      // re-applied to it rather than the new figure replacing the net rate.
      const before = rateMoved && l.qty > 0 ? (l.totalWeight * edited) / l.qty : l.priceListRate;
      const net = discountedRate(before, l.discountPercent);
      return {
        qty: l.qty,
        rate: net,
        amount: rateMoved ? 0 : l.amountAfterDiscount,
        price_list_rate: before,
        discount_percentage: l.discountPercent,
      };
    });
    return { ...discountTotals(rows), changed };
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

  /**
   * Give, change or remove a discount on one line.
   *
   * Written the moment it is confirmed, not queued until the approval. That is
   * what the phone does, and a dashboard that held it would leave a manager
   * who set a discount and walked away believing they had given one.
   */
  const applyDiscount = async () => {
    if (!order || !discounting) return;
    const percent = Number(discounting.typed);
    const refusal = discountRefusal(percent);
    if (refusal) {
      setError(refusal);
      return;
    }
    setBusy('discount');
    setError(null);
    try {
      await Api.sales.setLineDiscount({
        orderId: order.id,
        lineId: discounting.line.id,
        percent,
      });
      setDone(percent > 0 ? `Discount of ${percent}% applied.` : 'Discount removed.');
      setDiscounting(null);
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the discount.');
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
                <span className="mono">{order.id}</span>
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
                       * The line as a raw ERPNext row, so every figure below
                       * comes out of the same helpers the phone uses. A rate
                       * the manager has retyped is a rate BEFORE discount, so
                       * the stored percentage is re-applied to it rather than
                       * the new figure replacing the net rate.
                       */
                      const rateMoved = edited != null && edited > 0 && edited !== l.ratePerKg;
                      const beforeRate =
                        rateMoved && l.qty > 0 ? (l.totalWeight * edited) / l.qty : l.priceListRate;
                      const row: PricedRow = {
                        qty: l.qty,
                        rate: discountedRate(beforeRate, l.discountPercent),
                        amount: rateMoved ? 0 : l.amountAfterDiscount,
                        price_list_rate: beforeRate,
                        discount_percentage: l.discountPercent,
                      };
                      const lineDiscount = l.discountPercent;
                      const pos = positionFor(l.itemCode, stock, reservations, order.id);
                      const split = splitOf(l, reservations, order.id);
                      // Measured against the UNBOOKED shelf, so it never offers
                      // a roll another order is already holding.
                      const cover = coverFor(split, pos.freeForOthers);
                      const mode = servedFrom(l, reservations, order.id);
                      const heldElsewhere = pos.heldByOthers.rolls > 0 || pos.heldByOthers.belts > 0;
                      const freeOnShelf = pos.freeForOthers.rolls > 0 || pos.freeForOthers.belts > 0;
                      const heldHere = cover.reserved.rolls > 0 || cover.reserved.belts > 0;
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
                          <td className="right">
                            {/*
                              The concession, per line rather than per order.
                              A discount is nearly always about one product,
                              and spreading it across the order would give it
                              away on items nobody negotiated on.

                              Once the order is signed off this becomes a plain
                              statement of what was given, with no way in — for
                              everyone, the GM included. A line that never had
                              a discount says nothing at all: an order with no
                              discounts should not be covered in notices about
                              discounts.
                            */}
                            {signedOff ? (
                              lineDiscount > 0 ? (
                                <span className="tiny disc__final">
                                  {lineDiscount}% off — {money(rateBeforeDiscount(row), 2)} to{' '}
                                  {money(rateAfterDiscount(row), 2)}. Final.
                                </span>
                              ) : (
                                <span className="dim">—</span>
                              )
                            ) : (
                              <button
                                type="button"
                                className="btn btn--ghost btn--sm"
                                disabled={!!busy}
                                onClick={() =>
                                  setDiscounting({
                                    line: l,
                                    typed: lineDiscount > 0 ? String(lineDiscount) : '',
                                  })
                                }
                              >
                                {lineDiscount > 0 ? `${lineDiscount}% off · Change` : 'Discount'}
                              </button>
                            )}
                          </td>
                          <td className="right num">
                            {isDiscounted(row) ? (
                              /* The full price stays visible beside the
                                 discounted one. A total that quietly became
                                 smaller is a total nobody can check. */
                              <>
                                <div className="line__was">
                                  {money(lineBeforeDiscount(row), 0)}
                                </div>
                                <b className="exp__corrected">{money(lineAfterDiscount(row), 0)}</b>
                              </>
                            ) : edited != null && edited !== l.ratePerKg ? (
                              <b className="exp__corrected">{money(lineAfterDiscount(row), 0)}</b>
                            ) : (
                              money(lineAfterDiscount(row), 0)
                            )}
                          </td>
                          <td className="small">
                            {/*
                              Both halves, each on its own line. A split line's
                              made and shelf portions finish separately, and one
                              combined stage would be a fiction on every order
                              that is part stock and part production.
                            */}
                            <div className={movedHere ? 'stagecell is-moved' : 'stagecell'}>
                              {(cover.needsProduction || l.productionStage) && (
                                <div>
                                  <span className="stagecell__part">Being made</span>
                                  <b>{stageText(l.productionStage ?? '')}</b>
                                </div>
                              )}
                              {(heldHere || l.stockStage) && (
                                <div>
                                  <span className="stagecell__part">From stock</span>
                                  <b>{stageText(l.stockStage ?? '')}</b>
                                </div>
                              )}
                              {!cover.needsProduction &&
                                !l.productionStage &&
                                !heldHere &&
                                !l.stockStage && <span className="dim">—</span>}
                              {movedHere && <div className="stagecell__flag">moved</div>}
                            </div>
                          </td>
                          <td className="small">
                            {!pos.pooled ? (
                              <span className="dim tiny">not stocked</span>
                            ) : (
                              /*
                               * Five separate figures, because four of them
                               * were once collapsed into "booked by this
                               * order: 4 rolls + 2 belts" and nothing said the
                               * order was for eight or that four had to be
                               * made. Production then read "8 rolls" with four
                               * already in the plant, and a run raised off that
                               * screen would have been for double.
                               */
                              <table className="stockpos">
                                <tbody>
                                  {/*
                                    Two questions, asked in order and kept
                                    apart: what is on the shelf and who has it,
                                    then what this order needs.

                                    "Booked by other orders" is the row that
                                    was missing. Without it a shelf of 2 sat
                                    above "must be made: 4" with two dashes in
                                    between, and the only way to work out that
                                    somebody else held both rolls was to notice
                                    that nothing was free. A manager should not
                                    have to do arithmetic to find out why an
                                    order is going to production.
                                  */}
                                  <tr className="stockpos__head">
                                    <td colSpan={2}>The shelf</td>
                                  </tr>
                                  <tr>
                                    <td>On the shelf now</td>
                                    <td className="num">{qty({ rolls: pos.shelf, belts: 0 })}</td>
                                  </tr>
                                  <tr className={heldElsewhere ? 'warn' : 'dim'}>
                                    <td>Booked by other orders</td>
                                    <td className="num">{qty(pos.heldByOthers)}</td>
                                  </tr>
                                  <tr className={freeOnShelf ? 'ok' : 'dim'}>
                                    <td>Free — nobody has booked it</td>
                                    <td className="num">{qty(pos.freeForOthers)}</td>
                                  </tr>
                                  <tr className="dim">
                                    {/* The target, not the stock. Two different
                                        numbers that happen to match on some
                                        items, which made the coincidence look
                                        like the rule. */}
                                    <td>Minimum to hold</td>
                                    <td className="num">{pos.minimum}</td>
                                  </tr>

                                  <tr className="stockpos__head">
                                    <td colSpan={2}>This order</td>
                                  </tr>
                                  <tr>
                                    <td>Ordered</td>
                                    <td className="num">{qty(split.ordered)}</td>
                                  </tr>
                                  <tr className={heldHere ? 'ok' : 'dim'}>
                                    <td>Held for this order</td>
                                    <td className="num">{qty(cover.reserved)}</td>
                                  </tr>
                                  {(cover.availableNow.rolls > 0 || cover.availableNow.belts > 0) && (
                                    /*
                                      Uncovered, but the shelf has it free.
                                      Saving the order takes it; until then it
                                      is nobody's.
                                    */
                                    <tr className="info">
                                      <td>Not yet booked — free to take</td>
                                      <td className="num">{qty(cover.availableNow)}</td>
                                    </tr>
                                  )}
                                  <tr className={cover.needsProduction ? 'warn' : 'dim'}>
                                    <td>Must be made</td>
                                    <td className="num">{qty(cover.toMake)}</td>
                                  </tr>
                                </tbody>
                              </table>
                            )}

                            {/*
                              The sentence, for the case the columns make a
                              manager work out. Only shown when something has
                              to be made even though stock exists — which is
                              exactly the reading that looks like a bug and is
                              not one.
                            */}
                            {pos.pooled && cover.needsProduction && pos.shelf > 0 && (
                              <div className="stockpos__why">
                                {heldElsewhere && !freeOnShelf
                                  ? `All ${qty(pos.heldByOthers)} on the shelf ${
                                      pos.heldByOthers.rolls === 1 ? 'is' : 'are'
                                    } booked by other orders, so nothing here can come off it.`
                                  : `The shelf has ${qty(pos.freeForOthers)} free, which is less than this line needs.`}
                              </div>
                            )}
                            {pos.pooled && pos.inProduction.rolls > 0 && (
                              /* Its own line, never folded in beside a
                                 sellable figure. Two numbers in one sentence,
                                 one sellable and one not, is how a rep
                                 promises stock nobody has made. */
                              <div className="run__note">
                                🏭 {pos.inProduction.rolls} rolls being made — not on the shelf yet
                              </div>
                            )}
                            {pos.drift > 0 && (
                              <div
                                className="danger tiny"
                                title={`ERPNext still counts ${pos.drift} roll(s)${
                                  pos.driftBelts > 0 ? ` and ${pos.driftBelts} belt(s)` : ''
                                } as booked with no reservation behind them — usually a Sales Order deleted directly in ERPNext. The figures above ignore it.`}
                              >
                                ⚠ {pos.drift} phantom booking
                                {pos.drift === 1 ? '' : 's'} ignored
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

          {/* --------------------------------------- Block 5 — order total --- */}
          {preview.hasDiscount ? (
            /*
              Three rows, not one, and the same three the phone shows. The
              whole point of a discount the manager grants is that somebody can
              see what was given away, so the before figure stays on screen
              beside the after — never replaced by it.

              The percentage is `given / before` for the ORDER, not the mean of
              the line percentages: 10% off a small line and nothing off a
              large one is not a 5% order.
            */
            <div className="order__totals">
              <div className="order__total order__total--was">
                <span>Order before discount</span>
                <span>{money(preview.beforeDiscount, 0)}</span>
              </div>
              <div className="order__total order__total--off">
                <span>Discount ({preview.discountPercent}%)</span>
                <span>−{money(preview.discount, 0)}</span>
              </div>
              <div className="order__total">
                <span>Order after discount</span>
                <b>{money(preview.afterDiscount, 0)}</b>
              </div>
              <p className="note right">
                {preview.discountedLines} of {order.lines.length}{' '}
                {order.lines.length === 1 ? 'line' : 'lines'} discounted.
              </p>
            </div>
          ) : (
            <div className="order__total">
              <span>Order total</span>
              <b>{money(preview.changed ? preview.afterDiscount : order.total, 0)}</b>
            </div>
          )}
          {preview.changed && (
            <p className="note right">
              Was {money(order.total, 0)}. Rates save when you approve. Discounts are already
              saved, and are final once the order is approved.
            </p>
          )}

          {/* ------------------------------------- Block 6 — edit line-up --- */}
          {!editing && (
            <div className="line__edit-bar">
              {editClosed ? (
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

          {/* ------------------------------- the discount, one line at a time --- */}
          {discounting && (
            (() => {
              const base = discounting.line.priceListRate;
              const typed = Number(discounting.typed);
              const blank = discounting.typed.trim() === '';
              const refusal = blank ? null : discountRefusal(typed);
              const preview = discountedRate(base, blank ? 0 : typed);
              return (
                <div className="disc__scrim" role="dialog" aria-modal="true" aria-label="Discount">
                  <Card title="Discount" flush={false}>
                    <p className="note">{discounting.line.itemName}</p>
                    <Input
                      autoFocus
                      numeric
                      type="number"
                      min={0}
                      max={MAX_DISCOUNT_PERCENT}
                      step="0.5"
                      aria-label="Discount percent"
                      placeholder="Discount %"
                      value={discounting.typed}
                      onChange={(e) =>
                        setDiscounting((cur) => (cur ? { ...cur, typed: e.target.value } : cur))
                      }
                      onKeyDown={(e) => e.key === 'Escape' && setDiscounting(null)}
                    />
                    {/* The rate the customer would pay, updating as they type.
                        A percentage means nothing to a customer; the rate does. */}
                    <p className="note">
                      {money(base, 2)} → <b>{money(preview, 2)}</b> per unit
                    </p>
                    {refusal && <Alert tone="warn">{refusal}</Alert>}
                    <div className="line__edit-bar">
                      <Button variant="ghost" onClick={() => setDiscounting(null)}>
                        Cancel
                      </Button>
                      <Button
                        onClick={applyDiscount}
                        disabled={!!refusal || busy === 'discount'}
                        loading={busy === 'discount'}
                      >
                        {blank || typed === 0 ? 'Remove discount' : 'Apply'}
                      </Button>
                    </div>
                  </Card>
                </div>
              );
            })()
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
