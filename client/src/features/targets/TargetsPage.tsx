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
 * The phone's twin is app/lib/screens/manager/manager_targets_screen.dart.
 * The same targets show on both, and on the rep's own home screen.
 */

import { useEffect, useState } from 'react';
import { getTargetMonth, upsertTarget } from '@/api/salesTargets';
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
import { Alert, Badge, Button, Card, Empty, Field, Input, Meter, Modal, Segmented } from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';

const errText = (e: unknown, fallback: string) => (e instanceof Error && e.message ? e.message : fallback);

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

  const rows = data?.rows ?? [];
  const canEdit = new Set(data?.canEdit ?? []);

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Team Targets</div>
          <div className="tiny dim">
            Achieved = SAP invoices dated in the month, before GST. Approved orders not yet invoiced do not count.
            <br />
            Outstanding = what the rep's customers owe today, from SAP.
          </div>
        </div>
        <Button size="sm" onClick={() => setYm(ym - 1)} aria-label="Previous month">
          ‹
        </Button>
        <strong style={{ minWidth: 80, textAlign: 'center' }}>
          {month} {year}
        </strong>
        <Button size="sm" onClick={() => setYm(ym + 1)} disabled={ym >= maxYm} aria-label="Next month">
          ›
        </Button>
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

      {rows.length > 0 && (
        <Card flush>
          <div className="scroll-x">
            <table className="table">
              <thead>
                <tr>
                  <th>Rep</th>
                  <th className="right">Target</th>
                  <th className="right">Achieved (invoiced)</th>
                  <th style={{ minWidth: 180 }}>Progress</th>
                  <th className="right">Outstanding</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const f = fraction(r);
                  return (
                    <tr key={r.salesPerson}>
                      <td>
                        <div>{r.salesPerson}</div>
                        {data?.isGM && <div className="tiny dim">{r.team} team</div>}
                      </td>
                      <td className="right">
                        {hasTarget(r) ? formatTarget(r, r.targetAmount) : <span className="dim">Not set</span>}
                      </td>
                      <td className="right">
                        {hasInvoices(r) ? (
                          <Button variant="ghost" size="sm" onClick={() => setOpen(r)} title="See the invoices">
                            {formatTarget(r, achieved(r))} ›
                          </Button>
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
                      <td className="right">
                        <div>{formatMoney(r, r.outstanding)}</div>
                        {r.overdue > 0 && (
                          <div className="tiny" style={{ color: 'var(--danger)' }}>
                            {formatMoney(r, r.overdue)} overdue
                          </div>
                        )}
                      </td>
                      <td className="right">
                        {canEdit.has(r.salesPerson) && (
                          <Button
                            size="sm"
                            onClick={() => {
                              setDone(null);
                              setEditing(r);
                            }}
                          >
                            {hasTarget(r) ? 'Edit' : 'Set target'}
                          </Button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </Card>
      )}

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
    </div>
  );
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
