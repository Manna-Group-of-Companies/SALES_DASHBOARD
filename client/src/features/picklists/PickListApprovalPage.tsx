/**
 * Pick Lists for the Production Manager — approve what the reps picked
 * (5 Nov 2026).
 *
 * A rep makes a pick list on the phone from a manager-approved order: the
 * products Hi-Tech has in stock now, the rest to be picked later on another
 * list. Each list waits as Pending until a production manager approves it
 * here; the rep's phone then shows it as approved.
 *
 * Two screens (asked 6 Nov 2026):
 *   - the employees who ordered, as tabs - name, lists, what is still waiting;
 *   - a click on one opens THAT employee's screen: everything they picked, in
 *     rows and columns - when, which list, which order, each product, the
 *     quantities, and whether production approved it - with Approve there.
 * The employee is kept in the URL (`?rep=`), so Back returns to the tabs.
 *
 * As on the production queue, an order is shown by its SAP number — never the
 * customer (the user, 26 Sep 2026). `manna_pick_lists` blanks the customer
 * for a production manager, so it is not merely hidden here.
 *
 * The sales manager gets the same page read-only (`readOnly`, 5 Nov 2026) at
 * /pick-lists: their own team's lists, with the customer (the server sends it
 * to them), and no Approve.
 *
 * The Approve button is convenience; `manna_pick_list_approve` is what
 * refuses anyone who is not a production manager, a cancelled list, or a
 * second approval.
 */

import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { approvePickList, listPickLists, type PickList } from '@/api/pickLists';
import { UNITS } from '@/api/endpoints';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Icon, Input, Select, Skeleton } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import './picklists.css';

type Show = 'pending' | 'approved' | 'all';
type Range = 'all' | 'today' | 'yesterday' | '7d' | 'month' | 'custom';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
/** `2026-11-05 14:02:29` → `05 Nov 2026`. */
function day(s: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s);
  return m ? `${m[3]} ${MONTHS[Number(m[2]) - 1]} ${m[1]}` : s;
}
/** `2026-11-05 14:02:29` → `14:02`. */
const time = (s: string) => s.slice(11, 16);
const qty = (v: number) => (Number.isInteger(v) ? String(v) : v.toFixed(2));
/** `1 roll`, `3 rolls`, `50 Kg`. */
const amount = (v: number, unit: string) => `${qty(v)} ${v === 1 && unit === 'rolls' ? 'roll' : unit}`.trim();
const initials = (name: string) =>
  name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]!.toUpperCase())
    .join('') || '—';

const isPending = (l: PickList) => l.status === 'Submitted' && l.approvalStatus !== 'Approved';
const isApproved = (l: PickList) => l.status === 'Submitted' && l.approvalStatus === 'Approved';

/** yyyy-mm-dd in the browser's own day. */
function iso(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** The [from, to] days (inclusive, yyyy-mm-dd) a range means; '' is open. */
function bounds(range: Range, from: string, to: string): [string, string] {
  const now = new Date();
  const today = iso(now);
  const back = (n: number) => iso(new Date(now.getFullYear(), now.getMonth(), now.getDate() - n));
  switch (range) {
    case 'today':
      return [today, today];
    case 'yesterday':
      return [back(1), back(1)];
    case '7d':
      return [back(6), today];
    case 'month':
      return [iso(new Date(now.getFullYear(), now.getMonth(), 1)), today];
    case 'custom':
      return [from, to];
    default:
      return ['', ''];
  }
}

interface RepRow {
  rep: string;
  /** Newest first, as the server sends them. */
  lists: PickList[];
  orders: number;
  pending: number;
  approved: number;
  lastPicked: string;
  /** Product lines picked on live lists. */
  products: number;
  /** Picked per unit, e.g. { rolls: 12, Kg: 50 }. */
  pickedByUnit: Record<string, number>;
}

function buildRows(lists: PickList[]): RepRow[] {
  const by = new Map<string, RepRow>();
  for (const l of lists) {
    const k = l.salesPerson || '';
    let r = by.get(k);
    if (!r) {
      r = { rep: k, lists: [], orders: 0, pending: 0, approved: 0, lastPicked: l.pickedOn, products: 0, pickedByUnit: {} };
      by.set(k, r);
    }
    r.lists.push(l);
    if (isPending(l)) r.pending += 1;
    if (isApproved(l)) r.approved += 1;
    if (l.pickedOn > r.lastPicked) r.lastPicked = l.pickedOn;
    if (l.status === 'Submitted') {
      for (const i of l.items) {
        r.products += 1;
        r.pickedByUnit[i.unit || ''] = (r.pickedByUnit[i.unit || ''] ?? 0) + i.pickedQty;
      }
    }
  }
  for (const r of by.values()) r.orders = new Set(r.lists.map((l) => l.salesOrder)).size;
  // Something waiting first, then the most recently picked.
  return [...by.values()].sort(
    (a, b) => Number(b.pending > 0) - Number(a.pending > 0) || b.lastPicked.localeCompare(a.lastPicked),
  );
}

const units = (u: Record<string, number>) =>
  Object.entries(u)
    .map(([k, v]) => amount(v, k))
    .join(' · ');

export function PickListApprovalPage({ readOnly = false }: { readOnly?: boolean }) {
  const user = useAppSelector(selectUser);
  const [params, setParams] = useSearchParams();
  /** The employee whose screen is open, or null for the employees' tabs. */
  const rep = params.get('rep');
  const [lists, setLists] = useState<PickList[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  // Production opens on what is waiting for them; the sales manager on everything.
  const [show, setShow] = useState<Show>(readOnly ? 'all' : 'pending');
  // Production: their own unit by default, as on the production queue.
  const [unit, setUnit] = useState<string>(readOnly ? '' : (user?.productionUnit ?? ''));
  const [range, setRange] = useState<Range>('all');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [query, setQuery] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    listPickLists()
      .then((l) => {
        if (live) setLists(l);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error && e.message ? e.message : 'Could not read the pick lists.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick]);

  const [lo, hi] = bounds(range, from, to);

  /** Unit, dates and search narrow the lists; the status tabs then pick among them. */
  const inScope = useMemo(() => {
    const q = query.trim().toLowerCase();
    return lists.filter((l) => {
      if (unit && l.company !== unit) return false;
      const d = l.pickedOn.slice(0, 10);
      if (lo && d < lo) return false;
      if (hi && d > hi) return false;
      if (!q) return true;
      return [l.name, l.salesOrder, l.sapSalesOrder, l.salesPerson, l.customerName, ...l.items.map((i) => i.itemName)]
        .join(' ')
        .toLowerCase()
        .includes(q);
    });
  }, [lists, unit, lo, hi, query]);

  /** On an employee's screen the counts are theirs; on the tabs, everybody's. */
  const scoped = useMemo(() => (rep == null ? inScope : inScope.filter((l) => (l.salesPerson || '') === rep)), [inScope, rep]);
  const counts = useMemo(
    () => ({
      pending: scoped.filter(isPending).length,
      approved: scoped.filter(isApproved).length,
      all: scoped.length,
    }),
    [scoped],
  );

  /** What the status tab leaves. */
  const pick = (ls: PickList[]) =>
    show === 'pending' ? ls.filter(isPending) : show === 'approved' ? ls.filter(isApproved) : ls;
  const employees = useMemo(() => buildRows(pick(inScope)), [inScope, show]); // eslint-disable-line react-hooks/exhaustive-deps
  const repLists = useMemo(() => pick(scoped), [scoped, show]); // eslint-disable-line react-hooks/exhaustive-deps
  /** The open employee's figures over every status, for the header. */
  const repAll = useMemo(() => (rep == null ? null : buildRows(scoped)[0] ?? null), [scoped, rep]);

  const openRep = (r: string) => {
    setParams((p) => {
      const n = new URLSearchParams(p);
      n.set('rep', r);
      return n;
    });
    window.scrollTo(0, 0);
  };
  const closeRep = () =>
    setParams((p) => {
      const n = new URLSearchParams(p);
      n.delete('rep');
      return n;
    });

  async function approve(l: PickList) {
    if (!window.confirm(`Approve pick list ${l.name} (${l.items.length} product${l.items.length === 1 ? '' : 's'})?`)) {
      return;
    }
    setBusy(l.name);
    setActionError(null);
    try {
      await approvePickList(l.name);
    } catch (e: unknown) {
      setActionError(e instanceof Error && e.message ? e.message : `Could not approve ${l.name}.`);
    } finally {
      setBusy(null);
      // Re-read either way: another manager may have approved it meanwhile.
      setTick((t) => t + 1);
    }
  }

  if (!user) return null;

  const TABS: { k: Show; label: string; n: number }[] = [
    { k: 'pending', label: readOnly ? 'Awaiting production' : 'Awaiting approval', n: counts.pending },
    { k: 'approved', label: 'Approved', n: counts.approved },
    { k: 'all', label: 'All', n: counts.all },
  ];

  const toolbar = (
    <div className="pl-tools">
      <div className="pl-tabs" role="tablist" aria-label="Approval">
        {TABS.map((t) => (
          <button
            key={t.k}
            type="button"
            role="tab"
            aria-selected={show === t.k}
            className={`pl-tab${show === t.k ? ' is-on' : ''}`}
            onClick={() => setShow(t.k)}
          >
            {t.label}
            <b>{t.n}</b>
          </button>
        ))}
      </div>
      <div className="pl-tools__right">
        <Select value={range} onChange={(e) => setRange(e.target.value as Range)} aria-label="Picked on">
          <option value="all">All dates</option>
          <option value="today">Today</option>
          <option value="yesterday">Yesterday</option>
          <option value="7d">Last 7 days</option>
          <option value="month">This month</option>
          <option value="custom">Choose dates…</option>
        </Select>
        {range === 'custom' && (
          <span className="pl-dates">
            <Input type="date" compact value={from} max={to || undefined} onChange={(e) => setFrom(e.target.value)} aria-label="From" />
            <span className="dim">to</span>
            <Input type="date" compact value={to} min={from || undefined} onChange={(e) => setTo(e.target.value)} aria-label="To" />
          </span>
        )}
        <Select value={unit} onChange={(e) => setUnit(e.target.value)} aria-label="Unit">
          <option value="">All units</option>
          {UNITS.map((u) => (
            <option key={u} value={u}>
              {u}
            </option>
          ))}
        </Select>
        <label className="pl-search">
          <Icon name="search" size={15} />
          <input
            placeholder={rep == null ? 'Search employee, order, product' : 'Search order, pick list, product'}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            aria-label="Search pick lists"
          />
        </label>
      </div>
    </div>
  );

  return (
    <div>
      {rep == null ? (
        <div className="page-head">
          <div className="grow">
            <div className="page-head__title">Pick Lists</div>
            <div className="tiny dim">
              {readOnly
                ? 'Your reps who ordered and picked from Hi-Tech stock. Click one to see their orders, pick lists and what production approved.'
                : 'The employees who ordered and picked from Hi-Tech stock. Click one to see everything they picked, and approve it there.'}
            </div>
          </div>
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
        </div>
      ) : (
        <>
          <nav className="pl-crumb" aria-label="Breadcrumb">
            <button type="button" onClick={closeRep}>
              <Icon name="chevronLeft" size={14} /> All employees
            </button>
          </nav>
          <div className="page-head">
            <span className="pl-avatar pl-avatar--lg" aria-hidden>
              {initials(rep || '—')}
            </span>
            <div className="grow" style={{ minWidth: 0 }}>
              <div className="page-head__title">{rep || 'No rep'}</div>
              <div className="tiny dim">
                {repAll
                  ? `${repAll.orders} order${repAll.orders === 1 ? '' : 's'} · ${repAll.lists.length} pick list${repAll.lists.length === 1 ? '' : 's'} · ${repAll.products} product line${repAll.products === 1 ? '' : 's'} · ${units(repAll.pickedByUnit) || '—'} · ${repAll.approved} approved, ${repAll.pending} waiting`
                  : 'Nothing in these filters.'}
              </div>
            </div>
            <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
          </div>
        </>
      )}

      {error && (
        <Alert tone="danger" title="Could not load the pick lists">
          {error}
        </Alert>
      )}
      {actionError && (
        <Alert tone="danger" title="Not approved">
          {actionError}
        </Alert>
      )}

      <Card flush>
        {toolbar}
        {rep == null ? (
          <EmployeeTabs
            rows={employees}
            loading={loading && lists.length === 0}
            empty={
              lists.length === 0
                ? 'No pick lists yet.'
                : show === 'pending' && inScope.length > 0
                  ? 'Nothing waiting for approval in these dates.'
                  : 'No pick lists match.'
            }
            onOpen={openRep}
          />
        ) : (
          <ListsTable
            lists={repLists}
            loading={loading && lists.length === 0}
            empty={
              scoped.length === 0
                ? `${rep || 'This employee'} has no pick lists in these filters.`
                : show === 'pending'
                  ? 'Nothing of theirs is waiting for approval.'
                  : 'No pick lists match.'
            }
            busy={busy}
            onApprove={approve}
            readOnly={readOnly}
          />
        )}
      </Card>
    </div>
  );
}

/** The employees who ordered, one tab each: who, how much, and what is still waiting. */
function EmployeeTabs({
  rows,
  loading,
  empty,
  onOpen,
}: {
  rows: RepRow[];
  loading: boolean;
  empty: string;
  onOpen: (rep: string) => void;
}) {
  if (loading) {
    return (
      <div style={{ padding: 16 }}>
        <Skeleton height={120} />
      </div>
    );
  }
  if (!rows.length) return <div className="pl-empty">{empty}</div>;
  return (
    <div className="pl-emps">
      {rows.map((r) => (
        <button key={r.rep || '—'} type="button" className="pl-emp" onClick={() => onOpen(r.rep)}>
          <span className="pl-avatar" aria-hidden>
            {initials(r.rep || '—')}
          </span>
          <span className="pl-emp__body">
            <span className="pl-emp__name">{r.rep || 'No rep'}</span>
            <span className="tiny dim">
              {r.orders} order{r.orders === 1 ? '' : 's'} · {r.lists.length} pick list{r.lists.length === 1 ? '' : 's'} ·{' '}
              {units(r.pickedByUnit) || '—'}
            </span>
            <span className="tiny dim">
              Last picked {day(r.lastPicked)}, {time(r.lastPicked)}
            </span>
          </span>
          <span className="pl-emp__status">
            {r.pending > 0 ? (
              <Badge tone="warn">{r.pending} waiting</Badge>
            ) : r.approved > 0 ? (
              <Badge tone="ok">Approved</Badge>
            ) : (
              <Badge tone="neutral">Cancelled</Badge>
            )}
            <Icon name="chevronRight" size={16} />
          </span>
        </button>
      ))}
    </div>
  );
}

/**
 * One employee's pick lists in rows and columns: a line per product, newest list
 * first. The list's own cells - when, which list, which order, status - span its
 * products, so a list reads as one block and Approve sits once beside it.
 */
function ListsTable({
  lists,
  loading,
  empty,
  busy,
  onApprove,
  readOnly,
}: {
  lists: PickList[];
  loading: boolean;
  empty: string;
  busy: string | null;
  onApprove: (l: PickList) => void;
  readOnly: boolean;
}) {
  return (
    <div className="scroll-x">
      <table className="table pl-grid">
        <thead>
          <tr>
            <th>Picked at</th>
            <th>Pick list</th>
            <th>Order</th>
            <th>Product</th>
            <th className="right">Picked</th>
            <th className="right">Ordered</th>
            <th className="right">Hi-Tech stock then</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          {loading && (
            <tr>
              <td colSpan={8}>
                <Skeleton height={120} />
              </td>
            </tr>
          )}
          {!loading && lists.length === 0 && (
            <tr>
              <td colSpan={8} className="pl-empty">
                {empty}
              </td>
            </tr>
          )}
          {!loading &&
            lists.map((l) => {
              const span = Math.max(1, l.items.length);
              const items = l.items.length ? l.items : [null];
              return items.map((i, n) => (
                <tr key={`${l.name}-${i?.salesOrderItem ?? n}`} className={n === 0 ? 'pl-first' : undefined}>
                  {n === 0 && (
                    <>
                      <td rowSpan={span}>
                        <b>{time(l.pickedOn)}</b>
                        <div className="tiny dim">{day(l.pickedOn)}</div>
                      </td>
                      <td rowSpan={span} className="pl-doc mono">
                        {l.name}
                      </td>
                      <td rowSpan={span}>
                        {l.sapSalesOrder ? (
                          <>
                            SAP <span className="mono">{l.sapSalesOrder}</span>
                          </>
                        ) : (
                          <span className="dim">not in SAP yet</span>
                        )}
                        <div className="tiny dim mono">{l.salesOrder}</div>
                        {l.customerName && <div className="tiny">{l.customerName}</div>}
                      </td>
                    </>
                  )}
                  <td>{i?.itemName ?? <span className="dim">No products</span>}</td>
                  <td className="right">{i && <strong>{amount(i.pickedQty, i.unit)}</strong>}</td>
                  <td className="right">{i && qty(i.orderedQty)}</td>
                  <td className="right dim">{i && qty(i.availableQty)}</td>
                  {n === 0 && (
                    <td rowSpan={span}>
                      <div className="pl-status">
                        {l.status !== 'Submitted' ? (
                          <Badge tone="danger">Cancelled</Badge>
                        ) : l.approvalStatus === 'Approved' ? (
                          <>
                            <Badge tone="ok">Approved</Badge>
                            <span className="tiny dim">
                              {l.approvedByName}
                              {l.approvedOn ? ` · ${day(l.approvedOn)} ${time(l.approvedOn)}` : ''}
                            </span>
                          </>
                        ) : readOnly ? (
                          <Badge tone="warn">Awaiting production</Badge>
                        ) : (
                          <>
                            <Badge tone="warn">Awaiting approval</Badge>
                            <Button
                              variant="primary"
                              size="sm"
                              loading={busy === l.name}
                              disabled={busy !== null}
                              onClick={() => onApprove(l)}
                            >
                              Approve
                            </Button>
                          </>
                        )}
                      </div>
                    </td>
                  )}
                </tr>
              ));
            })}
        </tbody>
      </table>
    </div>
  );
}
