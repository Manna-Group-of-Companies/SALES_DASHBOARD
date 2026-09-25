/**
 * B2 — Production order detail.
 *
 * The customer was absent by construction until 19 Aug 2026 — the API resolved
 * them to a route and dropped the identity. Dispatch changed that: somebody
 * loading a van has to know whose pallet is whose, and a route does not say it
 * when two customers sit on one round. `getOrderForProduction` now resolves
 * and keeps the name.
 *
 * THE STATUS IS SAP'S (25 September 2026)
 *
 * Each line carried a stage picker here — the floor moved a line through its
 * product's cycle and the order rolled up from the lines. Removed on
 * instruction: the status comes from SAP's own sales order → invoice loop, so
 * nothing on this screen sets it. The order reads Pushed to SAP until SAP
 * invoices it, Dispatched once it has, and Cancelled in SAP if SAP cancels it;
 * each line reads Dispatched once the invoice that carried it exists. The
 * rules are `productionQueue.ts` and `sapOrderState.ts` (fixture-pinned).
 *
 * `custom_production_stage` / `custom_production_status` may still hold values
 * written before that day. Nothing here reads them.
 *
 * The one write left is shaped by ERPNext rather than by preference: **moving
 * the delivery date captures the original once, and never again.** Without
 * that capture the new date is just a number and nobody can see that it
 * moved, or from what.
 */

import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { OrderLine, ProductionOrderRow } from '@/domain/types';
import { modeLabel, modeTone, servedFrom } from '@/domain/minimumStock';
import { lineStatusFromSap } from '@/domain/sapOrderState';
import { queueState, QUEUE_STATE_LABEL, type QueueState } from '@/domain/productionQueue';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { Alert, Badge, Button, Card, Empty, Input, type BadgeTone } from '@/components/ui';
import { money } from '@/components/common/format';
import { ORDER_SYNC, SapSyncButton } from '@/components/common/SapSyncButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import './production.css';

type Order = ProductionOrderRow & { lines: OrderLine[] };

const STATE_TONE: Record<QueueState, BadgeTone> = {
  in_sap: 'info',
  dispatched: 'ok',
  cancelled: 'danger',
};

/** One line's reading. A cancelled order's lines are cancelled with it. */
function lineReading(line: OrderLine, order: Order): { text: string; tone: BadgeTone } {
  if (queueState(order.sap) === 'cancelled') return { text: 'Cancelled in SAP', tone: 'danger' };
  const s = lineStatusFromSap({ invoice: line.sapInvoice }, order.sap);
  if (s === 'Dispatched') return { text: 'Dispatched', tone: 'ok' };
  if (s === 'Pushed to SAP') return { text: 'Pushed to SAP', tone: 'info' };
  return { text: 'Not in SAP yet', tone: 'neutral' };
}

export function ProductionOrderPage() {
  const { orderId = '' } = useParams();

  const [order, setOrder] = useState<Order | null>(null);
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
      .then((o) => {
        if (!live) return;
        setOrder(o);
        setNewDate(o.deliveryDate ?? '');
        /*
         * A second read went out here for the live reservations, because the
         * shelf/production split was not on the order line — a reservation was
         * a separate record — and the floor needed it to know how much of an
         * eight-roll line was actually to be made. There are no reservations,
         * so the whole ordered quantity is what the floor is asked for.
         */
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
          <SapSyncButton target={ORDER_SYNC} onSynced={reload} />
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
                  <td className="dim">SAP order</td>
                  <td className="mono">{order.sap.salesOrder || 'Not in SAP yet'}</td>
                </tr>
                <tr>
                  <td className="dim">Status</td>
                  <td>
                    {order.sap.salesOrder ? (
                      <Badge tone={STATE_TONE[queueState(order.sap)]}>
                        {QUEUE_STATE_LABEL[queueState(order.sap)].toUpperCase()}
                      </Badge>
                    ) : (
                      <Badge tone="neutral">NOT IN SAP YET</Badge>
                    )}
                    {order.sap.invoice && (
                      <span className="small" style={{ marginLeft: 8 }}>
                        Invoice <b className="mono">{order.sap.invoice}</b>
                        {order.sap.invoiceDate ? ` · ${formatDate(order.sap.invoiceDate)}` : ''}
                      </span>
                    )}
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
              const mode = servedFrom(l);
              const reading = lineReading(l, order);
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
                    A "to make: 4 of 8 ordered, 4 already in stock" summary sat
                    here, worked out from what a shelf reservation covered.
                    There are no reservations to work it out from, and the
                    quantity above is the whole ask.
                  */}

                  {/*
                    The line's status, from SAP. A stage track with a picker
                    stood here until 25 September 2026 — see the header.
                  */}
                  <div className="prod__actions">
                    <Badge tone={reading.tone}>{reading.text.toUpperCase()}</Badge>
                    {l.sapInvoice && (
                      <span className="small">
                        Invoice <b className="mono">{l.sapInvoice}</b>
                        {l.sapInvoiceDate ? ` · ${formatDate(l.sapInvoiceDate)}` : ''}
                      </span>
                    )}
                  </div>
                </Card>
              );
            })}
          </div>

          <p className="note" style={{ marginTop: 12 }}>
            The status comes from SAP: <b>Pushed to SAP</b> once SAP has the order,{' '}
            <b>Dispatched</b> once SAP has invoiced it. Nothing here changes it — press <b>Sync</b>{' '}
            in the header to fetch the latest from SAP.
          </p>
        </>
      )}

      {!loading && !order && !error && <Empty icon="—" title="Order not found" />}
    </div>
  );
}
