/**
 * An order's stage track on the managers' screens: which SAP holds it, the
 * five stages, and who the next step waits on. Every word comes from
 * `domain/orderTrack.ts`, which reads only fields the apps and the SAP sync
 * write — see `shared/fixtures/order_track.json`.
 *
 * Two sizes: `OrderTrackLine` under an order row or card, `OrderTrackPanel`
 * on an order's own page.
 */
import { useEffect, useMemo, useState } from 'react';
import type { TeamOrder } from '@/domain/types';
import {
  orderTrack,
  pickListsByOrder,
  responsibleText,
  STATE_LABEL,
  type OrderTrack,
  type PickFacts,
  type StageKey,
  type StageState,
} from '@/domain/orderTrack';
import { formatDate } from '@/domain/orderRules';
import { getPickListsSince, listPickLists, type PickList } from '@/api/pickLists';
import { frappeToday } from '@/domain/serverClock';
import { Card } from '@/components/ui';
import './orderTrack.css';

/** `manna_pick_lists` returns at most this many, newest first. */
const PICK_LIST_LIMIT = 200;

const SHORT: Record<StageKey, string> = {
  manager: 'Manager',
  gm: 'GM',
  sap: 'SAP',
  pick: 'Pick list',
  processing: 'Processing',
};

const ICON: Record<StageState, string> = {
  done: '✓',
  current: '●',
  waiting: '○',
  na: '–',
  unknown: '?',
};

function toFacts(l: PickList): PickFacts {
  return {
    name: l.name,
    status: l.status,
    approvalStatus: l.approvalStatus,
    pickedOn: l.pickedOn,
    sapPickList: l.sapPickList,
    hitechInvoice: l.hitechInvoice,
    mtGoodsReceipt: l.mtGoodsReceipt,
    mtDelivery: l.mtDelivery,
    sapError: l.sapError,
  };
}

/**
 * `pick_lists_since` for the track, read once. Until it arrives, and if it
 * cannot be read, the track treats every order as eligible - as the phone's
 * pick list page does; `manna_pick_list_submit` still refuses an older one.
 */
let knownSince: string | null = null;
function usePickListsSince(): string | null {
  const [v, setV] = useState<string | null>(knownSince);
  useEffect(() => {
    let live = true;
    getPickListsSince().then((s) => {
      if (s !== null) knownSince = s;
      if (live) setV(s);
    });
    return () => {
      live = false;
    };
  }, []);
  return v;
}

/** The track for one order. `lists` null = its pick lists are not known. */
export function trackOf(o: TeamOrder, lists: PickList[] | null, pickListsSince?: string | null): OrderTrack {
  return orderTrack({
    placedOn: o.placedOn,
    deliveryDate: o.deliveryDate,
    // The server's day, not this browser's (serverClock).
    today: frappeToday(),
    pickListsSince: pickListsSince ?? knownSince,
    poStatus: o.poStatus,
    gmApprovedBy: o.gmApprovedBy,
    gmApprovedOn: o.gmApprovedOn,
    mtSalesOrder: o.mtSalesOrder,
    mtSyncError: o.mtSyncError,
    mtInvoice: o.mtInvoice,
    sapSalesOrder: o.sapSalesOrder,
    sapSalesOrderStatus: o.sapSalesOrderStatus,
    sapOrderStatus: o.sapOrderStatus,
    sapInvoice: o.sapInvoice,
    sapSyncError: o.sapSyncError,
    pickLists: lists ? lists.map(toFacts) : null,
  });
}

/**
 * Every pick list the caller may see, read once for a whole list of orders,
 * then shared out by order. `manna_pick_lists` scopes them to the caller (the
 * GM sees all; a sales manager their team's). A failed read leaves every
 * order's lists `null` — not known — and the page itself carries on.
 *
 * `tick` re-reads, so a page's Refresh refreshes these too.
 */
export function usePickListsByOrder(orderIds: string[], tick = 0): Record<string, PickList[] | null> {
  const [lists, setLists] = useState<PickList[] | null>(null);
  useEffect(() => {
    let live = true;
    listPickLists()
      .then((l) => live && setLists(l))
      .catch(() => live && setLists(null));
    return () => {
      live = false;
    };
  }, [tick]);
  const key = orderIds.join('|');
  // eslint-disable-next-line react-hooks/exhaustive-deps
  return useMemo(() => pickListsByOrder(lists, orderIds, PICK_LIST_LIMIT), [lists, key]);
}

/** One order's own pick lists, read by order (no 200-list ceiling). */
export function useOrderPickLists(orderId: string | undefined, tick = 0): PickList[] | null {
  const [lists, setLists] = useState<PickList[] | null>(null);
  useEffect(() => {
    if (!orderId) return;
    let live = true;
    setLists(null);
    listPickLists(orderId)
      .then((l) => live && setLists(l.filter((x) => x.salesOrder === orderId)))
      .catch(() => live && setLists(null));
    return () => {
      live = false;
    };
  }, [orderId, tick]);
  return lists;
}

function Steps({ track }: { track: OrderTrack }) {
  return (
    <ol className="otrack__steps" aria-label="Order stages">
      {track.stages.map((s) => (
        <li
          key={s.key}
          className={`otrack__step otrack__step--${s.state}`}
          title={`${s.label}: ${STATE_LABEL[s.state]}${s.note ? ` — ${s.note}` : ''}`}
        >
          <span className="otrack__icon" aria-hidden>
            {ICON[s.state]}
          </span>
          {SHORT[s.key]}
          <span className="sr-only">: {STATE_LABEL[s.state]}</span>
        </li>
      ))}
    </ol>
  );
}

/** The order is in SAP but was never approved. Red, because it must not happen. */
function EarlyWarning({ track }: { track: OrderTrack }) {
  if (!track.sentBeforeApproval) return null;
  return (
    <div className="otrack__warn" role="alert">
      ⚠ In SAP before approval ({track.sapLine}). The order sync sent it early. If it is rejected, cancel it in
      SAP by hand — rejecting here does not touch SAP.
    </div>
  );
}

function NextStep({ track, rep }: { track: OrderTrack; rep?: string }) {
  const who = responsibleText(track.action.who, rep);
  return (
    <div className={`otrack__next otrack__next--${track.outcome}`}>
      <span className="otrack__k">Next:</span> {track.action.text}
      {who && (
        <>
          {' '}
          · <b>{who}</b>
        </>
      )}
    </div>
  );
}

/** Under an order row or card: which SAP, the five stages, the next step. */
export function OrderTrackLine({ order, lists }: { order: TeamOrder; lists: PickList[] | null }) {
  const track = trackOf(order, lists, usePickListsSince());
  return (
    <div className="otrack" onClick={(e) => e.stopPropagation()} role="presentation">
      <div className="otrack__sap">
        <span className="otrack__k">SAP:</span>{' '}
        <span className={track.sap.mannaTreads || track.sap.hitech ? 'otrack__in' : 'dim'}>{track.sapLine}</span>
        <span className="dim"> · Pick list: {track.pickList}</span>
      </div>
      <Steps track={track} />
      <EarlyWarning track={track} />
      <NextStep track={track} rep={order.rep} />
    </div>
  );
}

/** On an order's own page: every stage with what its field says. */
export function OrderTrackPanel({ order, lists }: { order: TeamOrder; lists: PickList[] | null }) {
  const track = trackOf(order, lists, usePickListsSince());
  const who = responsibleText(track.action.who, order.rep);
  return (
    <div style={{ marginBottom: 14 }}>
      <Card title="Order status">
        <dl className="otrack__facts">
          <div>
            <dt>Order date</dt>
            <dd>{order.placedOn ? formatDate(order.placedOn) : 'Not known'}</dd>
          </div>
          <div>
            <dt>SAP sales order</dt>
            <dd className={track.sap.mannaTreads || track.sap.hitech ? 'otrack__in' : ''}>{track.sapLine}</dd>
          </div>
          <div>
            <dt>Pick list</dt>
            <dd>{track.pickList}</dd>
          </div>
          <div>
            <dt>Pending action</dt>
            <dd>
              {track.action.text}
              {who && (
                <>
                  {' '}
                  · <b>{who}</b>
                </>
              )}
            </dd>
          </div>
        </dl>
        <EarlyWarning track={track} />
        <ol className="otrack__rows" aria-label="Order stages">
          {track.stages.map((s) => (
            <li key={s.key} className={`otrack__row otrack__row--${s.state}`}>
              <span className="otrack__icon" aria-hidden>
                {ICON[s.state]}
              </span>
              <span className="otrack__label">{s.label}</span>
              <span className={`otrack__state otrack__state--${s.state}`}>{STATE_LABEL[s.state]}</span>
              <span className="otrack__note">{s.note}</span>
            </li>
          ))}
        </ol>
      </Card>
    </div>
  );
}
