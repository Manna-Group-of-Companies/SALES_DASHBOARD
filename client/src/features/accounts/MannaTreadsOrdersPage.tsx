/**
 * Orders at Hi-Tech — the accountant's screen (rebuilt 8 October 2026).
 *
 * Every approved order goes to Hi-Tech Pretreads' SAP on the inter-company
 * customer, Manna Treads, so the production floor never learns who the goods
 * are for. This screen is where the real customer is known: each order Hi-Tech
 * has, with the customer it was placed for and Hi-Tech's sales order number.
 *
 * Once Hi-Tech issues a delivery against the sales order, the card shows the
 * delivery's contents and only those — what left, not what was ordered. Until
 * then it shows the sales order as approved. Which is which is
 * `domain/accountantView.ts`.
 *
 * Read-only. Raising the order in Manna Treads' SAP from here was switched off
 * on 8 October 2026 ("for now, we cannot send the sales orders to Manna Treads
 * from the accountant view"); the request path is kept in `api/mannaTreads.ts`
 * and the sync for when it comes back.
 *
 * The route and file keep their older name so bookmarks and the accountant's
 * landing redirect did not have to change.
 */

import { useEffect, useMemo, useState } from 'react';
import {
  ACCT_STATE_LABEL,
  ACCT_STATE_TONE,
  ACCT_TAB_LABEL,
  ACCT_TABS,
  accountantView,
  matchesSearch,
  tabOf,
  type AcctTab,
  type AcctView,
} from '@/domain/accountantView';
import { formatDate } from '@/domain/orderRules';
import { listHitechOrders, type HitechOrderList, type HitechOrderRow } from '@/api/mannaTreads';
import { Alert, Badge, Empty, Input, Segmented, Select } from '@/components/ui';
import { money, moneyShort } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { SapSyncButton, ORDER_SYNC } from '@/components/common/SapSyncButton';
import { ExportButton, type SheetRow } from '@/features/reports/ExportButton';
import '@/components/layout/layout.css';
import './accounts.css';

interface Shown {
  row: HitechOrderRow;
  v: AcctView;
  tab: Exclude<AcctTab, 'all'>;
}

const PERIODS = [
  { days: 30, label: 'Last 30 days' },
  { days: 90, label: 'Last 3 months' },
  { days: 180, label: 'Last 6 months' },
  { days: 365, label: 'Last 12 months' },
] as const;

/** Kilos to three places at most, as SAP holds them. */
function kg(n: number): string {
  return n.toLocaleString('en-IN', { maximumFractionDigits: 3 });
}

export function MannaTreadsOrdersPage() {
  const [list, setList] = useState<HitechOrderList | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [days, setDays] = useState<number>(90);
  const [tab, setTab] = useState<AcctTab>('all');
  const [unit, setUnit] = useState('');
  const [query, setQuery] = useState('');

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    listHitechOrders(days)
      .then((l) => live && setList(l))
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read the orders.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick, days]);

  const reload = () => setTick((t) => t + 1);

  const all = useMemo<Shown[]>(
    () =>
      (list?.orders ?? []).map((row) => {
        const v = accountantView(row.input);
        return { row, v, tab: tabOf(v.state) };
      }),
    [list],
  );

  const units = useMemo(() => [...new Set(all.map((x) => x.row.unit).filter(Boolean))].sort(), [all]);

  // Unit and search narrow everything below, the tiles included; the tab only the list.
  const narrowed = useMemo(
    () =>
      all.filter(
        (x) =>
          (!unit || x.row.unit === unit) &&
          matchesSearch(query, {
            customerName: x.row.customerName,
            customer: x.row.customer,
            name: x.row.name,
            sapSalesOrder: x.row.sapSalesOrder,
            deliveries: x.v.deliveries,
          }),
      ),
    [all, unit, query],
  );

  const sum = (xs: Shown[]) => xs.reduce((s, x) => s + x.v.total, 0);
  const of = (t: Exclude<AcctTab, 'all'>) => narrowed.filter((x) => x.tab === t);
  const delivered = of('delivered');
  const notDelivered = of('not_delivered');
  const cancelled = of('cancelled');
  const count: Record<AcctTab, number> = {
    all: narrowed.length,
    delivered: delivered.length,
    not_delivered: notDelivered.length,
    cancelled: cancelled.length,
  };

  const shown = tab === 'all' ? narrowed : narrowed.filter((x) => x.tab === tab);

  const exportRows = (): SheetRow[] =>
    shown.flatMap(({ row, v }) =>
      v.lines.map((l) => ({
        Customer: row.customerName,
        'Manna Treads code': row.mtCode,
        'Hi-Tech SO': row.sapSalesOrder,
        'App order': row.name,
        'Order date': row.transactionDate,
        Rep: row.rep,
        Unit: row.unit,
        Status: ACCT_STATE_LABEL[v.state],
        Showing: v.shows === 'delivery' ? 'Delivery' : 'Sales order',
        Deliveries: v.deliveries.join(', '),
        'Item code': l.item,
        Item: l.itemName,
        Rolls: l.rolls ?? undefined,
        Kg: l.kg,
        'Rate incl. GST': l.rate,
        Amount: l.amount,
      })),
    );

  const period = PERIODS.find((p) => p.days === days)?.label ?? `${days} days`;

  return (
    <div className="acct">
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Orders at Hi-Tech</div>
        </div>
        <div className="acct__actions">
          <ExportButton
            filename={`orders-at-hitech-${new Date().toISOString().slice(0, 10)}.xlsx`}
            sheet="Orders at Hi-Tech"
            rows={exportRows}
            disabled={shown.length === 0}
          />
          <SapSyncButton target={ORDER_SYNC} onSynced={reload} />
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read the orders">
          {error}
        </Alert>
      )}

      {list && list.unreadable.length > 0 && (
        <Alert tone="warn" title="Some orders could not be read, and are not shown">
          {list.unreadable.map((u) => (
            <div key={u.name} className="small">
              <span className="mono">{u.name}</span> — {u.message}
            </div>
          ))}
        </Alert>
      )}

      <div className="tiles acct__tiles">
        <Tile
          label="Delivered"
          value={String(delivered.length)}
          foot={`${moneyShort(sum(delivered))} delivered`}
          tone={delivered.length ? 'ok' : undefined}
          onClick={() => setTab('delivered')}
        />
        <Tile
          label="Not delivered yet"
          value={String(notDelivered.length)}
          foot={`${moneyShort(sum(notDelivered))} on order`}
          onClick={() => setTab('not_delivered')}
        />
        <Tile
          label="Cancelled at Hi-Tech"
          value={String(cancelled.length)}
          foot={period}
          onClick={() => setTab('cancelled')}
        />
      </div>

      <div className="acct__toolbar">
        <Segmented<AcctTab>
          ariaLabel="Which orders"
          value={tab}
          onChange={setTab}
          options={ACCT_TABS.map((t) => ({ value: t, label: `${ACCT_TAB_LABEL[t]} (${count[t]})` }))}
        />
        <div className="acct__filters">
          <Select compact value={String(days)} onChange={(e) => setDays(Number(e.target.value))} aria-label="Period">
            {PERIODS.map((p) => (
              <option key={p.days} value={p.days}>
                {p.label}
              </option>
            ))}
          </Select>
          {units.length > 1 && (
            <Select compact value={unit} onChange={(e) => setUnit(e.target.value)} aria-label="Unit">
              <option value="">Every unit</option>
              {units.map((u) => (
                <option key={u} value={u}>
                  {u}
                </option>
              ))}
            </Select>
          )}
          <Input
            compact
            placeholder="Customer, order, SAP no. or DN"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            aria-label="Search"
          />
        </div>
      </div>

      {loading && !list && <Empty icon="◔" title="Loading…" />}
      {loading && list && (
        <div className="acct__busy small muted" role="status">
          <span className="spinner" aria-hidden /> Reloading…
        </div>
      )}

      {!loading && !error && shown.length === 0 && (
        <Empty icon="—" title={all.length ? 'No orders match' : 'No orders at Hi-Tech'}>
          {all.length ? undefined : `Nothing has reached Hi-Tech's SAP in the ${period.toLowerCase()}.`}
        </Empty>
      )}

      <div className="acct__list">
        {shown.map(({ row, v }) => (
          <OrderCard key={row.name} row={row} v={v} />
        ))}
      </div>
    </div>
  );
}

function OrderCard({ row, v }: { row: HitechOrderRow; v: AcctView }) {
  // A cancelled order has nothing to bill; its lines are a click away.
  const [open, setOpen] = useState(v.state !== 'cancelled');
  const delivery = v.shows === 'delivery';
  return (
    <article className={`acct-card acct-card--${v.state}`}>
      <header className="acct-card__head">
        <div className="acct-card__who">
          <div className="acct-card__customer">{row.customerName}</div>
          <div className="acct-card__meta">
            {row.mtCode && (
              <span>
                Manna Treads code <span className="mono">{row.mtCode}</span>
              </span>
            )}
            {row.rep && <span>{row.rep}</span>}
            {row.unit && row.unit !== 'Manna Treads' && <span>{row.unit}</span>}
          </div>
        </div>
        <div className="acct-card__amount">
          <Badge tone={ACCT_STATE_TONE[v.state]} dot>
            {ACCT_STATE_LABEL[v.state]}
          </Badge>
          <div className="acct-card__total num">{money(v.total, 2)}</div>
          <div className="acct-card__kg">{kg(v.totalKg)} kg</div>
        </div>
      </header>

      <dl className="acct-card__refs">
        <div>
          <dt>Hi-Tech SO</dt>
          <dd className="mono strong">{row.sapSalesOrder}</dd>
        </div>
        <div>
          <dt>App order</dt>
          <dd className="mono">{row.name}</dd>
        </div>
        <div>
          <dt>Ordered</dt>
          <dd>{formatDate(row.transactionDate)}</dd>
        </div>
        {row.sapInvoice && (
          <div>
            <dt>Hi-Tech invoice</dt>
            <dd className="mono">{row.sapInvoice}</dd>
          </div>
        )}
      </dl>

      <div className={`acct-doc ${delivery ? 'acct-doc--delivery' : ''}`}>
        <button type="button" className="acct-doc__label" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
          <span className="acct-doc__caret" aria-hidden>
            {open ? '▾' : '▸'}
          </span>
          {delivery ? (
            <>
              <b>Delivery</b>
              <span>{v.deliveries.length ? v.deliveries.join(', ') : 'issued by Hi-Tech'}</span>
              {v.state === 'part_delivered' && <span className="muted">· Hi-Tech's order is still open</span>}
            </>
          ) : (
            <>
              <b>Sales order</b>
              <span className="muted">as approved — no delivery yet</span>
            </>
          )}
        </button>

        {open && v.lines.length > 0 && (
          <div className="table-wrap">
            <table className="table acct-lines">
              <thead>
                <tr>
                  <th>Item code</th>
                  <th>Item</th>
                  {!delivery && <th className="right">Rolls</th>}
                  <th className="right">{delivery ? 'Delivered kg' : 'Kg'}</th>
                  <th className="right">Rate incl. GST</th>
                  <th className="right">Amount</th>
                </tr>
              </thead>
              <tbody>
                {v.lines.map((l, i) => (
                  <tr key={`${l.item}-${i}`}>
                    <td className="mono">{l.item}</td>
                    <td>{l.itemName}</td>
                    {!delivery && <td className="right num">{l.rolls ? kg(l.rolls) : '—'}</td>}
                    <td className="right num">{kg(l.kg)}</td>
                    <td className="right num">{money(l.rate, 2)}</td>
                    <td className="right num">{money(l.amount, 2)}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr>
                  <td colSpan={delivery ? 2 : 3} className="strong">
                    Total, including GST
                  </td>
                  <td className="right num strong">{kg(v.totalKg)}</td>
                  <td />
                  <td className="right num strong">{money(v.total, 2)}</td>
                </tr>
              </tfoot>
            </table>
          </div>
        )}
        {open && v.lines.length === 0 && <div className="small muted acct-doc__empty">No lines on this order.</div>}
      </div>
    </article>
  );
}
