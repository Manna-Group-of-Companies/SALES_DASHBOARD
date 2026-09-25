/**
 * One approved order, followed up.
 *
 * Everything about the order once the GM has approved it: where it is (with
 * the sales manager, in SAP under SAP's own number, invoiced), what it holds,
 * the condition it was approved on, and the whole conversation — the rep's
 * commitment, the managers' comments, the approval, and every answer the rep
 * has given since, which arrive here from their Conditions tab.
 *
 * Only the GM closes or sends back a condition (`canMoveCondition`), and only
 * the GM adds follow-up notes (`mayAddFollowUpNote`); the API re-checks both.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { OrderDetail, SalesCustomer } from '@/domain/types';
import { creditPicture } from '@/domain/orderStatus';
import {
  canMoveCondition,
  COND_AWAITING,
  COND_CLOSED,
  conditionOverdue,
  type ConditionAction,
} from '@/domain/creditCondition';
import { mayAddFollowUpNote } from '@/domain/creditCommitment';
import { followUpTimeline } from '@/domain/followUp';
import { lineStatusFromSap, reachedSap } from '@/domain/sapOrderState';
import { formatDate } from '@/domain/orderRules';
import { serverNow } from '@/domain/serverClock';
import { Api, type CreditComment, type CreditCondition } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Textarea } from '@/components/ui';
import { money } from '@/components/common/format';
import { RefreshButton } from '@/components/common/RefreshButton';
import { StatusPill } from '@/components/common/StatusPill';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import './orders.css';

/** Frappe's `YYYY-MM-DD HH:MM:SS`, as a person reads it. */
function when(at: string): string {
  if (!at) return '';
  const date = formatDate(at.slice(0, 10));
  const time = at.slice(11, 16);
  return time ? `${date}, ${time}` : date;
}

export function GmFollowUpOrderPage() {
  const { orderId = '' } = useParams();
  const user = useAppSelector(selectUser);

  const [order, setOrder] = useState<OrderDetail | null>(null);
  const [customer, setCustomer] = useState<SalesCustomer | null>(null);
  const [conditions, setConditions] = useState<CreditCondition[]>([]);
  const [comments, setComments] = useState<CreditComment[]>([]);
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState('');
  const [decisionNote, setDecisionNote] = useState<Record<string, string>>({});

  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([
      Api.sales.getOrder(orderId),
      Api.sales.listCreditConditions({ salesOrder: orderId }),
      Api.sales.listCreditComments([orderId]),
    ])
      .then(async ([o, conds, thread]) => {
        if (!live) return;
        setOrder(o);
        setConditions(conds);
        setComments(thread);
        const parties = await Api.sales.listCustomers().catch(() => [] as SalesCustomer[]);
        if (live) setCustomer(parties.find((c) => c.id === o.customer) ?? null);
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

  const timeline = useMemo(
    () =>
      order
        ? followUpTimeline({
            rep: order.rep,
            placedAt: order.placedAt,
            commitment: order.creditCommitment,
            commitmentDue: order.creditCommitmentDue,
            gmApprovedBy: order.gmApprovedBy,
            gmApprovedOn: order.gmApprovedOn,
            comments,
            conditions,
          })
        : [],
    [order, comments, conditions],
  );

  const today = serverNow();

  const decide = async (c: CreditCondition, action: ConditionAction) => {
    if (!user) return;
    setBusy(`${c.id}:${action}`);
    setError(null);
    try {
      await Api.sales.decideCreditCondition({
        id: c.id,
        action,
        role: user.role,
        note: decisionNote[c.id],
        by: user.name || user.id,
      });
      setDecisionNote((n) => ({ ...n, [c.id]: '' }));
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save that.');
    } finally {
      setBusy(null);
    }
  };

  const addNote = async () => {
    if (!user || !order) return;
    setBusy('note');
    setError(null);
    try {
      await Api.sales.addFollowUpNote({
        salesOrder: order.id,
        comment: note,
        role: user.role,
        author: user.name || user.id,
      });
      setNote('');
      reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the note.');
    } finally {
      setBusy(null);
    }
  };

  if (!user) return null;

  const inSap = order ? reachedSap({ salesOrder: order.sapSalesOrder }) : false;
  const picture = creditPicture({
    outstanding: customer?.outstanding,
    creditLimit: customer?.creditLimit,
    orderTotal: 0,
  });

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">{order ? order.customerName : 'Loading…'}</div>
          <div className="page-head__sub">
            {order ? (
              order.sapSalesOrder ? (
                <>
                  <b className="mono">SAP order {order.sapSalesOrder}</b>{' '}
                  <span className="tiny dim">({order.id} in ERPNext)</span>
                </>
              ) : (
                <>
                  <span className="mono">{order.id}</span> · not in SAP yet
                </>
              )
            ) : (
              orderId
            )}
          </div>
        </div>
        <div className="cal__nav">
          {order && <StatusPill status={order.poStatus} sapStatus={order.sapSalesOrderStatus} />}
          <RefreshButton onClick={reload} loading={loading} />
          <Link to="/follow-up" className="btn btn--ghost btn--sm">
            ← Follow-up
          </Link>
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read or save">
          {error}
        </Alert>
      )}
      {loading && !order && !error && <Empty icon="◔" title="Reading order…" />}

      {order && (
        <div className="fu__grid">
          <div className="fu__main">
            {/* ---------------------------------------------- condition --- */}
            {conditions.length === 0 ? (
              <Card title="Condition" className="commit">
                <p className="note" style={{ margin: 0 }}>
                  This order was approved without a condition, so the rep owes nothing on it.
                </p>
              </Card>
            ) : (
              conditions.map((c) => {
                const late = conditionOverdue(c.status, c.dueDate, today);
                const closed = c.status === COND_CLOSED;
                const canClose = canMoveCondition(c.status, 'close', 'gm');
                const canReopen = canMoveCondition(c.status, 'reopen', 'gm');
                return (
                  <Card
                    key={c.id}
                    title="The condition"
                    className="commit"
                    actions={
                      <Badge tone={late ? 'danger' : closed ? 'ok' : c.status === COND_AWAITING ? 'info' : 'warn'}>
                        {late ? 'Overdue' : c.status}
                      </Badge>
                    }
                  >
                    <blockquote className="commit__quote">
                      <div className="commit__words">{c.condition}</div>
                      <div className="commit__meta">
                        {c.salesPerson} owes this
                        {c.dueDate ? ` by ${formatDate(c.dueDate)}` : ' — no deadline'}
                        {c.setBy ? ` · set by ${c.setBy}` : ''}
                      </div>
                    </blockquote>

                    {c.status === COND_AWAITING && (
                      <div style={{ marginTop: 10 }}>
                        <Alert tone="info" title="The rep has answered">
                          “{c.response}” — read the conversation, then close it or send it back.
                        </Alert>
                      </div>
                    )}
                    {closed && (
                      <p className="note" style={{ marginBottom: 0 }}>
                        Closed{c.closedBy ? ` by ${c.closedBy}` : ''}
                        {c.closedOn ? ` on ${formatDate(c.closedOn.slice(0, 10))}` : ''}
                        {c.closeNote ? ` — ${c.closeNote}` : ''}.
                      </p>
                    )}

                    {(canClose || canReopen) && (
                      <div style={{ marginTop: 10 }}>
                        <Textarea
                          rows={2}
                          value={decisionNote[c.id] ?? ''}
                          onChange={(e) => setDecisionNote((n) => ({ ...n, [c.id]: e.target.value }))}
                          placeholder={
                            closed
                              ? 'Why you are reopening it (optional)'
                              : 'A note — sent to the rep if you send it back (optional)'
                          }
                          aria-label="Note on this decision"
                          disabled={!!busy}
                        />
                        <div className="lv__actions" style={{ justifyContent: 'flex-start', gap: 8, marginTop: 6 }}>
                          {canClose && (
                            <Button
                              size="sm"
                              variant="primary"
                              loading={busy === `${c.id}:close`}
                              disabled={!!busy}
                              onClick={() => void decide(c, 'close')}
                            >
                              Close it — the condition is met
                            </Button>
                          )}
                          {canReopen && (
                            <Button
                              size="sm"
                              loading={busy === `${c.id}:reopen`}
                              disabled={!!busy}
                              onClick={() => void decide(c, 'reopen')}
                            >
                              {closed ? 'Reopen' : 'Send back to the rep'}
                            </Button>
                          )}
                        </div>
                      </div>
                    )}
                  </Card>
                );
              })
            )}

            {/* ------------------------------------------- conversation --- */}
            <Card title="Follow-up" className="commit">
              {timeline.length === 0 ? (
                <p className="note" style={{ margin: 0 }}>Nothing said about this order yet.</p>
              ) : (
                <ol className="commit__thread" style={{ marginTop: 0 }}>
                  {timeline.map((e, i) => (
                    <li
                      key={`${e.kind}-${i}`}
                      className={`commit__item fu__event fu__event--${e.kind}`}
                    >
                      <div className="commit__meta">
                        <b>{e.who}</b>
                        {e.role ? ` · ${e.role}` : ''}
                        {e.at ? ` · ${when(e.at)}` : ''}
                        {e.kind === 'answer' && <span className="fu__tag">answer</span>}
                      </div>
                      <div className="commit__words">{e.text}</div>
                    </li>
                  ))}
                </ol>
              )}

              {mayAddFollowUpNote(user.role) && (
                <div className="commit__add">
                  <Textarea
                    rows={2}
                    value={note}
                    onChange={(e) => setNote(e.target.value)}
                    placeholder="A note to the rep — it shows under their condition on the phone"
                    aria-label="Add a follow-up note"
                    disabled={!!busy}
                  />
                  <Button size="sm" onClick={() => void addNote()} loading={busy === 'note'} disabled={!note.trim()}>
                    Add note
                  </Button>
                </div>
              )}
            </Card>
          </div>

          <div className="fu__side">
            {/* ------------------------------------------------- order --- */}
            <Card title="The order">
              <table className="table loc__facts">
                <tbody>
                  <tr>
                    <td className="dim">SAP order</td>
                    <td className="num">
                      {order.sapSalesOrder ? (
                        <b className="mono">{order.sapSalesOrder}</b>
                      ) : (
                        <span className="dim">Not pushed yet — with the sales manager</span>
                      )}
                    </td>
                  </tr>
                  {order.sapSalesOrderStatus && (
                    <tr>
                      <td className="dim">SAP status</td>
                      <td className="num">{order.sapSalesOrderStatus}</td>
                    </tr>
                  )}
                  <tr>
                    <td className="dim">Invoice</td>
                    <td className="num">
                      {order.sapInvoice
                        ? `${order.sapInvoice}${order.sapInvoiceDate ? ` · ${formatDate(order.sapInvoiceDate)}` : ''}`
                        : inSap
                          ? 'Not invoiced yet'
                          : '—'}
                    </td>
                  </tr>
                  <tr>
                    <td className="dim">ERPNext</td>
                    <td className="num mono">{order.id}</td>
                  </tr>
                  <tr>
                    <td className="dim">Rep</td>
                    <td className="num">{order.rep || '—'}</td>
                  </tr>
                  <tr>
                    <td className="dim">Raised</td>
                    <td className="num">{formatDate(order.placedOn)}</td>
                  </tr>
                  <tr>
                    <td className="dim">Delivery</td>
                    <td className="num">{order.deliveryDate ? formatDate(order.deliveryDate) : 'not set'}</td>
                  </tr>
                  <tr>
                    <td className="dim">Order total</td>
                    <td className="num">
                      <b>{money(order.total, 0)}</b>
                    </td>
                  </tr>
                  <tr>
                    <td className="dim">Approved by</td>
                    <td className="num">
                      {order.gmApprovedBy || '—'}
                      {order.gmApprovedOn ? ` · ${formatDate(order.gmApprovedOn.slice(0, 10))}` : ''}
                    </td>
                  </tr>
                  {customer && (
                    <>
                      <tr>
                        <td className="dim">Customer owes now</td>
                        <td className="num">{money(picture.outstanding, 0)}</td>
                      </tr>
                      <tr>
                        <td className="dim">Credit limit</td>
                        <td className="num">
                          {picture.creditLimit ? money(picture.creditLimit, 0) : 'not set'}
                        </td>
                      </tr>
                    </>
                  )}
                </tbody>
              </table>
            </Card>

            {/* ------------------------------------------------- lines --- */}
            <Card title="Lines" flush>
              {order.lines.length === 0 ? (
                <Empty icon="—" title="This order has no lines" />
              ) : (
                <div className="scroll-x">
                  <table className="table">
                    <thead>
                      <tr>
                        <th>Item</th>
                        <th className="right">Qty</th>
                        <th className="right">Amount</th>
                        <th>SAP</th>
                      </tr>
                    </thead>
                    <tbody>
                      {order.lines.map((l) => (
                        <tr key={l.id}>
                          <td>
                            <div>{l.itemName}</div>
                            <div className="tiny dim">{money(l.ratePerKg, 2)} / kg</div>
                          </td>
                          <td className="right num">
                            {l.rolls ? `${l.rolls} roll${l.rolls === 1 ? '' : 's'}` : `${l.qty}`}
                            {l.looseBelts ? ` + ${l.looseBelts} belt${l.looseBelts === 1 ? '' : 's'}` : ''}
                            <div className="tiny dim">{l.totalWeight} kg</div>
                          </td>
                          <td className="right num">{money(l.amount, 0)}</td>
                          <td className="small">
                            {inSap ? (
                              <>
                                {lineStatusFromSap({ invoice: l.sapInvoice }, { salesOrder: order.sapSalesOrder })}
                                {l.sapInvoice && <div className="tiny dim">Invoice {l.sapInvoice}</div>}
                              </>
                            ) : (
                              <span className="dim">—</span>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </Card>
          </div>
        </div>
      )}

      {!loading && !order && !error && <Empty icon="—" title="Order not found" />}
    </div>
  );
}
