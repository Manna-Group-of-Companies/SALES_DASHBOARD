/**
 * The GM's follow-up — every order they approved, after the approval.
 *
 * Asked for 25 September 2026, as its own view rather than a panel under
 * "Escalated to you": that screen is what waits on the GM's decision, and
 * this is what the decision set in motion. An order lands here the moment the
 * GM approves it and stays until nothing is left to watch — through the sales
 * manager's push, SAP's order number, the invoice, and the rep's answers to
 * the condition, which arrive on the order itself.
 *
 * Sorted by what needs the GM first — see `followUpBucket`.
 */

import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Api, type FollowUp } from '@/api/client';
import {
  FOLLOW_UP_BUCKETS,
  FOLLOW_UP_LABEL,
  followUpBucket,
  type FollowUpBucket,
} from '@/domain/followUp';
import { COND_CLOSED, conditionOverdue } from '@/domain/creditCondition';
import { formatDate } from '@/domain/orderRules';
import { serverNow } from '@/domain/serverClock';
import { Alert, Badge, Card, Empty, Input, Segmented } from '@/components/ui';
import { money } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import { StatusPill } from '@/components/common/StatusPill';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import './orders.css';

type Filter = FollowUpBucket | 'all';

export function GmFollowUpPage() {
  const [rows, setRows] = useState<FollowUp[]>([]);
  const [filter, setFilter] = useState<Filter>('all');
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.sales
      .listFollowUps()
      .then((r) => live && setRows(r))
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read the follow-up.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick]);

  const today = serverNow();

  const sorted = useMemo(() => {
    const withBucket = rows.map((f) => ({
      f,
      bucket: followUpBucket({ poStatus: f.order.poStatus, conditions: f.conditions, today }),
    }));
    const rank = (b: FollowUpBucket) => FOLLOW_UP_BUCKETS.indexOf(b);
    return withBucket.sort(
      (a, b) =>
        rank(a.bucket) - rank(b.bucket) ||
        (b.f.order.gmApprovedOn ?? '').localeCompare(a.f.order.gmApprovedOn ?? ''),
    );
    // `today` is read once per load; re-sorting on every render would move
    // rows under the GM's cursor at midnight.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rows]);

  const count = (b: FollowUpBucket) => sorted.filter((x) => x.bucket === b).length;

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    return sorted.filter(
      ({ f, bucket }) =>
        (filter === 'all' || bucket === filter) &&
        (!q ||
          f.order.id.toLowerCase().includes(q) ||
          (f.order.sapSalesOrder ?? '').toLowerCase().includes(q) ||
          f.order.customerName.toLowerCase().includes(q) ||
          f.order.rep.toLowerCase().includes(q)),
    );
  }, [sorted, filter, query]);

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Follow-up</div>
          <div className="page-head__sub">
            Orders you approved — what SAP has made of them, and what the reps owe on them
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read the follow-up">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile
          label="Rep has answered"
          value={String(count('answered'))}
          tone={count('answered') ? 'warn' : 'ok'}
          foot={count('answered') ? 'Waiting for you to close or send back' : 'Nothing waiting on you'}
          onClick={() => setFilter('answered')}
        />
        <Tile
          label="Overdue"
          value={String(count('overdue'))}
          tone={count('overdue') ? 'alert' : 'ok'}
          foot="Past the date, not yet answered"
          onClick={() => setFilter('overdue')}
        />
        <Tile
          label="Waiting for the push"
          value={String(count('awaiting_push'))}
          foot="With the sales manager, not yet in SAP"
          onClick={() => setFilter('awaiting_push')}
        />
        <Tile
          label="Condition open"
          value={String(count('open'))}
          foot="In SAP, condition still owed"
          onClick={() => setFilter('open')}
        />
      </div>

      <div className="cal__toolbar" style={{ flexWrap: 'wrap', gap: 8 }}>
        <Segmented<Filter>
          ariaLabel="Show"
          value={filter}
          onChange={setFilter}
          options={[
            { value: 'all', label: `All (${sorted.length})` },
            ...FOLLOW_UP_BUCKETS.map((b) => ({ value: b, label: FOLLOW_UP_LABEL[b] })),
          ]}
        />
        <Input
          placeholder="Search customer, order, SAP number or rep…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search the follow-up"
        />
      </div>

      {loading && rows.length === 0 && <Empty icon="◔" title="Reading the follow-up…" />}

      {!loading && !error && shown.length === 0 && (
        <Empty icon="✓" title={rows.length ? 'Nothing in this pile' : 'Nothing to follow up yet'}>
          An order lands here the moment you approve it, and stays until its condition is closed.
        </Empty>
      )}

      {shown.length > 0 && (
        <Card flush>
          <div className="scroll-x">
            <table className="table fu__table">
              <thead>
                <tr>
                  <th>Customer</th>
                  <th>Order</th>
                  <th>Condition</th>
                  <th>Latest from the rep</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {shown.map(({ f, bucket }) => {
                  const live = f.conditions.filter((c) => c.status !== COND_CLOSED);
                  const c = live[0] ?? f.conditions[0];
                  const late = c ? conditionOverdue(c.status, c.dueDate, today) : false;
                  return (
                    <tr key={f.order.id} className={bucket === 'answered' ? 'fu__row--answered' : ''}>
                      <td>
                        <Link to={`/follow-up/${f.order.id}`} className="fu__link">
                          {f.order.customerName}
                        </Link>
                        <div className="tiny dim">
                          {f.order.rep} · {money(f.order.total, 0)}
                        </div>
                      </td>
                      <td>
                        {/*
                          SAP's number once SAP has the order: it is the one the
                          factory, the delivery note and the invoice carry. The
                          ERPNext name stays underneath, small, for support.
                        */}
                        {f.order.sapSalesOrder ? (
                          <b className="mono">SAP {f.order.sapSalesOrder}</b>
                        ) : (
                          <span className="dim">Not in SAP yet</span>
                        )}
                        <div className="tiny dim mono">{f.order.id}</div>
                        {f.order.sapInvoice && (
                          <div className="tiny">
                            Invoice {f.order.sapInvoice}
                            {f.order.sapInvoiceDate ? ` · ${formatDate(f.order.sapInvoiceDate)}` : ''}
                          </div>
                        )}
                      </td>
                      <td className="fu__cond">
                        {c ? (
                          <>
                            <div className="fu__clip">{c.condition}</div>
                            <div className="tiny">
                              <Badge
                                tone={
                                  late
                                    ? 'danger'
                                    : c.status === COND_CLOSED
                                      ? 'ok'
                                      : c.status === 'Awaiting Review'
                                        ? 'info'
                                        : 'warn'
                                }
                              >
                                {late ? 'Overdue' : c.status}
                              </Badge>{' '}
                              {c.dueDate ? `due ${formatDate(c.dueDate)}` : 'no deadline'}
                            </div>
                          </>
                        ) : (
                          <span className="dim">No condition</span>
                        )}
                      </td>
                      <td className="fu__cond">
                        {f.lastAnswer ? (
                          <>
                            <div className="fu__clip">“{f.lastAnswer.comment}”</div>
                            <div className="tiny dim">
                              {f.lastAnswer.postedOn ? formatDate(f.lastAnswer.postedOn.slice(0, 10)) : ''}
                            </div>
                          </>
                        ) : c?.response ? (
                          <div className="fu__clip">“{c.response}”</div>
                        ) : (
                          <span className="dim">Nothing yet</span>
                        )}
                      </td>
                      <td>
                        <StatusPill status={f.order.poStatus} sapStatus={f.order.sapSalesOrderStatus} />
                        <div className="tiny dim" style={{ marginTop: 4 }}>
                          {FOLLOW_UP_LABEL[bucket]}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </Card>
      )}
    </div>
  );
}
