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
  SalesCustomer,
  StockReservationRow,
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
  DISCOUNT_LOCKED,
  discountEditable,
  discountLine,
  normaliseDiscount,
  orderDiscount,
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
  const [discountEdits, setDiscountEdits] = useState<Record<string, number>>({});
  const [drafts, setDrafts] = useState<Draft[] | null>(null);
  const [picking, setPicking] = useState(false);
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    setRateEdits({});
    setDiscountEdits({});
    setDrafts(null);
    Api.sales
      .getOrder(orderId)
      .then(async (o) => {
        if (!live) return;
        setOrder(o);
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

  const stock = useMemo(() => poolByItem(pool), [pool]);
  // The server's clock, not the browser's: this decides whether a change is
  // allowed, and a user controls their own clock.
  const now = useMemo(() => serverNow(), [tick, order]);
  const approved = order ? isApproved(order.poStatus) : false;
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
  const preview = useMemo(() => {
    if (!order) return { before: 0, after: 0, saved: 0, percent: 0, lines: 0, changed: false };
    let changed = false;
    const rows = order.lines.map((l) => {
      const edited = rateEdits[l.id];
      const rateMoved = edited != null && edited > 0 && edited !== l.ratePerKg;
      if (rateMoved) changed = true;
      const gross = rateMoved
        ? l.totalWeight * edited
        : l.qty * l.priceListRate || l.amount || l.qty * l.rate;
      const pct = discountEdits[l.id] ?? l.discountPercent;
      if (discountEdits[l.id] != null && discountEdits[l.id] !== l.discountPercent) changed = true;
      const cut = discountLine({ perUnit: l.qty > 0 ? gross / l.qty : 0, qty: l.qty, percent: pct });
      return { before: cut.before, after: cut.after, percent: cut.percent };
    });
    return { ...orderDiscount(rows), changed };
  }, [order, rateEdits, discountEdits]);

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
        discountEdits: decision === 'approve' ? discountEdits : undefined,
        role: user?.role,
      });
      setOrder(saved);
      setRateEdits({});
      setDiscountEdits({});
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
            </Alert>
          </div>

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
                      <th>Minimum stock</th>
                      <th>Served from</th>
                    </tr>
                  </thead>
                  <tbody>
                    {order.lines.map((l) => {
                      const edited = rateEdits[l.id];
                      const effective = edited != null && edited > 0 ? edited : l.ratePerKg;
                      /*
                       * The line total BEFORE any discount, which is what the
                       * rate rules produce. A stored zero must never be shown
                       * as a nil line against rates the rep entered correctly,
                       * hence the fallbacks — and `priceListRate` is used
                       * rather than `rate`, which is the discounted figure.
                       */
                      const gross =
                        edited != null && edited !== l.ratePerKg
                          ? l.totalWeight * effective
                          : l.qty * l.priceListRate || l.amount || l.qty * l.rate;
                      const pct = discountEdits[l.id] ?? l.discountPercent;
                      const cut = discountLine({
                        perUnit: l.qty > 0 ? gross / l.qty : 0,
                        qty: l.qty,
                        percent: pct,
                      });
                      const amount = cut.after;
                      const priceOpen = discountEditable(role, l.rateApproved);
                      const pos = positionFor(l.itemCode, stock, reservations, order.id);
                      const split = splitOf(l, reservations, order.id);
                      // Measured against the UNBOOKED shelf, so it never offers
                      // a roll another order is already holding.
                      const cover = coverFor(split, pos.freeForOthers);
                      const mode = servedFrom(l, reservations, order.id);
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

                              Locked by the same gate as the rate, because a
                              discount IS a price. Once the order is approved
                              the figure is shown, never entered.
                            */}
                            {priceOpen && !(approved && boundByCutoff(role)) ? (
                              <Input
                                numeric
                                compact
                                type="number"
                                min={0}
                                max={100}
                                step="0.5"
                                aria-label={`Discount percent for ${l.itemName}`}
                                value={pct || ''}
                                placeholder="0"
                                onChange={(e) =>
                                  setDiscountEdits((cur) => ({
                                    ...cur,
                                    [l.id]: normaliseDiscount(Number(e.target.value)),
                                  }))
                                }
                              />
                            ) : (
                              <span className="num" title={l.rateApproved ? DISCOUNT_LOCKED : undefined}>
                                {pct > 0 ? `${pct}%` : '—'}
                                {l.rateApproved && pct > 0 ? ' 🔒' : ''}
                              </span>
                            )}
                          </td>
                          <td className="right num">
                            {cut.saved > 0 ? (
                              /* Both figures, always. "After discount" on its
                                 own is just a price — the point of the feature
                                 is that the two can be compared. */
                              <>
                                <div className="line__was">{money(cut.before, 0)}</div>
                                <b className="exp__corrected">{money(amount, 0)}</b>
                                <div className="tiny ok-text">−{money(cut.saved, 0)}</div>
                              </>
                            ) : edited != null && edited !== l.ratePerKg ? (
                              <b className="exp__corrected">{money(amount, 0)}</b>
                            ) : (
                              money(amount, 0)
                            )}
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
                                  <tr>
                                    {/* The shelf, not the target. These are two
                                        different numbers that happen to match on
                                        some items, and calling the shelf
                                        "minimum stock held" made the coincidence
                                        look like the rule. */}
                                    <td>On the shelf</td>
                                    <td className="num">{pos.shelf}</td>
                                  </tr>
                                  <tr className="dim">
                                    <td>Minimum to hold</td>
                                    <td className="num">{pos.minimum}</td>
                                  </tr>
                                  <tr>
                                    <td>Ordered</td>
                                    <td className="num">{qty(split.ordered)}</td>
                                  </tr>
                                  <tr className="ok">
                                    <td>Held for this order</td>
                                    <td className="num">{qty(cover.reserved)}</td>
                                  </tr>
                                  {(cover.availableNow.rolls > 0 || cover.availableNow.belts > 0) && (
                                    /*
                                      Uncovered, but the shelf has it. Raising
                                      the quantity here does not extend the hold
                                      the rep's phone took, so this is the part
                                      nobody has claimed yet — free stock, not a
                                      production job.
                                    */
                                    <tr className="info">
                                      <td>Not yet reserved — free on the shelf</td>
                                      <td className="num">{qty(cover.availableNow)}</td>
                                    </tr>
                                  )}
                                  <tr className={cover.needsProduction ? 'warn' : 'dim'}>
                                    <td>Must be made</td>
                                    <td className="num">{qty(cover.toMake)}</td>
                                  </tr>
                                  <tr className="dim">
                                    <td>Unbooked, anyone can take</td>
                                    <td className="num">{qty(pos.freeForOthers)}</td>
                                  </tr>
                                </tbody>
                              </table>
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
          {preview.saved > 0 ? (
            /*
              Three lines, not one. The whole point of a discount the manager
              grants is that somebody can see what was given away, so the
              before figure stays on screen beside the after — never replaced
              by it.

              The percentage is `saved / before` for the ORDER, not the mean of
              the line percentages: 10% off a small line and nothing off a
              large one is not a 5% order.
            */
            <div className="order__totals">
              <div className="order__total order__total--was">
                <span>Before discount</span>
                <span>{money(preview.before, 0)}</span>
              </div>
              <div className="order__total order__total--off">
                <span>Discount ({preview.percent}% over {preview.lines} line{preview.lines === 1 ? '' : 's'})</span>
                <span>−{money(preview.saved, 0)}</span>
              </div>
              <div className="order__total">
                <span>After discount</span>
                <b>{money(preview.after, 0)}</b>
              </div>
            </div>
          ) : (
            <div className="order__total">
              <span>Order total</span>
              <b>{money(preview.changed ? preview.after : order.total, 0)}</b>
            </div>
          )}
          {preview.changed && (
            <p className="note right">
              Was {money(order.total, 0)}. Rates and discounts save when you approve, and are final
              once they do.
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
