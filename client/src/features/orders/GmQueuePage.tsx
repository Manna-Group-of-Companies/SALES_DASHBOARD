/**
 * §7.4 — The General Manager's queue.
 *
 * Everything a sales manager could not finalise: orders that would take a
 * customer past their credit limit. Each card leads with the credit picture,
 * because that is the whole reason the order arrived here — a GM opening this
 * screen is answering one question, and it should not need a click. The bar
 * draws it: what is owed, what this order adds, where the limit falls.
 *
 * Under it, the rep's commitment: what the customer promised in exchange for
 * the credit. That is the other half of the question, so it is on the card
 * rather than a click away.
 *
 * Longest-waiting first: an escalation holds a customer's goods, and the one
 * that has waited three days matters more than the one raised this morning.
 *
 * "Review" opens the GM's own review (`GmOrderPage`), not the sales
 * manager's — that one offered the GM "Send to GM" on an order already
 * escalated to them. There the two exemptions apply: they may edit an order
 * that is not theirs, and change a rate the sales manager already locked. See
 * `orderStatus.ts` for why both exist.
 */

import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import type { SalesCustomer, TeamOrder } from '@/domain/types';
import { creditPicture, PO_STATUS } from '@/domain/orderStatus';
import { agingOf, bucketsOf, escalationOf, pastTermsPhrase } from '@/domain/credit';
import { hasCommitment } from '@/domain/creditCommitment';
import { formatDate } from '@/domain/orderRules';
import { daysBetween } from '@/domain/hrRules';
import { frappeToday } from '@/domain/serverClock';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Empty, Input } from '@/components/ui';
import { money, moneyShort } from '@/components/common/format';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import { COND_AWAITING } from '@/domain/creditCondition';
import { CreditBar } from './CreditBar';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import './orders.css';

/** The customer's six credit fields, as `agingOf` reads them. */
function rowOf(c: SalesCustomer | undefined) {
  return {
    custom_outstanding_balance: c?.outstanding ?? 0,
    custom_credit_limit: c?.creditLimit ?? 0,
    custom_outstanding_0_30: c?.outstanding0_30 ?? 0,
    custom_outstanding_30_60: c?.outstanding30_60 ?? 0,
    custom_outstanding_60_90: c?.outstanding60_90 ?? 0,
    custom_outstanding_90_plus: c?.outstanding90Plus ?? 0,
    custom_overdue_past_terms: c?.overduePastTerms ?? 0,
    custom_payment_terms: c?.paymentTerms ?? '',
    custom_overdue_days: c?.overdueDays ?? 0,
  };
}

function waited(placedOn: string, today: string): { text: string; long: boolean } {
  const days = placedOn ? Math.max(0, daysBetween(placedOn, today)) : 0;
  if (days === 0) return { text: 'Raised today', long: false };
  return { text: `Waiting ${days} day${days === 1 ? '' : 's'}`, long: days >= 2 };
}

export function GmQueuePage() {
  const user = useAppSelector(selectUser);
  const navigate = useNavigate();

  const [orders, setOrders] = useState<TeamOrder[]>([]);
  /**
   * What is waiting in Follow-up, said here so an approval does not simply
   * vanish from the GM's view. The orders themselves live on that screen.
   */
  const [awaitingPush, setAwaitingPush] = useState(0);
  const [answered, setAnswered] = useState(0);
  const [customers, setCustomers] = useState<SalesCustomer[]>([]);
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([
      Api.sales.listOrders(),
      Api.sales.listCustomers(),
      Api.sales.listCreditConditions().catch(() => []),
    ])
      .then(([o, c, conds]) => {
        if (!live) return;
        setOrders(o.filter((x) => x.poStatus === PO_STATUS.pendingGm));
        setAwaitingPush(o.filter((x) => x.poStatus === PO_STATUS.finalApproval).length);
        setAnswered(conds.filter((k) => k.status === COND_AWAITING).length);
        setCustomers(c);
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
  }, [tick]);

  const byId = useMemo(() => new Map(customers.map((c) => [c.id, c])), [customers]);
  const today = frappeToday();

  /** Each order with its credit picture, read the way the review page reads it. */
  const cards = useMemo(
    () =>
      orders
        .map((o) => {
          const c = byId.get(o.customer);
          const row = rowOf(c);
          const aging = agingOf(row);
          return {
            o,
            aging,
            // The second reason an order is here (11 Oct 2026).
            pastTerms: escalationOf(row, o.total).pastTerms ? pastTermsPhrase(row) : '',
            picture: creditPicture({ outstanding: aging.total, creditLimit: c?.creditLimit, orderTotal: o.total }),
          };
        })
        // Longest-waiting first; same day, the larger overshoot first.
        .sort((a, b) => a.o.placedOn.localeCompare(b.o.placedOn) || b.picture.over - a.picture.over),
    [orders, byId],
  );

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return cards;
    return cards.filter(
      ({ o }) =>
        o.id.toLowerCase().includes(q) ||
        o.customerName.toLowerCase().includes(q) ||
        o.rep.toLowerCase().includes(q),
    );
  }, [cards, query]);

  const totals = useMemo(
    () => ({
      value: cards.reduce((s, x) => s + x.o.total, 0),
      over: cards.reduce((s, x) => s + x.picture.over, 0),
    }),
    [cards],
  );

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Escalated to You</div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not load the queue">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 16 }}>
        <Tile
          label="Awaiting your decision"
          value={String(orders.length)}
          foot={orders.length ? `${moneyShort(totals.value)} of orders` : 'Nothing waiting'}
          tone={orders.length ? 'warn' : 'ok'}
        />
        <Tile
          label="Over limit, in total"
          value={moneyShort(totals.over)}
          foot="if every order here is approved"
          tone={totals.over > 0 ? 'alert' : undefined}
        />
        {/*
          The other half of the loop lives in Follow-up: what the GM approved,
          and the reps' answers to the conditions. Counted here so an answer
          waiting on the GM is seen from the screen they open first.
        */}
        <Tile
          label="Reps' answers to review"
          value={String(answered)}
          foot="in Follow-up"
          tone={answered ? 'warn' : undefined}
          onClick={() => navigate('/follow-up')}
        />
        <Tile
          label="Approved, awaiting SAP push"
          value={String(awaitingPush)}
          foot="with the sales manager"
          onClick={() => navigate('/follow-up')}
        />
      </div>

      {orders.length > 0 && (
        <div className="cal__toolbar">
          <Input
            placeholder="Search order, customer or rep"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            aria-label="Search the queue"
          />
        </div>
      )}

      {loading && orders.length === 0 && <Empty icon="◔" title="Loading…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="✓" title={orders.length ? 'No matching orders' : 'No escalated orders'}>
          {orders.length ? undefined : 'Every order is within its customer’s limit, or already decided.'}
        </Empty>
      )}

      <div className="gmq__grid">
        {rows.map(({ o, aging, pastTerms, picture: p }) => {
          const wait = waited(o.placedOn, today);
          return (
            <article key={o.id} className="gmq">
              <header className="gmq__head">
                <div style={{ minWidth: 0 }}>
                  <div className="gmq__customer">{o.customerName}</div>
                  <div className="gmq__sub">
                    {o.rep || '—'} · <span className="mono">{o.id}</span>
                  </div>
                </div>
                <span className={`gmq__wait${wait.long ? ' is-long' : ''}`}>{wait.text}</span>
              </header>

              <div className="gmq__figures">
                <div>
                  <div className="gmq__fig-label">This order</div>
                  <div className="gmq__fig-value num">{money(p.orderTotal, 0)}</div>
                </div>
                <div>
                  <div className="gmq__fig-label">Projected</div>
                  <div className="gmq__fig-value num">{money(p.projected, 0)}</div>
                </div>
                <div>
                  <div className="gmq__fig-label">Over limit by</div>
                  <div className={`gmq__fig-value num${p.over > 0 ? ' is-over' : ''}`}>
                    {p.over > 0 ? money(p.over, 0) : '—'}
                  </div>
                </div>
              </div>

              <div className="gmq__body">
                <CreditBar picture={p} compact />
                {pastTerms && <div className="gm__over">Overdue: {pastTerms}</div>}

                {aging.bucketsKnown && (
                  <div className="gmq__aging" aria-label="Outstanding by age">
                    {bucketsOf(aging).map((b) => (
                      <div key={b.key} className={`gmq__age${b.overdue ? ' is-late' : ''}`}>
                        <span>{b.label.replace(' days', 'd')}</span>
                        <b>{moneyShort(b.amount)}</b>
                      </div>
                    ))}
                  </div>
                )}

                <div
                  className={hasCommitment(o.creditCommitment) ? 'gm__commit' : 'gm__commit gm__commit--none'}
                  title={o.creditCommitment}
                >
                  {hasCommitment(o.creditCommitment) ? `“${o.creditCommitment}”` : 'No commitment from the customer'}
                </div>
                {hasCommitment(o.creditCommitment) && o.creditCommitmentDue && (
                  <div className="gmq__due">Promised by {formatDate(o.creditCommitmentDue)}</div>
                )}
              </div>

              <footer className="gmq__foot">
                <span>
                  Raised {formatDate(o.placedOn)}
                  {o.deliveryDate ? ` · Delivery ${formatDate(o.deliveryDate)}` : ''}
                </span>
                <Link to={`/gm/orders/${o.id}`} className="btn btn--sm btn--primary">
                  Review
                </Link>
              </footer>
            </article>
          );
        })}
      </div>
    </div>
  );
}
