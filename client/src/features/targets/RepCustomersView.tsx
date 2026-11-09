/**
 * Team Targets → one rep: every customer of theirs, what they ordered and SAP
 * invoiced this month, and what they owe today (5 Nov 2026).
 *
 * Reached by clicking a rep on TargetsPage. Read-only. What is joined, and why
 * there is no "paid" column, is in ./repCustomers.ts.
 */

import { Fragment, useEffect, useMemo, useState } from 'react';
import { Api } from '@/api/client';
import { getRepOrders, getSapInvoices, type RepMonthOrder, type SapInvoice } from '@/api/salesTargets';
import { achieved, formatMoney, formatTarget, fraction, hasTarget, type TargetRow } from '@/domain/salesTarget';
import type { SalesCustomer } from '@/domain/types';
import { Alert, Badge, Button, Card, Icon, Skeleton, type BadgeTone } from '@/components/ui';
import { buildRepCustomers, initials, shortDate, statusOf, type RepCustomerRow } from './repCustomers';
import './targets.css';

type Filter = 'all' | 'owes' | 'overdue' | 'clear';

const pad = (n: number) => String(n).padStart(2, '0');

export function RepCustomersView({
  row,
  month,
  monthIndex,
  year,
  canEdit,
  onBack,
  onEdit,
  onShowInvoices,
}: {
  row: TargetRow;
  month: string;
  /** 0–11. */
  monthIndex: number;
  year: number;
  canEdit: boolean;
  onBack: () => void;
  onEdit: () => void;
  onShowInvoices: () => void;
}) {
  const [customers, setCustomers] = useState<SalesCustomer[]>([]);
  const [orders, setOrders] = useState<RepMonthOrder[]>([]);
  const [sapInvoices, setSapInvoices] = useState<Map<string, SapInvoice[]>>(new Map());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>('all');
  const [q, setQ] = useState('');
  const [open, setOpen] = useState<Set<string>>(new Set());

  const from = `${year}-${pad(monthIndex + 1)}-01`;
  const to = `${year}-${pad(monthIndex + 1)}-${pad(new Date(year, monthIndex + 1, 0).getDate())}`;

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([Api.sales.listCustomers([row.salesPerson]), getRepOrders(row.salesPerson, from, to)])
      .then(async ([c, o]) => {
        if (!live) return;
        setCustomers(c);
        setOrders(o);
        // Per-invoice paid/balance, once the SAP sync writes it. Optional:
        // [] until then, and the table keeps its order-line form.
        const ids = [...new Set([...o.map((x) => x.customer), ...c.map((x) => x.id)])].filter(Boolean);
        const inv = await getSapInvoices(ids);
        if (!live) return;
        const by = new Map<string, SapInvoice[]>();
        for (const i of inv) by.set(i.customer, [...(by.get(i.customer) ?? []), i]);
        setSapInvoices(by);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error && e.message ? e.message : 'Could not read the customers.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [row.salesPerson, from, to]);

  // Only customers who ordered or were invoiced in the month (asked 5 Nov 2026).
  const all = useMemo(
    () =>
      buildRepCustomers(customers, orders, row.lines).filter((r) => r.orders.length > 0 || r.invoices.length > 0),
    [customers, orders, row.lines],
  );
  const m = (v: number) => formatMoney(row, v);

  const T = useMemo(() => {
    const s = (f: (r: RepCustomerRow) => number) => all.reduce((n, r) => n + f(r), 0);
    return {
      ordered: s((r) => r.ordered),
      orders: s((r) => r.orders.length),
      notInvoiced: s((r) => r.orders.filter((o) => !o.sapInvoice).reduce((n, o) => n + o.netTotal, 0)),
      invoiced: s((r) => r.invoiced),
      invoices: new Set(row.lines.map((l) => l.invoice)).size,
      assigned: customers.length,
    };
  }, [all, customers.length, row.lines]);

  // The rep's own totals, from the same script as the list, so the two agree.
  const owed = row.outstanding;
  const overdue = Math.min(row.overdue, owed);
  const pct = (v: number) => (owed > 0 ? (v / owed) * 100 : 0);

  const counts: Record<Filter, number> = {
    all: all.length,
    owes: all.filter((r) => (r.outstanding ?? 0) > 1).length,
    overdue: all.filter((r) => statusOf(r) === 'overdue').length,
    clear: all.filter((r) => statusOf(r) === 'clear').length,
  };

  const needle = q.trim().toLowerCase();
  const list = all.filter((r) => {
    if (filter === 'clear' && statusOf(r) !== 'clear') return false;
    if (filter === 'owes' && !((r.outstanding ?? 0) > 1)) return false;
    if (filter === 'overdue' && statusOf(r) !== 'overdue') return false;
    return !needle || `${r.name} ${r.id}`.toLowerCase().includes(needle);
  });
  const L = {
    orders: list.reduce((n, r) => n + r.orders.length, 0),
    ordered: list.reduce((n, r) => n + r.ordered, 0),
    invoiced: list.reduce((n, r) => n + r.invoiced, 0),
    out: list.reduce((n, r) => n + (r.outstanding ?? 0), 0),
    od: list.reduce((n, r) => n + r.overdue, 0),
  };

  /** Paid against this customer's SAP invoices; null until the sync writes them. */
  const paidOf = (r: RepCustomerRow): number | null => {
    const inv = r.id ? sapInvoices.get(r.id) : undefined;
    return inv?.length ? inv.reduce((n, i) => n + i.paid, 0) : null;
  };
  const listPaid = list.reduce((n, r) => n + (paidOf(r) ?? 0), 0);

  const rowKey = (r: RepCustomerRow) => r.id || `name:${r.name}`;
  const toggle = (k: string) =>
    setOpen((s) => {
      const n = new Set(s);
      if (n.has(k)) n.delete(k);
      else n.add(k);
      return n;
    });

  const f = fraction(row);

  return (
    <div>
      <nav className="tg-crumb" aria-label="Breadcrumb">
        <button type="button" onClick={onBack}>
          Team Targets
        </button>
        <Icon name="chevronRight" size={14} />
        <span>{row.salesPerson}</span>
      </nav>

      <div className="tg-head">
        <div className="tg-avatar" aria-hidden>
          {initials(row.salesPerson)}
        </div>
        <div className="grow" style={{ minWidth: 0 }}>
          <h2>{row.salesPerson}</h2>
          <div className="tg-head__sub">
            {row.team ? `${row.team} team · ` : ''}
            Target {hasTarget(row) ? formatTarget(row, row.targetAmount) : 'not set'} · Achieved {month} {year}{' '}
            {formatTarget(row, achieved(row))}
            {hasTarget(row) ? ` (${Math.round(f * 100)}%)` : ''}
          </div>
        </div>
        {canEdit && (
          <Button size="sm" onClick={onEdit}>
            {hasTarget(row) ? 'Edit target' : 'Set target'}
          </Button>
        )}
        <Button size="sm" onClick={onBack}>
          Back
        </Button>
      </div>

      {error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="danger" title="Could not load this rep's customers">
            {error}
          </Alert>
        </div>
      )}

      <div className="tg-kpis">
        <div className="tg-kpi">
          <div className="tg-kpi__l">
            <Icon name="users" size={14} />
            Customers ordered
          </div>
          <div className="tg-kpi__v">{loading ? '…' : all.length}</div>
          <div className="tg-kpi__s">{loading ? ' ' : `In ${month}, of ${T.assigned} assigned`}</div>
        </div>
        <div className="tg-kpi">
          <div className="tg-kpi__l">
            <Icon name="clipboard" size={14} />
            Ordered in {month}
          </div>
          <div className="tg-kpi__v">{loading ? '…' : m(T.ordered)}</div>
          <div className="tg-kpi__s">
            {loading
              ? ' '
              : `${T.orders} order${T.orders === 1 ? '' : 's'} · ${m(T.notInvoiced)} not invoiced`}
          </div>
        </div>
        <div className="tg-kpi">
          <div className="tg-kpi__l tg-ok">
            <Icon name="receipt" size={14} />
            Invoiced in {month}
          </div>
          <div className="tg-kpi__v tg-ok">{m(row.invoicedAmount)}</div>
          <div className="tg-kpi__s">
            {T.invoices > 0 ? (
              <button type="button" className="tg-kpi__link" onClick={onShowInvoices}>
                {T.invoices} SAP invoice{T.invoices === 1 ? '' : 's'} ›
              </button>
            ) : (
              'No invoices yet'
            )}
          </div>
        </div>
        <div className="tg-kpi">
          <div className="tg-kpi__l">
            <Icon name="rupee" size={14} />
            Outstanding
          </div>
          <div className="tg-kpi__v">{m(owed)}</div>
          <div className="tg-kpi__s">Owed today, from SAP</div>
        </div>
        <div className={`tg-kpi${overdue > 1 ? ' tg-kpi--danger' : ''}`}>
          <div className={`tg-kpi__l${overdue > 1 ? ' tg-red' : ''}`}>
            <Icon name="clock" size={14} />
            Overdue
          </div>
          <div className={`tg-kpi__v${overdue > 1 ? ' tg-red' : ''}`}>{m(overdue)}</div>
          <div className="tg-kpi__s">Past payment terms</div>
        </div>
      </div>

      {owed > 1 && (
        <div className="tg-coll">
          <div className="tg-coll__title">Outstanding</div>
          <div
            className="tg-bar"
            role="img"
            aria-label={`${Math.round(pct(owed - overdue))}% within terms, ${Math.round(pct(overdue))}% overdue`}
          >
            <i className="tg-c-terms" style={{ width: `${pct(owed - overdue)}%` }} />
            <i className="tg-c-overdue" style={{ width: `${pct(overdue)}%` }} />
          </div>
          <div className="tg-legend">
            <span>
              <i className="tg-c-terms" />
              Within terms {m(owed - overdue)}
            </span>
            <span>
              <i className="tg-c-overdue" />
              Overdue {m(overdue)}
            </span>
          </div>
        </div>
      )}

      <Card flush>
        <div className="tg-tools">
          <div className="tg-tabs" role="tablist">
            {(
              [
                ['all', 'All'],
                ['owes', 'Outstanding'],
                ['overdue', 'Overdue'],
                ['clear', 'Fully paid'],
              ] as [Filter, string][]
            ).map(([k, l]) => (
              <button
                key={k}
                type="button"
                role="tab"
                aria-selected={filter === k}
                className={`tg-tab${filter === k ? ' is-on' : ''}`}
                onClick={() => setFilter(k)}
              >
                {l}
                <b>{loading ? '' : counts[k]}</b>
              </button>
            ))}
          </div>
          <label className="tg-search">
            <Icon name="search" size={15} />
            <input
              placeholder="Search customer or code"
              value={q}
              onChange={(e) => setQ(e.target.value)}
              aria-label="Search customers"
            />
          </label>
        </div>

        <div className="scroll-x">
          <table className="table">
            <thead>
              <tr>
                <th style={{ width: 36 }} />
                <th>Customer</th>
                <th className="right">Orders</th>
                <th className="right">Ordered</th>
                <th className="right">Invoiced</th>
                <th className="right">Paid</th>
                <th className="right">Outstanding</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {loading &&
                [0, 1, 2].map((i) => (
                  <tr key={i}>
                    <td colSpan={8}>
                      <Skeleton height={18} />
                    </td>
                  </tr>
                ))}
              {!loading && list.length === 0 && (
                <tr>
                  <td colSpan={8} className="tg-empty">
                    {all.length === 0 ? `No customer ordered from this rep in ${month}.` : 'No customers match.'}
                  </td>
                </tr>
              )}
              {!loading &&
                list.map((r) => {
                  const k = rowKey(r);
                  const isOpen = open.has(k);
                  const notInvoiced = r.orders.filter((o) => !o.sapInvoice);
                  return (
                    <Fragment key={k}>
                      <tr
                        className={`tg-cust${isOpen ? ' is-open' : ''}`}
                        onClick={() => toggle(k)}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault();
                            toggle(k);
                          }
                        }}
                        tabIndex={0}
                        aria-expanded={isOpen}
                      >
                        <td>
                          <span className="tg-chev">
                            <Icon name="chevronRight" size={16} />
                          </span>
                        </td>
                        <td>
                          <div className="tg-cname">{r.name}</div>
                          <div className="tiny dim">
                            {[r.id && r.id !== r.name ? r.id : '', r.paymentTerms, r.assigned ? '' : 'not assigned to this rep']
                              .filter(Boolean)
                              .join(' · ') || ' '}
                          </div>
                        </td>
                        <td className="right">
                          {r.orders.length || <span className="dim">0</span>}
                          {r.lastOrder && <div className="tiny dim">Last {shortDate(r.lastOrder)}</div>}
                        </td>
                        <td className="right">
                          {r.ordered ? m(r.ordered) : <span className="dim">—</span>}
                          {notInvoiced.length > 0 && (
                            <div className="tiny dim">
                              {m(notInvoiced.reduce((n, o) => n + o.netTotal, 0))} not invoiced
                            </div>
                          )}
                        </td>
                        <td className="right">{r.invoiced ? m(r.invoiced) : <span className="dim">—</span>}</td>
                        <td className="right tg-ok" style={{ fontWeight: 600 }}>
                          {paidOf(r) == null ? <span className="dim">—</span> : m(paidOf(r)!)}
                        </td>
                        <td className="right" style={{ fontWeight: 600 }}>
                          {r.outstanding == null ? <span className="dim">—</span> : m(r.outstanding)}
                          {r.overdue > 1 && <div className="tiny tg-red">{m(r.overdue)} overdue</div>}
                        </td>
                        <td>
                          <StatusPill r={r} />
                        </td>
                      </tr>
                      {isOpen && (
                        <tr className="tg-docs">
                          <td colSpan={8}>
                            <div className="tg-docs__wrap">
                              <InvoiceTable r={r} invoices={(r.id && sapInvoices.get(r.id)) || []} m={m} month={month} />
                            </div>
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  );
                })}
            </tbody>
            {!loading && list.length > 0 && (
              <tfoot>
                <tr>
                  <td />
                  <td>Total ({list.length})</td>
                  <td className="right">{L.orders}</td>
                  <td className="right">{m(L.ordered)}</td>
                  <td className="right">{m(L.invoiced)}</td>
                  <td className="right tg-ok">{m(listPaid)}</td>
                  <td className="right">
                    {m(L.out)}
                    {L.od > 1 && <div className="tiny tg-red">{m(L.od)} overdue</div>}
                  </td>
                  <td />
                </tr>
              </tfoot>
            )}
          </table>
        </div>
      </Card>

      <div className="tg-hint">
        <Icon name="info" size={14} />
        Click a customer to see each invoice and what was paid against it. Outstanding = invoiced − paid; orders not
        yet invoiced are not counted as outstanding. Ordered and invoiced are before GST.
      </div>
    </div>
  );
}

const PILL: Record<ReturnType<typeof statusOf>, BadgeTone> = {
  overdue: 'danger',
  owes: 'warn',
  clear: 'ok',
  unknown: 'neutral',
};

function StatusPill({ r }: { r: RepCustomerRow }) {
  const s = statusOf(r);
  const text =
    s === 'overdue'
      ? `Overdue${r.overdueDays ? ` ${r.overdueDays}d` : ''}`
      : s === 'owes'
        ? 'Not due'
        : s === 'clear'
          ? 'Fully paid'
          : 'Not assigned';
  return <Badge tone={PILL[s]}>{text}</Badge>;
}

/**
 * A customer's documents, in one table (the mockup of 5 Nov 2026): every SAP
 * invoice with its due date, what was paid and what is left, then any order
 * not invoiced yet. Before the SAP sync writes `SAP Invoice` rows, the month's
 * invoiced order lines stand in, with paid and balance not known yet.
 */
function InvoiceTable({
  r,
  invoices,
  m,
  month,
}: {
  r: RepCustomerRow;
  invoices: SapInvoice[];
  m: (v: number) => string;
  month: string;
}) {
  const today = new Date().toISOString().slice(0, 10);
  const daysLate = (due: string) => Math.max(0, Math.round((Date.parse(today) - Date.parse(due)) / 86_400_000));
  const fromSap = invoices.length > 0;
  const sap = [...invoices].sort((a, b) => a.postingDate.localeCompare(b.postingDate));
  const lines = [...r.invoices].sort((a, b) => a.date.localeCompare(b.date));
  const invoicedOrders = new Set(r.invoices.flatMap((i) => i.orders));
  const pending = r.orders.filter((o) => !o.sapInvoice && !invoicedOrders.has(o.id));

  if (!fromSap && lines.length === 0 && pending.length === 0) {
    return (
      <div className="tiny dim" style={{ padding: '10px 0' }}>
        No invoices or orders in {month}.
      </div>
    );
  }

  return (
    <table className="table">
      <thead>
        <tr>
          <th>Document</th>
          <th>Date</th>
          <th>Due date</th>
          <th className="right">Amount</th>
          <th className="right">Paid</th>
          <th className="right">Balance</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        {fromSap
          ? sap.map((i) => {
              const paid = i.balance <= 1;
              const late = !paid && i.dueDate && i.dueDate < today ? daysLate(i.dueDate) : 0;
              return (
                <tr key={`${i.company}-${i.invoiceNo}`}>
                  <td>{i.invoiceNo}</td>
                  <td>{shortDate(i.postingDate)}</td>
                  <td>{i.dueDate ? shortDate(i.dueDate) : '—'}</td>
                  <td className="right">{m(i.total)}</td>
                  <td className="right tg-ok">{m(i.paid)}</td>
                  <td className="right">{m(Math.max(0, i.balance))}</td>
                  <td>
                    {paid ? (
                      <Badge tone="ok">Paid</Badge>
                    ) : late ? (
                      <Badge tone="danger">Overdue · {late}d</Badge>
                    ) : (
                      <Badge tone="warn">Not due</Badge>
                    )}
                  </td>
                </tr>
              );
            })
          : lines.map((i) => (
              <tr key={`inv-${i.invoice}`}>
                <td>{i.invoice}</td>
                <td>{shortDate(i.date)}</td>
                <td>—</td>
                <td className="right">{m(i.amount)}</td>
                <td className="right dim">—</td>
                <td className="right dim">—</td>
                <td>
                  <Badge tone="info" title="Paid and balance arrive with the SAP invoice sync">
                    Invoiced
                  </Badge>
                </td>
              </tr>
            ))}
        {pending.map((o) => (
          <tr key={`so-${o.id}`}>
            <td>{o.sapSalesOrder ? `SO ${o.sapSalesOrder}` : <span className="dim">Not in SAP yet</span>}</td>
            <td>{shortDate(o.placedOn)}</td>
            <td>—</td>
            <td className="right">{m(o.netTotal)}</td>
            <td className="right tg-ok">{m(0)}</td>
            <td className="right">—</td>
            <td>
              <Badge tone="neutral">Not invoiced</Badge>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
