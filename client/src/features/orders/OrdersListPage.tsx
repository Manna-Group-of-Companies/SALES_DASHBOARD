/**
 * A1 — Team Orders.
 *
 * **The only place an order is approved.** It is deliberately absent from the
 * approvals inbox: approving fixes a price permanently, commits stock, and for
 * a lead converts the party, and that decision needs the lines, the stock
 * position and the credit picture, which an inbox row cannot carry.
 *
 * Sales Orders and Lead Orders appear in one list. They are two doctypes but
 * one job — a manager owes a decision on both, and splitting them would be two
 * places to look and two counts to hold in your head. Lead orders are marked,
 * because what approval *does* to them is different.
 *
 * The week is chosen, not inferred, and the choice is built from the **server's
 * clock**. A browser clock a day out would silently show a manager a different
 * week than the one their decisions land in.
 */

import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import type { LeadOrder, SalesPerson, TeamOrder } from '@/domain/types';
import { activeSalesPeople } from '@/domain/attendance';
import { scopeFor, teamOf, NO_TEAM_MESSAGE } from '@/domain/sales';
import {
  awaitingManager,
  isApproved,
  leadOrderApproved,
  productionLine,
  isSet,
} from '@/domain/orderStatus';
import { recentWeeks, type Week } from '@/domain/weeks';
import { serverNow } from '@/domain/serverClock';
import { formatDate } from '@/domain/orderRules';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Empty, Input, Select } from '@/components/ui';
import { money } from '@/components/common/format';
import { StatusPill, CompletionTick } from '@/components/common/StatusPill';
import { RefreshButton } from '@/components/common/RefreshButton';
import { ExportButton } from '@/features/reports/ExportButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import '@/components/common/status.css';
import './orders.css';

/** A Sales Order and a Lead Order flattened onto one shape for the list. */
interface Row {
  id: string;
  kind: 'sales' | 'lead';
  party: string;
  rep: string;
  date: string;
  total: number;
  status: string;
  productionStatus?: string;
  productionFinishDate?: string;
  combinedOrder?: string;
  undecided: boolean;
}

export function OrdersListPage() {
  const user = useAppSelector(selectUser);
  const navigate = useNavigate();

  const [orders, setOrders] = useState<TeamOrder[]>([]);
  const [leadOrders, setLeadOrders] = useState<LeadOrder[]>([]);
  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [weeks, setWeeks] = useState<Week[]>([]);
  const [weekStart, setWeekStart] = useState('');
  const [rep, setRep] = useState('');
  const [query, setQuery] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  /*
   * The week list is built once a server response has been seen, so the
   * clock behind it is the server's. Until then there is nothing to choose
   * from, which is honest: the alternative is offering a week that may be
   * wrong and silently correcting it underneath the manager.
   */
  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.attendance
      .listSalesPeople()
      .then(async (p) => {
        if (!live) return;
        setPeople(p);
        const team = scopeFor(p, user?.salesPerson);
        /* Fail closed: an unresolved team must show nothing, never everyone. */
        if (!team) {
          setError(NO_TEAM_MESSAGE);
          return;
        }
        const list = recentWeeks(serverNow(), 13);
        const chosen = weekStart || list[0].start;
        const week = list.find((w) => w.start === chosen) ?? list[0];
        setWeeks(list);
        setWeekStart(week.start);

        const [so, lo] = await Promise.all([
          Api.sales.listOrders(team),
          Api.sales
            .listLeadOrders({
              reps: team,
              from: week.start,
              to: week.end,
            })
            .catch(() => [] as LeadOrder[]),
        ]);
        if (!live) return;
        setOrders(so);
        setLeadOrders(lo);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read orders.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick, user, weekStart]);

  const week = useMemo(
    () => weeks.find((w) => w.start === weekStart) ?? weeks[0],
    [weeks, weekStart],
  );

  const staff = useMemo(() => activeSalesPeople(people), [people]);
  const myTeam = useMemo(() => teamOf(people, user?.salesPerson), [people, user]);

  const repOptions = useMemo(
    () =>
      staff
        .filter((p) => !myTeam.length || myTeam.includes(p.id))
        .sort((a, b) => a.name.localeCompare(b.name)),
    [staff, myTeam],
  );

  /** Both doctypes, mapped onto one shape and filtered to the chosen week. */
  const allRows = useMemo<Row[]>(() => {
    if (!week) return [];
    const inWeek = (d: string) => d >= week.start && d <= week.end;

    const sales: Row[] = orders
      .filter((o) => inWeek(o.placedOn))
      .map((o) => ({
        id: o.id,
        kind: 'sales',
        party: o.customerName,
        rep: o.rep,
        date: o.placedOn,
        total: o.total,
        status: o.poStatus,
        productionStatus: o.productionStatus,
        combinedOrder: o.combinedOrder,
        undecided: awaitingManager(o.poStatus),
      }));

    const leads: Row[] = leadOrders.map((l) => ({
      id: l.id,
      kind: 'lead',
      party: l.leadName,
      rep: l.rep ?? '',
      date: l.orderDate,
      total: l.total,
      status: l.status,
      undecided: !leadOrderApproved(l.status),
    }));

    return [...sales, ...leads].sort((a, b) => b.date.localeCompare(a.date));
  }, [orders, leadOrders, week]);

  const rows = useMemo(() => {
    let list = rep ? allRows.filter((r) => r.rep === rep) : allRows;
    const q = query.trim().toLowerCase();
    if (q) {
      list = list.filter(
        (r) =>
          r.id.toLowerCase().includes(q) ||
          r.party.toLowerCase().includes(q) ||
          r.rep.toLowerCase().includes(q),
      );
    }
    return list;
  }, [allRows, rep, query]);

  const waiting = useMemo(() => rows.filter((r) => r.undecided).length, [rows]);

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Team orders</div>
          <div className="page-head__sub">
            {myTeam.length
              ? `${myTeam.length} representatives in your team`
              : 'Your orders'}
          </div>
        </div>
        <div className="cal__nav">
          <ExportButton
            filename={`orders-${week?.start ?? 'week'}.xlsx`}
            sheet="Orders"
            disabled={rows.length === 0}
            rows={() =>
              rows.map((r) => ({
                Order: r.id,
                Type: r.kind === 'lead' ? 'Lead order' : 'Sales order',
                Party: r.party,
                Representative: r.rep,
                Date: r.date,
                Total: r.total,
                Approval: r.status,
                Production: r.productionStatus ?? '',
                'Combined order': r.combinedOrder ?? '',
              }))
            }
          />
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read orders">
          {error}
        </Alert>
      )}

      <div className="cal__toolbar">
        <Select
          value={weekStart}
          onChange={(e) => setWeekStart(e.target.value)}
          aria-label="Week"
        >
          {weeks.map((w, i) => (
            <option key={w.start} value={w.start}>
              {i === 0 ? `This week · ${w.label}` : w.label}
            </option>
          ))}
        </Select>
        <Select value={rep} onChange={(e) => setRep(e.target.value)} aria-label="Representative">
          <option value="">All representatives</option>
          {repOptions.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </Select>
        <Input
          placeholder="Search order, party or rep…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search orders"
        />
      </div>

      {/* The one line that says whether there is work to do. */}
      <div className={`orders__count ${waiting ? 'warn' : 'ok'}`}>
        {rows.length} order{rows.length === 1 ? '' : 's'} ·{' '}
        {waiting ? `${waiting} waiting on you` : 'all decided'}
      </div>

      {loading && <Empty icon="◔" title="Reading orders…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="—" title="No orders in this week">
          Pick another week above, or clear the search.
        </Empty>
      )}

      {!loading && rows.length > 0 && (
        <div className="orders__list">
          {rows.map((r) => {
            const prod =
              r.kind === 'sales'
                ? productionLine({
                    poStatus: r.status,
                    productionStatus: r.productionStatus,
                    productionFinishDate: r.productionFinishDate,
                  })
                : null;
            const to = r.kind === 'lead' ? `/lead-orders/${r.id}` : `/orders/${r.id}`;
            return (
              <div
                key={`${r.kind}-${r.id}`}
                className="ordrow"
                role="button"
                tabIndex={0}
                onClick={() => navigate(to)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    navigate(to);
                  }
                }}
              >
                <div className="ordrow__top">
                  <span className="ordrow__party">
                    <Link to={to} onClick={(e) => e.stopPropagation()}>
                      {r.party}
                    </Link>
                    {r.kind === 'lead' && (
                      <Badge tone="accent" title="Not yet a customer">
                        LEAD
                      </Badge>
                    )}
                  </span>
                  <b className="num">{money(r.total, 0)}</b>
                </div>

                <div className="ordrow__meta">
                  <span className="mono">{r.id}</span> · {r.rep || 'unassigned'} ·{' '}
                  {formatDate(r.date)}
                </div>

                <div className="ordrow__status">
                  <StatusPill status={r.status} />
                  {r.undecided && <span className="tiny dim">Tap to review</span>}
                  {/* Never a tick on a lead order: it is not a Sales Order yet
                      and has no production status, so an empty box would read
                      as "not finished" rather than "not applicable". */}
                  <CompletionTick
                    productionStatus={r.productionStatus}
                    applicable={r.kind === 'sales' && isApproved(r.status)}
                  />
                </div>

                {/* Only once approved: before that, production has never seen
                    the order and any sentence about it would be invented. */}
                {prod && (
                  <div className={`ordrow__prod ${prod.done ? 'done' : ''}`}>
                    <span aria-hidden="true">{prod.done ? '☑' : '🏭'}</span> {prod.text}
                  </div>
                )}

                {isSet(r.combinedOrder) && (
                  <div className="ordrow__comb">
                    <span aria-hidden="true">⑃</span> Week order: {r.combinedOrder}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
