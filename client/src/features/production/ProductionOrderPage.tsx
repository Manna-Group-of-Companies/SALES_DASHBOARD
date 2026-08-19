/**
 * B2 — Production order detail.
 *
 * The customer was absent by construction until 19 Aug 2026 — the API resolved
 * them to a route and dropped the identity. Dispatch changed that: somebody
 * loading a van has to know whose pallet is whose, and a route does not say it
 * when two customers sit on one round. `getOrderForProduction` now resolves
 * and keeps the name.
 *
 * The two writes here are the ones most likely to go wrong, and both are
 * shaped by ERPNext's field types rather than by preference:
 *
 *   - **Setting a stage writes two fields of different types.** The line's
 *     `custom_production_stage` is free text and takes the fine stage name;
 *     the order's `custom_production_status` is a Select of four values and
 *     rejects anything else — taking the whole update down with it.
 *   - **Moving the delivery date captures the original once, and never again.**
 *     Without that capture the new date is just a number and nobody can see
 *     that it moved, or from what.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { OrderLine, ProductionOrderRow } from '@/domain/types';
import {
  DISPATCHED,
  tracksFor,
  rollUp,
  workComplete,
  workPosition,
  workProgress,
  workTotal,
  type StagedLine,
} from '@/domain/production';
import { modeLabel, modeTone, servedFrom, splitOf } from '@/domain/minimumStock';
import type { StockReservationRow } from '@/domain/types';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { Alert, Badge, Button, Card, Empty, Input, Select } from '@/components/ui';
import { money } from '@/components/common/format';
import { CompletionTick } from '@/components/common/StatusPill';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import './production.css';

type Order = ProductionOrderRow & { lines: OrderLine[] };

export function ProductionOrderPage() {
  const { orderId = '' } = useParams();

  const [order, setOrder] = useState<Order | null>(null);
  const [reservations, setReservations] = useState<StockReservationRow[]>([]);
  /* False when the reservation lookup failed: show ONE track, not two invented ones. */
  const [splitKnown, setSplitKnown] = useState(true);
  const [moving, setMoving] = useState(false);
  const [newDate, setNewDate] = useState('');
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
    Api.production
      .getOrder(orderId)
      .then(async (o) => {
        if (!live) return;
        setOrder(o);
        setNewDate(o.deliveryDate ?? '');
        /*
         * The split is not on the order line — a reservation is a separate
         * record — so it is derived. If this lookup fails, show no split at
         * all rather than losing the order.
         */
        try {
          const res = await Api.sales.listReservations();
          if (!live) return;
          setReservations(res);
          setSplitKnown(true);
        } catch {
          if (live) setSplitKnown(false);
        }
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

  /** What the order status will become once a stage is set — shown live. */
  const impliedStatus = useMemo(() => (order ? rollUp(order.lines) : null), [order]);

  const setStage = async (
    line: OrderLine,
    stage: string,
    field: 'stockStage' | 'productionStage',
  ) => {
    if (!order) return;
    setBusy(line.id + field);
    setError(null);
    try {
      const saved = await Api.production.setStage({
        orderId: order.id,
        lineId: line.id,
        stage,
        field,
      });
      setOrder(saved);
      setDone(`${line.itemName} → ${stage}. Order is now ${saved.productionStatus}.`);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the stage.');
    } finally {
      setBusy(null);
    }
  };

  const moveDate = async () => {
    if (!order || !newDate) return;
    setBusy('date');
    setError(null);
    try {
      const saved = await Api.production.moveDeliveryDate({ orderId: order.id, date: newDate });
      setOrder(saved);
      setMoving(false);
      setDone('Delivery date moved. The rep sees the new date on their order.');
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not move the date.');
    } finally {
      setBusy(null);
    }
  };

  const acknowledge = async () => {
    if (!order) return;
    setBusy('ack');
    try {
      await Api.production.acknowledgeChange(order.id);
      setOrder({ ...order, changedAfterApproval: false });
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not acknowledge.');
    } finally {
      setBusy(null);
    }
  };

  const moved =
    order?.originalDeliveryDate &&
    order.deliveryDate &&
    order.originalDeliveryDate !== order.deliveryDate;
  const postponed = moved && order!.deliveryDate! > order!.originalDeliveryDate!;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">{order ? order.customerName : 'Loading…'}</div>
          <div className="page-head__sub">
            {order ? `${order.route} · destination route` : 'Destination route'}
          </div>
        </div>
        <div className="cal__nav">
          <RefreshButton onClick={reload} loading={loading} />
          <Link to="/production" className="btn btn--ghost btn--sm">
            ← Queue
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
              <Alert tone="danger" title="This order was edited after it was approved">
                <p style={{ margin: '0 0 10px' }}>
                  The floor may be building the wrong quantities. Check the lines below against
                  what is already in progress.
                </p>
                <Button size="sm" onClick={acknowledge} loading={busy === 'ack'}>
                  Acknowledged
                </Button>
              </Alert>
            </div>
          )}

          <Card title="Order">
            <table className="table loc__facts">
              <tbody>
                <tr>
                  <td className="dim">Order</td>
                  <td className="mono">{order.id}</td>
                </tr>
                <tr>
                  <td className="dim">Raised</td>
                  <td>{formatDate(order.placedOn)}</td>
                </tr>
                <tr>
                  <td className="dim">Order value</td>
                  <td className="num">{money(order.total, 0)}</td>
                </tr>
                <tr>
                  <td className="dim">Unit</td>
                  <td>{order.unit || '—'}</td>
                </tr>
                <tr>
                  <td className="dim">Status</td>
                  <td>
                    <CompletionTick productionStatus={order.productionStatus} />
                  </td>
                </tr>
              </tbody>
            </table>

            <div className="prod__delivery">
              Delivery: {order.deliveryDate ? formatDate(order.deliveryDate) : 'not set'}
            </div>

            {moved && (
              <Alert tone="warn" title={postponed ? 'Postponed' : 'Brought forward'}>
                Customer asked for {formatDate(order.originalDeliveryDate!)}, now{' '}
                {formatDate(order.deliveryDate!)}.
              </Alert>
            )}

            {!moving ? (
              <div className="prod__actions">
                {/*
                  A solid button, not a ghost. This was styled as faint
                  borderless text and read as a caption — the one action on
                  this card that changes what the rep is promised, and nobody
                  could tell it was clickable.
                */}
                <Button onClick={() => setMoving(true)}>📅 Move delivery date</Button>
                <span className="note">
                  Postpone or bring forward to a date the floor can actually meet. The rep sees the
                  new date on their order.
                </span>
              </div>
            ) : (
              <div className="prod__actions">
                <Input
                  type="date"
                  value={newDate}
                  onChange={(e) => setNewDate(e.target.value)}
                  aria-label="New delivery date"
                />
                <Button variant="primary" onClick={moveDate} loading={busy === 'date'} disabled={!newDate}>
                  Save date
                </Button>
                <Button variant="ghost" onClick={() => setMoving(false)}>
                  Cancel
                </Button>
                {!order.originalDeliveryDate && (
                  <span className="note">
                    The current date ({order.deliveryDate ? formatDate(order.deliveryDate) : '—'})
                    is recorded as what the customer asked for. That is captured once and never
                    overwritten.
                  </span>
                )}
              </div>
            )}
          </Card>

          <div className="prod__lines">
            {order.lines.map((l) => {
              const split = splitOf(l, reservations, order.id);
              const staged: StagedLine = {
                category: l.category,
                fulfilmentMode: l.fulfilmentMode,
                productionStage: l.productionStage,
                stockStage: l.stockStage,
                reservedRolls: split.reserved.rolls,
                reservedBelts: split.reserved.belts,
                toMakeRolls: split.toMake.rolls,
                toMakeBelts: split.toMake.belts,
                splitKnown,
              };
              const tracks = tracksFor(staged);
              const mode = servedFrom(l, reservations, order.id, splitKnown);
              return (
                <Card key={l.id} title={l.itemName}>
                  <div className="prod__linetop">
                    <span className="dim small">{l.packingNote || '—'}</span>
                    <Badge tone={modeTone(mode) === 'make' ? 'neutral' : 'accent'}>
                      {modeLabel(mode).toUpperCase()}
                    </Badge>
                  </div>

                  <div className="prod__facts">
                    <span className="num">
                      {l.rolls ? `${l.rolls} roll${l.rolls === 1 ? '' : 's'}` : `${l.qty}`}
                      {l.looseBelts ? ` + ${l.looseBelts} belts` : ''} · {l.totalWeight} kg
                    </span>
                    <span className="num dim">{money(l.ratePerKg, 2)} / kg</span>
                  </div>

                  {/*
                    The floor's own summary. Without it this line read "8 rolls"
                    while four already sat in the plant, and a run raised off
                    that number would have been for double.
                  */}
                  {splitKnown && split.isSplit && (
                    <div className="prod__split">
                      ⑂ To make: {split.toMake.rolls} · {split.ordered.rolls} ordered,{' '}
                      {split.reserved.rolls} already in stock
                    </div>
                  )}

                  {/*
                    One track per half. A split line is two pieces of work that
                    finish separately: the shelf half is picked and packed, the
                    made half runs the family cycle. Showing the shelf half
                    against Curing described work nobody was doing.
                  */}
                  {tracks.map((t) => {
                    /*
                      Counted against the stages the FLOOR works, not the
                      stored sequence: Dispatch Planning owns `Dispatched`
                      now, so measuring against it left a packed line — which
                      is finished, as far as this screen's reader is
                      concerned — showing "Stage 2 of 3" behind a half-empty
                      bar. See `workPosition` in domain/production.ts.
                    */
                    const pos = workPosition(t.sequence, t.stage);
                    const unknown = pos < 0;
                    const total = workTotal(t.sequence);
                    const done = workComplete(t.sequence, t.stage);
                    const pct = Math.round(workProgress(t.sequence, t.stage) * 100);
                    const key = l.id + t.field;
                    return (
                      <div key={t.key} className={`track track--${t.key}`}>
                        <div className="track__title">{t.title}</div>
                        {unknown ? (
                          <p className="prod__badstage">
                            Stage &ldquo;{t.stage}&rdquo; is not in this product&rsquo;s cycle
                          </p>
                        ) : (
                          <>
                            <div className="prod__stagecap">
                              Stage {pos} of {total} · {t.stage}
                            </div>
                            <div className="prod__bar">
                              <div
                                className={`prod__bar-fill ${done ? 'done' : ''}`}
                                style={{ width: `${pct}%` }}
                              />
                            </div>
                          </>
                        )}
                        <div className="prod__actions">
                          {/*
                            Dispatched is never hand-picked here — Dispatch
                            Planning is the only thing that writes it now, and
                            only once a line's full ordered quantity has
                            actually gone out. Once a track reaches it, the
                            picker is retired: moving it "back" from Dispatched
                            would corrupt the cumulative-quantity invariant
                            Dispatch Planning depends on.
                          */}
                          <Select
                            value={unknown ? '' : t.stage}
                            disabled={busy === key || t.stage === DISPATCHED}
                            onChange={(e) => e.target.value && setStage(l, e.target.value, t.field)}
                            aria-label={`${t.title} stage for ${l.itemName}`}
                          >
                            {unknown && <option value="">Set a stage from this cycle…</option>}
                            {t.sequence
                              .filter((s) => s !== DISPATCHED)
                              .map((s) => (
                                <option key={s} value={s}>
                                  {s}
                                </option>
                              ))}
                          </Select>
                        </div>
                      </div>
                    );
                  })}
                </Card>
              );
            })}
          </div>

          {impliedStatus && (
            <p className="note" style={{ marginTop: 12 }}>
              The order reads <b>{impliedStatus}</b>, rolled up from its lines: Ready and
              Dispatched are decided by the slowest line, In Production by the fastest, and a stage
              that is not in a line's cycle counts as not started — errors always round down, so an
              unrecognised stage can never make an order look shippable.
            </p>
          )}
        </>
      )}

      {!loading && !order && !error && <Empty icon="—" title="Order not found" />}
    </div>
  );
}
