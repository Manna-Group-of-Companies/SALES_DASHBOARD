/**
 * Team Targets — a sales manager's monthly targets for their reps, and what
 * SAP has invoiced against each (3 Nov 2026).
 *
 * Achieved means invoiced: the figures come from the `manna_sales_targets`
 * Server Script, which counts only order lines SAP has raised an A/R invoice
 * for, dated in the month — see `domain/salesTarget.ts`. Achieved and its
 * percentage always show, 0 until something is invoiced; the list of invoices
 * opens only once there are some.
 *
 * Clicking a rep opens their customers (RepCustomersView, 5 Nov 2026): what
 * each ordered and SAP invoiced in the month, and what each owes today. The
 * rep is kept in the URL (`?rep=`) so Back and a reload land on the same rep.
 *
 * The GM sees every team here, read-only (5 Nov 2026): `manna_sales_targets`
 * gives the GM all teams and an empty `can_edit`, so no Set target / Edit
 * button shows and the guard would refuse one anyway. A team filter narrows it.
 *
 * Each rep's row also shows the month's orders and their value, what the rep's
 * customers have paid against their SAP invoices (once the SAP invoice sync
 * writes `SAP Invoice`; "—" until then), and a payment status.
 *
 * The phone's twin is app/lib/screens/manager/manager_targets_screen.dart.
 * The same targets show on both, and on the rep's own home screen.
 */

import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import {
  getMonthOrdersByRep,
  getSapInvoices,
  getTargetMonth,
  upsertTarget,
  type RepMonthTotals,
} from '@/api/salesTargets';
import { Api } from '@/api/client';
import {
  TARGET_MONTHS,
  achieved,
  formatMoney,
  formatTarget,
  fraction,
  hasInvoices,
  hasTarget,
  type TargetMonth,
  type TargetRow,
  type TargetUnit,
} from '@/domain/salesTarget';
import {
  Alert,
  Badge,
  Button,
  Card,
  Empty,
  Field,
  Icon,
  Input,
  Meter,
  Modal,
  Segmented,
  Select,
  type BadgeTone,
} from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import { RepCustomersView } from './RepCustomersView';
import './targets.css';

const errText = (e: unknown, fallback: string) => (e instanceof Error && e.message ? e.message : fallback);
const pad = (n: number) => String(n).padStart(2, '0');

/** A rep's payment status, from what their customers owe (SAP). */
function payStatus(r: TargetRow): { text: string; tone: BadgeTone } {
  // A rupee left on an invoice is rounding (credit.ts OVERDUE_TOLERANCE).
  if (r.overdue > 1) return { text: 'Overdue', tone: 'danger' };
  if (r.outstanding > 1) return { text: 'Not due', tone: 'warn' };
  return { text: 'Fully paid', tone: 'ok' };
}

export function TargetsPage() {
  const now = new Date();
  // Months counted from year 0, so stepping across December is arithmetic.
  const [ym, setYm] = useState(now.getFullYear() * 12 + now.getMonth());
  const year = Math.floor(ym / 12);
  const month = TARGET_MONTHS[ym % 12];
  // Next month may be planned ahead; no further than that.
  const maxYm = now.getFullYear() * 12 + now.getMonth() + 1;

  const [data, setData] = useState<TargetMonth | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [editing, setEditing] = useState<TargetRow | null>(null);
  const [open, setOpen] = useState<TargetRow | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [params, setParams] = useSearchParams();
  const repName = params.get('rep');

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    getTargetMonth(month, year)
      .then((m) => {
        if (live) setData(m);
      })
      .catch((e: unknown) => {
        if (!live) return;
        setData(null);
        setError(errText(e, 'Could not read the targets.'));
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [month, year, tick]);

  const [totals, setTotals] = useState<Map<string, RepMonthTotals>>(new Map());
  /** Paid per rep, from SAP invoices; null while SAP Invoice is not there. */
  const [paid, setPaid] = useState<Map<string, number> | null>(null);
  const [team, setTeam] = useState('');

  const monthIndex = ym % 12;
  useEffect(() => {
    if (!data?.rows.length) return;
    let live = true;
    const from = `${year}-${pad(monthIndex + 1)}-01`;
    const to = `${year}-${pad(monthIndex + 1)}-${pad(new Date(year, monthIndex + 1, 0).getDate())}`;
    const reps = data.rows.map((r) => r.salesPerson);
    getMonthOrdersByRep(from, to)
      .then((t) => live && setTotals(t))
      .catch(() => live && setTotals(new Map()));
    // Paid: each rep's assigned customers' SAP invoices. Best-effort.
    Api.sales
      .listCustomers(reps)
      .then(async (cs) => {
        const inv = await getSapInvoices(cs.map((c) => c.id));
        if (!live) return;
        if (!inv.length) {
          setPaid(null);
          return;
        }
        const repOf = new Map(cs.map((c) => [c.id, c.assignedRep ?? '']));
        const by = new Map<string, number>();
        for (const i of inv) {
          const rep = repOf.get(i.customer);
          if (rep) by.set(rep, (by.get(rep) ?? 0) + i.paid);
        }
        setPaid(by);
      })
      .catch(() => live && setPaid(null));
    return () => {
      live = false;
    };
  }, [data, year, monthIndex]);

  const allRows = data?.rows ?? [];
  const teams = useMemo(() => [...new Set(allRows.map((r) => r.team).filter(Boolean))].sort(), [allRows]);
  const rows = team ? allRows.filter((r) => r.team === team) : allRows;
  const canEdit = new Set(data?.canEdit ?? []);
  const readOnly = Boolean(data?.isGM) && canEdit.size === 0;
  const selected = repName ? allRows.find((r) => r.salesPerson === repName) : undefined;


  const openRep = (r: TargetRow) => {
    setDone(null);
    setParams((p) => {
      const n = new URLSearchParams(p);
      n.set('rep', r.salesPerson);
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

  const modals = (
    <>
      {editing && (
        <TargetModal
          row={editing}
          month={month}
          year={year}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setDone(`Target set for ${editing.salesPerson}, ${month} ${year}`);
            setEditing(null);
            setTick((t) => t + 1);
          }}
        />
      )}
      {open && <InvoicesModal row={open} title={`${open.salesPerson} · ${month} ${year}`} onClose={() => setOpen(null)} />}
    </>
  );

  if (selected) {
    return (
      <div>
        {done && (
          <div style={{ marginBottom: 14 }}>
            <Alert tone="ok" title={done} />
          </div>
        )}
        <RepCustomersView
          row={selected}
          month={month}
          monthIndex={monthIndex}
          year={year}
          canEdit={canEdit.has(selected.salesPerson)}
          onBack={closeRep}
          onEdit={() => {
            setDone(null);
            setEditing(selected);
          }}
          onShowInvoices={() => setOpen(selected)}
        />
        {modals}
      </div>
    );
  }

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">
            {data?.isGM ? 'Targets — all teams' : 'Team Targets'}{' '}
            {readOnly && <Badge tone="neutral">Read only</Badge>}
          </div>
          <div className="tiny dim">
            Achieved = SAP invoices dated in the month, before GST. Approved orders not yet invoiced do not count.
            <br />
            Outstanding = what the rep's customers owe today, from SAP.
          </div>
        </div>
        <div className="tg-month">
          <Button size="sm" onClick={() => setYm(ym - 1)} aria-label="Previous month">
            <Icon name="chevronLeft" size={14} />
          </Button>
          <strong>
            {month} {year}
          </strong>
          <Button size="sm" onClick={() => setYm(ym + 1)} disabled={ym >= maxYm} aria-label="Next month">
            <Icon name="chevronRight" size={14} />
          </Button>
        </div>
        {data?.isGM && teams.length > 1 && (
          <div style={{ width: 180 }}>
            <Select value={team} onChange={(e) => setTeam(e.target.value)} aria-label="Team">
              <option value="">All teams</option>
              {teams.map((t) => (
                <option key={t} value={t}>
                  {t} team
                </option>
              ))}
            </Select>
          </div>
        )}
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not load the targets">
          {error}
        </Alert>
      )}
      {done && !error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="ok" title={done} />
        </div>
      )}

      {!loading && !error && rows.length === 0 && <Empty icon="—" title="No reps in your team were found" />}
      {!loading && !error && repName && rows.length > 0 && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="warn" title={`${repName} is not in this list`} />
        </div>
      )}

      {rows.length > 0 && (
        <Card flush>
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Rep</th>
                  <th className="right">Target</th>
                  <th className="right">Orders</th>
                  <th className="right">Ordered</th>
                  <th className="right">Achieved (invoiced)</th>
                  <th style={{ minWidth: 150 }}>Progress</th>
                  <th className="right">Paid</th>
                  <th className="right">Outstanding</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const f = fraction(r);
                  return (
                    <tr
                      key={r.salesPerson}
                      className="tg-rep-row"
                      tabIndex={0}
                      onClick={() => openRep(r)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter') openRep(r);
                      }}
                      title={`See ${r.salesPerson}'s customers`}
                    >
                      <td>
                        <div className="tg-rep-name">{r.salesPerson}</div>
                        <div className="tiny dim">
                          {data?.isGM ? `${r.team} team · ` : ''}View customers
                        </div>
                      </td>
                      <td className="right">
                        {hasTarget(r) ? formatTarget(r, r.targetAmount) : <span className="dim">Not set</span>}
                      </td>
                      <td className="right">
                        {totals.get(r.salesPerson)?.orders ?? <span className="dim">0</span>}
                      </td>
                      <td className="right" style={{ whiteSpace: 'nowrap' }}>
                        {totals.get(r.salesPerson)?.ordered ? (
                          formatMoney(r, totals.get(r.salesPerson)!.ordered)
                        ) : (
                          <span className="dim">—</span>
                        )}
                      </td>
                      <td className="right">
                        {hasInvoices(r) ? (
                          <>
                            <div>{formatTarget(r, achieved(r))}</div>
                            <div className="tiny dim">{invoiceCount(r)}</div>
                          </>
                        ) : (
                          <>
                            <div>{formatTarget(r, 0)}</div>
                            <div className="tiny dim">No invoices yet</div>
                          </>
                        )}
                      </td>
                      <td>
                        {hasTarget(r) ? (
                          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                            <div className="grow">
                              <Meter value={f} tone={f >= 1 ? 'ok' : 'accent'} label={`${r.salesPerson} progress`} />
                            </div>
                            {f >= 1 ? (
                              <Badge tone="ok">{Math.round(f * 100)}%</Badge>
                            ) : (
                              <span className="tiny">{Math.round(f * 100)}%</span>
                            )}
                          </div>
                        ) : (
                          <span className="tiny dim">—</span>
                        )}
                      </td>
                      <td className="right tg-ok" style={{ fontWeight: 600, whiteSpace: 'nowrap' }}>
                        {paid && paid.has(r.salesPerson) ? (
                          formatMoney(r, paid.get(r.salesPerson)!)
                        ) : (
                          <span className="dim">—</span>
                        )}
                      </td>
                      <td className="right">
                        <div>{formatMoney(r, r.outstanding)}</div>
                        {r.overdue > 0 && (
                          <div className="tiny" style={{ color: 'var(--danger)' }}>
                            {formatMoney(r, r.overdue)} overdue
                          </div>
                        )}
                      </td>
                      <td>
                        <Badge tone={payStatus(r).tone}>{payStatus(r).text}</Badge>
                      </td>
                      <td className="right" style={{ whiteSpace: 'nowrap' }}>
                        {canEdit.has(r.salesPerson) && (
                          <Button
                            size="sm"
                            onClick={(e) => {
                              e.stopPropagation();
                              setDone(null);
                              setEditing(r);
                            }}
                          >
                            {hasTarget(r) ? 'Edit' : 'Set target'}
                          </Button>
                        )}{' '}
                        <span className="tg-chev">
                          <Icon name="chevronRight" size={18} />
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </Card>
      )}
      {rows.length > 0 && (
        <div className="tg-hint">
          <Icon name="info" size={14} />
          Click a rep to see their customers: what each ordered and was invoiced this month, and what each owes.
        </div>
      )}

      {modals}
    </div>
  );
}

function invoiceCount(r: TargetRow): string {
  const n = new Set(r.lines.map((l) => l.invoice)).size;
  return `${n} invoice${n === 1 ? '' : 's'}`;
}

function TargetModal({
  row,
  month,
  year,
  onClose,
  onSaved,
}: {
  row: TargetRow;
  month: string;
  year: number;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [unit, setUnit] = useState<TargetUnit>(row.unit);
  const [value, setValue] = useState(hasTarget(row) ? String(row.targetAmount) : '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const amount = Number(value.replace(/,/g, ''));
  const valid = value.trim() !== '' && Number.isFinite(amount) && amount >= 0;

  const save = async () => {
    if (!valid) return;
    setBusy(true);
    setError(null);
    try {
      await upsertTarget({ salesPerson: row.salesPerson, month, year, amount, unit });
      onSaved();
    } catch (e) {
      setError(errText(e, 'Could not save the target.'));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      title={`Target — ${row.salesPerson}, ${month} ${year}`}
      onClose={onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" onClick={save} disabled={!valid || busy}>
            {busy ? 'Saving…' : 'Save'}
          </Button>
        </>
      }
    >
      {error && (
        <div style={{ marginBottom: 12 }}>
          <Alert tone="danger" title="Not saved">
            {error}
          </Alert>
        </div>
      )}
      <div style={{ marginBottom: 12 }}>
        <Segmented<TargetUnit>
          options={[
            { value: 'Currency', label: row.currency },
            { value: 'Tonnes', label: 'Tonnes' },
          ]}
          value={unit}
          onChange={setUnit}
        />
      </div>
      <Field
        label={unit === 'Currency' ? `Monthly target (${row.currency})` : 'Monthly target (tonnes)'}
        hint="Measured against SAP invoices dated in the month."
        htmlFor="target-amount"
      >
        <Input
          id="target-amount"
          numeric
          inputMode="decimal"
          value={value}
          invalid={value !== '' && !valid}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') void save();
          }}
        />
      </Field>
    </Modal>
  );
}

function InvoicesModal({ row, title, onClose }: { row: TargetRow; title: string; onClose: () => void }) {
  const lines = [...row.lines].reverse();
  const money = (v: number) => `${row.currency} ${Math.round(v).toLocaleString(row.currency === 'AED' ? 'en-AE' : 'en-IN')}`;
  return (
    <Modal title={title} onClose={onClose} width="wide">
      <div style={{ marginBottom: 10 }}>
        <strong>Total invoiced: {formatTarget(row, achieved(row))}</strong>
        {row.unit === 'Tonnes' && <span className="dim"> ({money(row.invoicedAmount)})</span>}
      </div>
      <div className="scroll-x">
        <table className="table">
          <thead>
            <tr>
              <th>Invoice</th>
              <th>Date</th>
              <th>Customer</th>
              <th>Item</th>
              <th className="right">Kg</th>
              <th className="right">Amount</th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l, i) => (
              <tr key={`${l.order}-${l.invoice}-${i}`}>
                <td>{l.invoice}</td>
                <td>{l.invoiceDate}</td>
                <td>
                  <div>{l.customerName}</div>
                  <div className="tiny dim">{l.order}</div>
                </td>
                <td>{l.itemName}</td>
                <td className="right">{l.kg.toFixed(1)}</td>
                <td className="right">{money(l.amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Modal>
  );
}
