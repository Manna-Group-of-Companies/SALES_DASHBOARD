/**
 * B1 — Production dashboard, the queue.
 *
 * **Production must never see the customer.** The API resolves customer →
 * route and deletes the customer before the payload reaches this screen, so
 * there is no identity on the object to render and none for the search box to
 * match. Hiding it in CSS would leave it in the DOM; leaving it on the object
 * would let a search confirm a customer by guessing. It simply is not here.
 *
 * The search therefore matches **order number and route only** — and can only
 * match those, because nothing else was sent.
 */

import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import type { ProductionOrderRow } from '@/domain/types';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { UNITS } from '@/api/endpoints';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Empty, Input, Select } from '@/components/ui';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { CompletionTick } from '@/components/common/StatusPill';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import '@/features/orders/orders.css';

export function ProductionQueuePage() {
  const user = useAppSelector(selectUser);
  const navigate = useNavigate();

  const [rows, setRows] = useState<ProductionOrderRow[]>([]);
  /*
   * Scoped to this manager's own unit by default, from
   * `User.custom_production_company` — Ajith is "Manna Treads", Saju is "Manna
   * Tyre Retreads", Renjith is "Manna Tyres UAE". B1 filters the queue on
   * `custom_company`, and defaulting to every unit would put three factories'
   * work on one floor's screen.
   */
  const [unit, setUnit] = useState<string>(user?.productionUnit ?? '');
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.production
      .listQueue(unit || undefined)
      .then((r) => {
        if (live) setRows(r);
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

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return rows;
    // Order number and route only. There is nothing else on the object.
    return rows.filter(
      (r) => r.id.toLowerCase().includes(q) || r.route.toLowerCase().includes(q),
    );
  }, [rows, query]);

  const stats = useMemo(
    () => ({
      changed: rows.filter((r) => r.changedAfterApproval).length,
      dispatched: rows.filter((r) => r.productionStatus === 'Dispatched').length,
      noRoute: rows.filter((r) => r.route === 'No route set').length,
    }),
    [rows],
  );

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Production</div>
          <div className="page-head__sub">
            Approved orders, by destination route · {rows.length} in the queue
            {unit ? ` · ${unit}` : ' · all units'}
          </div>
        </div>
        <div className="cal__nav">
          <Link to="/production/dispatch" className="btn btn--ghost btn--sm">
            Dispatch planning
          </Link>
          <Link to="/production/close-week" className="btn btn--ghost btn--sm">
            Close the week
          </Link>
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read the queue">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile label="In the queue" value={String(rows.length)} foot="Approved and released" />
        <Tile
          label="Changed after approval"
          value={String(stats.changed)}
          tone={stats.changed ? 'warn' : undefined}
          foot={stats.changed ? 'The floor may be building the wrong thing' : 'None'}
        />
        <Tile label="Dispatched" value={String(stats.dispatched)} tone="ok" foot="Complete" />
        <Tile
          label="No route set"
          value={String(stats.noRoute)}
          tone={stats.noRoute ? 'warn' : undefined}
          foot="Nowhere to deliver"
        />
      </div>

      <div className="cal__toolbar">
        <Select value={unit} onChange={(e) => setUnit(e.target.value)} aria-label="Unit">
          <option value="">All units</option>
          {UNITS.map((u) => (
            <option key={u} value={u}>
              {u}
            </option>
          ))}
        </Select>
        <Input
          placeholder="Search order number or route…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search the queue"
        />
      </div>

      {loading && <Empty icon="◔" title="Reading the queue…" />}

      {!loading && !error && shown.length === 0 && (
        <Empty icon="—" title="Nothing in the queue">
          Orders appear here once a sales manager approves them.
        </Empty>
      )}

      {!loading && shown.length > 0 && (
        <div className="orders__list">
          {shown.map((r) => (
            <div
              key={r.id}
              className="ordrow"
              role="button"
              tabIndex={0}
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
                  <span aria-hidden="true">{r.changedAfterApproval ? '⚠' : '🧾'}</span>
                  {/* The route is the title. Never the customer, and never the
                      territory — see the API for why "No route set" stands. */}
                  <span className={r.route === 'No route set' ? 'dim' : ''}>{r.route}</span>
                  {r.changedAfterApproval && <Badge tone="danger">CHANGED</Badge>}
                </span>
                <b className="num">{money(r.total, 0)}</b>
              </div>

              <div className="ordrow__meta">
                <span className="mono">{r.id}</span> · raised {formatDate(r.placedOn)}
              </div>
              <div className="ordrow__meta">
                Deliver by {r.deliveryDate ? formatDate(r.deliveryDate) : 'not set'}
                {r.productionFinishDate ? ` · est. finish ${formatDate(r.productionFinishDate)}` : ''}
              </div>

              <div className="ordrow__status">
                <CompletionTick productionStatus={r.productionStatus} />
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
