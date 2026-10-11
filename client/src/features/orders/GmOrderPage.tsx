/**
 * The GM's review of an escalated order.
 *
 * Until 24 September 2026 "Open the order" on the GM's queue led to the sales
 * manager's review, which offered the GM "Send to GM" — the GM could look at
 * an escalated order on the dashboard and not approve it. This is the GM's own
 * page, in the order the GM decides in:
 *
 *   1. The credit picture — the reason the order is here.
 *   2. The rep's commitment, and what the sales manager and the GM have said
 *      about it.
 *   3. The lines — the GM may change rates, quantities and items, past a rate
 *      the sales manager locked.
 *   4. The decision. Approving turns the rep's commitment into their credit
 *      condition, reworded if the GM likes — on the rep's phone under
 *      Conditions from that moment — and sends the order BACK to the sales
 *      manager as "Approved by GM". The GM does not push to SAP; the sales
 *      manager does (asked for 24 Sep 2026).
 *
 * Every gate is re-asked by `Api.sales.decideOrder` against the order as
 * stored — see `domain/creditCommitment.ts` and its fixture.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { MinStockLine, OrderDetail, SalesCustomer } from '@/domain/types';
import { creditPicture, EDIT_LOCK, isApproved, PO_STATUS } from '@/domain/orderStatus';
import { agingOf, creditEscalates, escalationOf, pastTermsPhrase } from '@/domain/credit';
import {
  approvalConditionProblem,
  conditionRequiredOnApproval,
  defaultConditionDue,
  orderActions,
} from '@/domain/creditCommitment';
import { poolByItem, positionFor, type Qty } from '@/domain/minimumStock';
import { formatDate } from '@/domain/orderRules';
import { proformaHeld } from '@/domain/proformaRelease';
import { serverNow } from '@/domain/serverClock';
import { Api, type CreditCondition } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Button, Card, Empty, Field, Input, Textarea } from '@/components/ui';
import { money } from '@/components/common/format';
import { RefreshButton } from '@/components/common/RefreshButton';
import { AgingBoxes } from '@/components/common/AgingBoxes';
import { StatusPill } from '@/components/common/StatusPill';
import { CommitmentThread } from './CommitmentThread';
import { CreditBar } from './CreditBar';
import { OrderLinesEditor } from './OrderLinesEditor';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import './orders.css';

function qty(q: Qty): string {
  const parts: string[] = [];
  if (q.rolls) parts.push(`${q.rolls} roll${q.rolls === 1 ? '' : 's'}`);
  if (q.belts) parts.push(`${q.belts} belt${q.belts === 1 ? '' : 's'}`);
  return parts.join(' + ') || '—';
}

export function GmOrderPage() {
  const { orderId = '' } = useParams();
  const user = useAppSelector(selectUser);

  const [order, setOrder] = useState<OrderDetail | null>(null);
  const [customer, setCustomer] = useState<SalesCustomer | null>(null);
  const [pool, setPool] = useState<MinStockLine[]>([]);
  /** Conditions already made from this order — shown once it is approved. */
  const [conditions, setConditions] = useState<CreditCondition[]>([]);
  const [rateEdits, setRateEdits] = useState<Record<string, number>>({});
  const [editing, setEditing] = useState(false);
  const [terms, setTerms] = useState('');
  const [due, setDue] = useState('');
  const [rejecting, setRejecting] = useState(false);
  const [rejectNote, setRejectNote] = useState('');
  /** A note for the sales manager, posted beside the commitment with the approval. */
  const [smNote, setSmNote] = useState('');
  const [threadKey, setThreadKey] = useState(0);
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<{ text: string; tone: 'ok' | 'warn' | 'danger' } | null>(
    null,
  );
  /** Set when the approval landed and the condition did not, so it can be retried. */
  const [unsaved, setUnsaved] = useState<{ text: string; dueDate: string } | null>(null);

  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    setRateEdits({});
    Api.sales
      .getOrder(orderId)
      .then(async (o) => {
        if (!live) return;
        setOrder(o);
        // The rep's words are the GM's starting point — approving as-is is the
        // common case, and retyping them is how they get changed by accident.
        setTerms(o.creditCommitment ?? '');
        setDue(defaultConditionDue(o.creditCommitmentDue, serverNow()));
        const [parties, stock, made] = await Promise.all([
          Api.sales.listCustomers().catch(() => [] as SalesCustomer[]),
          Api.sales.listMinimumStock().catch(() => [] as MinStockLine[]),
          Api.sales.listCreditConditions({ salesOrder: o.id }).catch(() => []),
        ]);
        if (!live) return;
        setCustomer(parties.find((c) => c.id === o.customer) ?? null);
        setPool(stock);
        setConditions(made);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read this order.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [orderId, tick]);

  const customerRow = useMemo(
    () => ({
      custom_outstanding_balance: customer?.outstanding ?? 0,
      custom_credit_limit: customer?.creditLimit ?? 0,
      custom_outstanding_0_30: customer?.outstanding0_30 ?? 0,
      custom_outstanding_30_60: customer?.outstanding30_60 ?? 0,
      custom_outstanding_60_90: customer?.outstanding60_90 ?? 0,
      custom_outstanding_90_plus: customer?.outstanding90Plus ?? 0,
      custom_overdue_past_terms: customer?.overduePastTerms ?? 0,
      custom_payment_terms: customer?.paymentTerms ?? '',
      custom_overdue_days: customer?.overdueDays ?? 0,
    }),
    [customer],
  );

  const stock = useMemo(() => poolByItem(pool), [pool]);

  /** The total with the GM's typed rates, which save on approval. */
  const preview = useMemo(() => {
    if (!order) return { total: 0, changed: false };
    let changed = false;
    let total = 0;
    for (const l of order.lines) {
      const edited = rateEdits[l.id];
      const moved = edited != null && edited > 0 && edited !== l.ratePerKg;
      if (moved) changed = true;
      total += moved ? l.totalWeight * edited : l.amount;
    }
    return { total, changed };
  }, [order, rateEdits]);

  // On the total as the GM is about to approve it, so a rate trimmed here
  // shows its effect on the credit picture before anything is saved.
  const picture = creditPicture({
    // Read the way overCreditLimit reads it: the stored total, or the buckets
    // when SAP left it at zero (26 Sep 2026).
    outstanding: agingOf(customerRow).total,
    creditLimit: customer?.creditLimit,
    orderTotal: preview.total,
  });
  // "Needs the GM": the limit, or overdue past the payment terms (11 Oct 2026).
  const overLimit = order ? creditEscalates(customerRow, preview.total) : false;
  const pastTerms = order ? escalationOf(customerRow, preview.total).pastTerms : false;

  /** Pushed to SAP by the sales manager — finished. */
  const approved = order ? isApproved(order.poStatus) : false;
  /** Approved by this GM and back with the sales manager to push. */
  const gmApproved = (order?.poStatus ?? '').trim() === PO_STATUS.finalApproval;
  const rejected = (order?.poStatus ?? '').trim() === PO_STATUS.rejected;
  /** With the GM and undecided — the one stage a GM's line edit keeps it theirs. */
  const withGm = (order?.poStatus ?? '').trim() === PO_STATUS.pendingGm;
  const acts = orderActions(user?.role, order?.poStatus, overLimit);
  /** Whether the rep's proforma is waiting on this GM (proforma_release.json). */
  const holdsProforma = order
    ? proformaHeld({
        customer: customerRow,
        orderTotal: preview.total,
        poStatus: order.poStatus,
        proformaStatus: order.proformaStatus,
      })
    : false;
  const required = conditionRequiredOnApproval(order?.creditCommitment);
  const termsProblem = approvalConditionProblem(order?.creditCommitment, terms);

  // ------------------------------------------------------------ actions ---

  /*
   * The GM's approval is a credit decision, not a push. It sends the order
   * back to the sales manager at `Pending Final Approval`, and the sales
   * manager pushes it to SAP (credit_commitment.json). The note, if any, goes
   * first as a comment, so the sales manager reads it beside the commitment.
   */
  const approve = async () => {
    if (!order || !user) return;
    setBusy('approve');
    setError(null);
    try {
      if (smNote.trim()) {
        await Api.sales.addCreditComment({
          salesOrder: order.id,
          comment: smNote,
          role: user.role,
          author: user.name || user.id,
        });
        setSmNote('');
        setThreadKey((k) => k + 1);
      }
      const saved = await Api.sales.decideOrder({
        id: order.id,
        decision: 'gmApprove',
        rateEdits,
        role: user.role,
        condition: terms.trim() ? { text: terms, dueDate: due } : undefined,
        by: user.name || user.id,
      });
      setOrder(saved);
      setRateEdits({});
      if (saved.conditionSaved === false) {
        setUnsaved({ text: terms.trim(), dueDate: due });
        setDone({
          text: 'Approved, but the condition was not saved. Save it again below.',
          tone: 'warn',
        });
      } else {
        setDone({
          text: saved.conditionSaved
            ? `Approved and returned to the sales manager. Condition sent to ${order.rep || 'the rep'}.`
            : 'Approved and returned to the sales manager.',
          tone: 'ok',
        });
      }
      Api.sales
        .listCreditConditions({ salesOrder: order.id })
        .then(setConditions)
        .catch(() => {});
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the decision.');
    } finally {
      setBusy(null);
    }
  };

  /** The approval stands; this only retries the condition that did not land. */
  const saveConditionAgain = async () => {
    if (!order || !user || !unsaved) return;
    setBusy('condition');
    const made = await Api.sales.addCreditCondition({
      customer: order.customer,
      salesPerson: order.rep,
      condition: unsaved.text,
      dueDate: unsaved.dueDate,
      salesOrder: order.id,
      setBy: user.name || user.id,
    });
    setBusy(null);
    if (made) {
      setUnsaved(null);
      setConditions((c) => [...c, made]);
      setDone({ text: `Condition sent to ${order.rep || 'the rep'}.`, tone: 'ok' });
    } else {
      setError('The condition could not be saved. Try again.');
    }
  };

  const reject = async () => {
    if (!order || !user) return;
    setBusy('reject');
    setError(null);
    try {
      // The reason first, so it is on the record even if the rejection has to
      // be pressed again.
      if (rejectNote.trim()) {
        await Api.sales.addCreditComment({
          salesOrder: order.id,
          comment: `Rejected: ${rejectNote.trim()}`,
          role: user.role,
          author: user.name || user.id,
        });
        setThreadKey((k) => k + 1);
      }
      const saved = await Api.sales.decideOrder({
        id: order.id,
        decision: 'reject',
        role: user.role,
      });
      setOrder(saved);
      setRejecting(false);
      setRejectNote('');
      setDone({
        text: gmApproved
          ? 'Approval withdrawn. Order rejected and its condition closed.'
          : 'Order rejected.',
        tone: 'danger',
      });
      Api.sales
        .listCreditConditions({ salesOrder: order.id })
        .then(setConditions)
        .catch(() => {});
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the decision.');
    } finally {
      setBusy(null);
    }
  };

  /** The condition this approval made, or the retry for one that did not save. */
  const conditionsBlock = (
    <>
      {conditions.length > 0 ? (
        conditions.map((c) => (
          <blockquote key={c.id} className="commit__quote" style={{ marginTop: 8 }}>
            <div className="commit__words">{c.condition}</div>
            <div className="commit__meta">
              {c.salesPerson}
              {c.dueDate ? ` · due ${formatDate(c.dueDate)}` : ''} · {c.status}
            </div>
          </blockquote>
        ))
      ) : unsaved ? null : (
        <p className="small muted">No condition set.</p>
      )}
      {unsaved && (
        <div className="mt-16">
          <Alert
            tone="warn"
            title="Condition not saved"
            actions={
              <Button
                size="sm"
                onClick={() => void saveConditionAgain()}
                loading={busy === 'condition'}
              >
                Save again
              </Button>
            }
          >
            “{unsaved.text}” — due {formatDate(unsaved.dueDate)}
          </Alert>
        </div>
      )}
    </>
  );

  /** Reject, with an optional reason saved beside the commitment. */
  const rejectControls = (openLabel: string) =>
    rejecting ? (
      <>
        <Field label="Reason (optional)">
          <Textarea
            rows={2}
            value={rejectNote}
            onChange={(e) => setRejectNote(e.target.value)}
            disabled={!!busy}
          />
        </Field>
        <div className="lv__actions" style={{ justifyContent: 'flex-start', gap: 8 }}>
          <Button
            variant="danger"
            onClick={() => void reject()}
            loading={busy === 'reject'}
            disabled={!!busy}
          >
            {gmApproved ? 'Withdraw and reject' : 'Reject order'}
          </Button>
          <Button variant="ghost" onClick={() => setRejecting(false)} disabled={!!busy}>
            Cancel
          </Button>
        </div>
      </>
    ) : (
      <Button
        variant="ghost"
        onClick={() => setRejecting(true)}
        disabled={!acts.reject || !!busy || editing}
      >
        {openLabel}
      </Button>
    );

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">{order ? order.customerName : 'Loading…'}</div>
          <div className="page-head__sub">
            {order ? (
              <>
                {order.rep || '—'} · Raised {formatDate(order.placedOn)} · Delivery{' '}
                {order.deliveryDate ? formatDate(order.deliveryDate) : 'not set'} ·{' '}
                <span className="mono">{order.id}</span>
              </>
            ) : (
              orderId
            )}
          </div>
        </div>
        <div className="cal__nav">
          {order && <StatusPill status={order.poStatus} sapStatus={order.sapSalesOrderStatus} />}
          <RefreshButton onClick={reload} loading={loading} />
          <Link to="/gm" className="btn btn--ghost btn--sm">
            ← Escalated to You
          </Link>
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not load or save">
          {error}
        </Alert>
      )}
      {done && !error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone={done.tone} icon={done.tone === 'danger' ? '✕' : undefined} title={done.text} />
        </div>
      )}
      {loading && !order && !error && <Empty icon="◔" title="Loading…" />}

      {order && (
        <div className="gmrev">
          {/* ---------------------------------------------- 1. credit --- */}
          <div className="gmrev__credit">
          <Card title="Credit Position" className="commit">
            {!customer ? (
              <p className="small muted">Credit record unavailable.</p>
            ) : (
              <>
                <dl className="gmrev__figs" style={{ margin: 0 }}>
                  <div>
                    <dt>Outstanding</dt>
                    <dd className="num">{money(picture.outstanding, 0)}</dd>
                  </div>
                  <div>
                    <dt>This order</dt>
                    <dd className="num">
                      {money(picture.orderTotal, 0)}
                      {preview.changed && <span className="tiny dim"> (was {money(order.total, 0)})</span>}
                    </dd>
                  </div>
                  <div>
                    <dt>Projected</dt>
                    <dd className={`num${picture.over > 0 ? ' is-over' : ''}`}>{money(picture.projected, 0)}</dd>
                  </div>
                  <div>
                    <dt>Credit limit</dt>
                    <dd className="num">{picture.creditLimit ? money(picture.creditLimit, 0) : 'Not set'}</dd>
                  </div>
                </dl>
                <CreditBar picture={picture} />
                {picture.over > 0 ? (
                  <div className="gm__over">Over limit by {money(picture.over, 0)}</div>
                ) : (
                  <p className="small muted" style={{ marginTop: 10 }}>
                    Within limit at current figures.
                  </p>
                )}
                {/* The second reason an order reaches the GM (11 Oct 2026). */}
                {pastTerms && (
                  <div className="gm__over">Overdue: {pastTermsPhrase(customerRow)}</div>
                )}
                <AgingBoxes customer={customerRow} />
              </>
            )}
          </Card>
          </div>

          <div className="gmrev__main">
          {/* ------------------------------------------- 2. commitment --- */}
          <CommitmentThread order={order} overLimit={overLimit} reloadKey={threadKey} />

          {/* ------------------------------------------------ 3. lines --- */}
          <Card title="Lines" flush>
            {order.lines.length === 0 ? (
              <Empty icon="—" title="No lines" />
            ) : (
              <div className="scroll-x">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Item</th>
                      <th className="right">Qty</th>
                      <th className="right">Rate / kg</th>
                      <th className="right">Amount</th>
                      <th>SAP stock</th>
                    </tr>
                  </thead>
                  <tbody>
                    {order.lines.map((l) => {
                      const edited = rateEdits[l.id];
                      const moved = edited != null && edited > 0 && edited !== l.ratePerKg;
                      const amount = moved ? l.totalWeight * edited : l.amount;
                      const pos = positionFor(l.itemCode, stock);
                      return (
                        <tr key={l.id}>
                          <td>
                            <div>{l.itemName}</div>
                            <div className="tiny dim">{l.packingNote || l.category || '—'}</div>
                          </td>
                          <td className="right num">
                            {l.rolls ? `${l.rolls} roll${l.rolls === 1 ? '' : 's'}` : `${l.qty}`}
                            {l.looseBelts
                              ? ` + ${l.looseBelts} belt${l.looseBelts === 1 ? '' : 's'}`
                              : ''}
                            <div className="tiny dim">{l.totalWeight} kg</div>
                          </td>
                          <td className="right">
                            {/* The GM may move any rate, including one the
                                sales manager locked — see `rateEditable` —
                                until they have approved: after that these
                                are the figures the sales manager pushes. */}
                            {approved || gmApproved || editing ? (
                              <span className="num">{money(l.ratePerKg, 2)}</span>
                            ) : (
                              <Input
                                numeric
                                compact
                                type="number"
                                min={0}
                                step="0.01"
                                className="gmrev__rate"
                                aria-label={`Rate for ${l.itemName}`}
                                value={edited ?? l.ratePerKg}
                                onChange={(e) =>
                                  setRateEdits((cur) => ({
                                    ...cur,
                                    [l.id]: Number(e.target.value) || 0,
                                  }))
                                }
                              />
                            )}
                          </td>
                          <td className="right num">
                            {moved ? <b className="exp__corrected">{money(amount, 0)}</b> : money(amount, 0)}
                          </td>
                          <td className="small">
                            {!pos.stocked ? (
                              <span className="dim tiny">Not stocked</span>
                            ) : !pos.weightsKnown ? (
                              <span className="dim tiny">Weights not set</span>
                            ) : (
                              qty(pos.available)
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          <div className="order__total">
            <span>Order total</span>
            <b>{money(preview.total, 0)}</b>
          </div>
          {preview.changed && (
            <p className="small muted right" style={{ marginTop: 4 }}>
              Was {money(order.total, 0)} · new rates save on approval
            </p>
          )}

          <OrderLinesEditor
            order={order}
            role={user?.role}
            pool={pool}
            disabled={!!busy || preview.changed}
            lockedReason={
              approved
                ? 'In SAP. Lines are final.'
                : gmApproved
                  ? // Nobody changes an order the GM approved (26 Sep 2026).
                    // Withdrawing rejects it, and the rep fixes and resends.
                    EDIT_LOCK.gmApproved
                  : preview.changed
                  ? 'Approve or refresh to discard rate changes before editing lines.'
                  : null
            }
            openNote={
              withGm
                ? 'The order stays in your queue.'
                : // Saving anything not escalated sends it to the sales manager's queue
                  // (saveOrderLines), so this says so rather than promising otherwise.
                  'Saving returns it to the sales manager as Pending Approval.'
            }
            onEditingChange={setEditing}
            onError={setError}
            onSaved={() => {
              setDone({
                text: withGm
                  ? 'Lines saved.'
                  : 'Lines saved. Returned to the sales manager as Pending Approval.',
                tone: 'ok',
              });
              reload();
            }}
          />
          </div>

          {/* --------------------------------------------- 4. decision --- */}
          <div className="gmrev__decision">
          {approved ? (
            <Card title="In SAP">
              {conditionsBlock}
              <div className="mt-16">
                <Link to={`/follow-up/${order.id}`} className="btn btn--sm">
                  Open follow-up →
                </Link>
              </div>
            </Card>
          ) : gmApproved ? (
            /*
             * Approved, and with the sales manager to push. The GM does not
             * push (credit_commitment.json), but may withdraw the approval
             * until it has gone — which rejects the order and closes its
             * condition.
             */
            <Card
              title="Approved — Awaiting SAP Push"
              actions={
                order.gmApprovedOn ? (
                  <span className="tiny dim">Approved {formatDate(order.gmApprovedOn.slice(0, 10))}</span>
                ) : undefined
              }
            >
              {conditionsBlock}
              <div className="mt-16">{rejectControls('Withdraw approval…')}</div>
              <div className="mt-16">
                <Link to={`/follow-up/${order.id}`} className="btn btn--sm">
                  Open follow-up →
                </Link>
              </div>
            </Card>
          ) : rejected ? (
            <Alert tone="danger" icon="✕" title="Rejected" />
          ) : (
            <Card title="Your Decision">
              <Field
                label={required ? 'Condition' : 'Condition (optional)'}
                error={terms !== (order.creditCommitment ?? '') ? (termsProblem ?? undefined) : undefined}
              >
                <Textarea
                  rows={3}
                  value={terms}
                  onChange={(e) => setTerms(e.target.value)}
                  placeholder="Clear the 60-day outstanding before the next delivery"
                  disabled={!!busy || editing}
                />
              </Field>
              <Field label="Due date">
                <Input
                  type="date"
                  className="gmdecide__due"
                  value={due}
                  onChange={(e) => setDue(e.target.value)}
                  disabled={!!busy || editing}
                />
              </Field>
              <Field label="Comment to sales manager (optional)">
                <Textarea
                  rows={2}
                  value={smNote}
                  onChange={(e) => setSmNote(e.target.value)}
                  placeholder="Push only once the cheque is in hand"
                  disabled={!!busy || editing}
                />
              </Field>

              {rejecting ? (
                rejectControls('Reject…')
              ) : (
                <div className="lv__actions" style={{ justifyContent: 'flex-start', gap: 8 }}>
                  <Button
                    variant="primary"
                    onClick={() => void approve()}
                    loading={busy === 'approve'}
                    disabled={!acts.gmApprove || !!busy || editing || Boolean(termsProblem)}
                  >
                    {terms.trim() ? 'Approve with condition' : 'Approve'}
                  </Button>
                  <Button
                    variant="ghost"
                    onClick={() => setRejecting(true)}
                    disabled={!acts.reject || !!busy || editing}
                  >
                    Reject…
                  </Button>
                </div>
              )}
              {holdsProforma && !rejecting && (
                <p className="small muted" style={{ marginTop: 10 }}>
                  Approving releases the rep's held proforma.
                </p>
              )}
              {editing && (
                <p className="small muted" style={{ marginTop: 10 }}>
                  Save or cancel line edits first.
                </p>
              )}
            </Card>
          )}
          </div>
        </div>
      )}

      {!loading && !order && !error && <Empty icon="—" title="Order not found" />}
    </div>
  );
}
