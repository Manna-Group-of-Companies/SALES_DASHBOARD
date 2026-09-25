/**
 * B1 — Production dashboard, the queue.
 *
 * WHAT IS ON IT (24 September 2026)
 *
 * Every order SAP has, and nothing SAP does not. An order arrives here the
 * moment the sync writes its SAP sales-order number back, and an order SAP
 * cancels stays on the list marked Cancelled in SAP rather than vanishing —
 * see `domain/productionQueue.ts`. Until that day the queue listed every order
 * approved in ERPNext whether or not SAP had it, and the floor's screen was
 * mostly sync-test orders.
 *
 * The week is chosen, as on the sales manager's Team Orders, and means the
 * same thing there and here: the Monday-to-Sunday week the order was RAISED
 * in, on the server's clock. Two managers saying "this week's orders" should
 * be looking at the same orders.
 *
 * Dispatch planning is parked, on instruction, so this screen no longer links
 * to it.
 *
 * The customer leads each row and the route sits beneath it. Production was
 * sent the route and never the customer until 19 Aug 2026, when dispatch
 * needed to know whose pallet is whose.
 */

import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import type { ProductionOrderRow } from '@/domain/types';
import { formatDate } from '@/domain/orderRules';
import {
  inProductionQueue,
  queueState,
  QUEUE_STATES,
  QUEUE_STATE_LABEL,
  type QueueState,
} from '@/domain/productionQueue';
import { addDays, isoDate, recentWeeks, type Week } from '@/domain/weeks';
import { serverNow } from '@/domain/serverClock';
import { Api } from '@/api/client';
import { UNITS } from '@/api/endpoints';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Empty, Input, Segmented, Select, type BadgeTone } from '@/components/ui';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { ORDER_SYNC, SapSyncButton } from '@/components/common/SapSyncButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import '@/features/orders/orders.css';

/** Weeks offered, newest first — the same span as Team Orders. */
const WEEKS = 13;

const STATE_TONE: Record<QueueState, BadgeTone> = {
  in_sap: 'info',
  dispatched: 'ok',
  cancelled: 'danger',
};

interface Row {
  r: ProductionOrderRow;
  state: QueueState;
}

export function ProductionQueuePage() {
  const user = useAppSelector(selectUser);
  const navigate = useNavigate();

  const [rows, setRows] = useState<ProductionOrderRow[]>([]);
  /*
   * Scoped to this manager's own unit by default, from
   * `User.custom_production_company` — Ajith is "Manna Treads", Saju is "Manna
   * Tyre Retreads", Renjith is "Manna Tyres UAE". Defaulting to every unit
   * would put three factories' work on one floor's screen.
   */
  const [unit, setUnit] = useState<string>(user?.productionUnit ?? '');
  const [weeks, setWeeks] = useState<Week[]>([]);
  const [weekStart, setWeekStart] = useState('');
  const [state, setState] = useState<'' | QueueState>('');
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    // A coarse bound on the read, from the browser's clock: the week offered
    // for choosing is built on the server's clock below, once a response has
    // set it, so a browser a day out cannot put a manager in the wrong week.
    const since = isoDate(addDays(new Date(), -7 * (WEEKS + 1)));
    Api.production
      .listQueue(unit || undefined, since)
      .then((r) => {
        if (!live) return;
        setRows(r);
        const list = recentWeeks(serverNow(), WEEKS);
        setWeeks(list);
        setWeekStart((current) => (list.some((w) => w.start === current) ? current : list[0].start));
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read the queue.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick, unit]);

  const week = useMemo(
    () => weeks.find((w) => w.start === weekStart) ?? weeks[0],
    [weeks, weekStart],
  );

  /** The week's orders SAP has. Every count and filter works from this. */
  const inWeek = useMemo<Row[]>(() => {
    if (!week) return [];
    return rows
      .filter((r) => inProductionQueue(r.sap))
      .filter((r) => r.placedOn >= week.start && r.placedOn <= week.end)
      .map((r) => ({ r, state: queueState(r.sap) }));
  }, [rows, week]);

  const counts = useMemo(() => {
    const c: Record<QueueState, number> = { in_sap: 0, dispatched: 0, cancelled: 0 };
    for (const x of inWeek) c[x.state] += 1;
    return c;
  }, [inWeek]);

  // A cancelled order is not work, so a change to one is not worth a warning.
  const changed = useMemo(
    () => inWeek.filter((x) => x.state !== 'cancelled' && x.r.changedAfterApproval).length,
    [inWeek],
  );

  const shown = useMemo(() => {
    let list = inWeek;
    if (state) list = list.filter((x) => x.state === state);
    const q = query.trim().toLowerCase();
    if (q) {
      list = list.filter(
        (x) =>
          x.r.id.toLowerCase().includes(q) ||
          x.r.route.toLowerCase().includes(q) ||
          x.r.customerName.toLowerCase().includes(q) ||
          (x.r.sap.salesOrder ?? '').toLowerCase().includes(q),
      );
    }
    return list;
  }, [inWeek, state, query]);

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Production</div>
          <div className="page-head__sub">
            Orders in SAP · {week ? week.label : '…'}
            {unit ? ` · ${unit}` : ' · all units'}
          </div>
        </div>
        <div className="cal__nav">
          <SapSyncButton target={ORDER_SYNC} onSynced={() => setTick((t) => t + 1)} />
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read the queue">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile
          label="Pushed to SAP"
          value={String(counts.in_sap)}
          tone="ok"
          foot="In SAP, not yet invoiced"
        />
        <Tile label="Dispatched" value={String(counts.dispatched)} foot="Invoiced in SAP" />
        <Tile
          label="Cancelled in SAP"
          value={String(counts.cancelled)}
          tone={counts.cancelled ? 'warn' : undefined}
          foot={counts.cancelled ? 'Nothing to make for these' : 'None'}
        />
        <Tile
          label="Changed after approval"
          value={String(changed)}
          tone={changed ? 'warn' : undefined}
          foot={changed ? 'The floor may be building the wrong thing' : 'None'}
        />
      </div>

      <div className="cal__toolbar">
        <Select
          value={weekStart}
          onChange={(e) => setWeekStart(e.target.value)}
          aria-label="Week"
          disabled={!weeks.length}
        >
          {weeks.map((w, i) => (
            <option key={w.start} value={w.start}>
              {i === 0 ? `This week · ${w.label}` : w.label}
            </option>
          ))}
        </Select>
        <Segmented
          ariaLabel="State"
          value={state}
          onChange={setState}
          options={[
            { value: '' as const, label: `All (${inWeek.length})` },
            ...QUEUE_STATES.map((s) => ({
              value: s,
              label: `${QUEUE_STATE_LABEL[s]} (${counts[s]})`,
            })),
          ]}
        />
        <Select value={unit} onChange={(e) => setUnit(e.target.value)} aria-label="Unit">
          <option value="">All units</option>
          {UNITS.map((u) => (
            <option key={u} value={u}>
              {u}
            </option>
          ))}
        </Select>
        <Input
          placeholder="Search order, SAP no., customer or route…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search the queue"
        />
      </div>

      {loading && <Empty icon="◔" title="Reading the queue…" />}

      {!loading && !error && shown.length === 0 && (
        <Empty icon="—" title={inWeek.length ? 'Nothing matches' : 'No orders in SAP this week'}>
          {inWeek.length
            ? 'Try another state, or clear the search.'
            : 'An order appears here as soon as it reaches SAP. Pick another week above.'}
        </Empty>
      )}

      {!loading && shown.length > 0 && (
        <div className="orders__list">
          {shown.map(({ r, state: s }) => (
            <div
              key={r.id}
              className="ordrow"
              role="button"
              tabIndex={0}
              // A cancelled order stays readable but steps back, so the live
              // work is what the eye lands on.
              style={s === 'cancelled' ? { opacity: 0.72 } : undefined}
              onClick={() => navigate(`/production/${r.id}`)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault();
                  navigate(`/production/${r.id}`);
                }
              }}
            >
              <div className="ordrow__top">
                <span className="ordrow__party">
                  <span aria-hidden="true">
                    {s === 'cancelled' ? '✕' : r.changedAfterApproval ? '⚠' : '🧾'}
                  </span>
                  <span style={s === 'cancelled' ? { textDecoration: 'line-through' } : undefined}>
                    {r.customerName}
                  </span>
                  {s !== 'cancelled' && r.changedAfterApproval && (
                    <Badge tone="danger">CHANGED</Badge>
                  )}
                </span>
                <b className="num">{money(r.total, 0)}</b>
              </div>

              <div className="ordrow__meta">
                <span className={r.route === 'No route set' ? 'dim' : ''}>{r.route}</span> ·{' '}
                <span className="mono">{r.id}</span> · raised {formatDate(r.placedOn)}
              </div>
              <div className="ordrow__meta">
                Deliver by {r.deliveryDate ? formatDate(r.deliveryDate) : 'not set'}
                {r.productionFinishDate ? ` · est. finish ${formatDate(r.productionFinishDate)}` : ''}
                {/*
                  How often the rep has changed this order. The floor is
                  building to whatever it says now, and an order rewritten
                  several times is worth checking the spec on rather than
                  trusting from memory. Silent at zero, which is most orders.
                */}
                {r.editCount > 0 &&
                  ` · edited ${r.editCount} ${r.editCount === 1 ? 'time' : 'times'}`}
              </div>

              <div className="ordrow__status">
                <Badge tone={STATE_TONE[s]}>{QUEUE_STATE_LABEL[s].toUpperCase()}</Badge>
                <span className="small">
                  SAP order <b className="mono">{r.sap.salesOrder}</b>
                  {s === 'dispatched' && r.sap.invoice && (
                    <>
                      {' '}
                      · invoice <b className="mono">{r.sap.invoice}</b>
                      {r.sap.invoiceDate ? ` · ${formatDate(r.sap.invoiceDate)}` : ''}
                    </>
                  )}
                </span>
              </div>
            </div>
          ))}
        </div>
      )}

      {!loading && inWeek.length > 0 && (
        <p className="note" style={{ marginTop: 12 }}>
          Only orders SAP has are listed. An order approved in ERPNext appears here once the SAP
          sync has created it in SAP — press <b>Sync</b> in the header if one is missing.
        </p>
      )}
    </div>
  );
}
