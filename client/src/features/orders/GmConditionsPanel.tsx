/**
 * The conditions the GM has attached, and the answers waiting on them.
 *
 * The GM sets these while approving an over-limit order. Without somewhere to
 * close them, a condition would be a promise the rep answers into silence —
 * and the one rule the feature exists for is that only the GM decides whether
 * an obligation was met. So this is the other half of the loop, and it lives
 * beside the queue that creates them.
 *
 * Awaiting Review sorts to the top: those are the ones with a person waiting.
 * `canMoveCondition` decides what the buttons offer, so the screen and
 * `Api.sales.decideCreditCondition` cannot drift apart — the API re-checks the
 * same rule, because this site has no Server Script behind the screen.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import { Api, type CreditCondition } from '@/api/client';
import {
  canMoveCondition,
  COND_AWAITING,
  COND_CLOSED,
  conditionOverdue,
  type ConditionAction,
} from '@/domain/creditCondition';
import { serverNow } from '@/domain/serverClock';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { pushToast } from '@/store/slices/notificationsSlice';
import { Alert, Badge, Button, Card, Empty, Textarea } from '@/components/ui';

export function GmConditionsPanel() {
  const dispatch = useAppDispatch();
  const user = useAppSelector(selectUser);

  const [rows, setRows] = useState<CreditCondition[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [notes, setNotes] = useState<Record<string, string>>({});

  const load = useCallback(() => {
    setLoading(true);
    setError(null);
    Api.sales
      .listCreditConditions()
      .then(setRows)
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : 'Could not read the conditions.'),
      )
      .finally(() => setLoading(false));
  }, []);

  useEffect(load, [load]);

  const today = serverNow();

  /*
   * Awaiting Review first — somebody is waiting on those. Then open ones by
   * deadline, then the closed ones, which are history rather than work.
   */
  const sorted = useMemo(() => {
    const rank = (c: CreditCondition) =>
      c.status === COND_AWAITING ? 0 : c.status === COND_CLOSED ? 2 : 1;
    return [...rows].sort(
      (a, b) => rank(a) - rank(b) || (a.dueDate || '9999').localeCompare(b.dueDate || '9999'),
    );
  }, [rows]);

  const open = sorted.filter((c) => c.status !== COND_CLOSED);
  const waiting = sorted.filter((c) => c.status === COND_AWAITING).length;

  const decide = async (c: CreditCondition, action: ConditionAction) => {
    if (!user) return;
    setBusy(c.id);
    try {
      await Api.sales.decideCreditCondition({
        id: c.id,
        action,
        role: user.role,
        note: notes[c.id],
        by: user.name || user.id,
      });
      dispatch(
        pushToast(
          action === 'close' ? 'Condition closed.' : 'Sent back to the rep.',
          'success',
        ),
      );
      load();
    } catch (e: unknown) {
      dispatch(
        pushToast(e instanceof Error ? e.message : 'Could not save that.', 'critical'),
      );
    } finally {
      setBusy(null);
    }
  };

  if (loading) return <Empty icon="◔" title="Reading conditions…" />;

  return (
    <Card
      title={
        waiting > 0
          ? `Conditions — ${waiting} awaiting your review`
          : `Conditions — ${open.length} open`
      }
    >
      {error && (
        <Alert tone="danger" title="Could not read the conditions">
          {error}
        </Alert>
      )}

      {!error && sorted.length === 0 && (
        <Empty icon="✓" title="No conditions set">
          When you approve an over-limit order on terms, those terms appear here until you
          close them.
        </Empty>
      )}

      {sorted.map((c) => {
        const late = conditionOverdue(c.status, c.dueDate, today);
        const closed = c.status === COND_CLOSED;
        const canClose = canMoveCondition(c.status, 'close', 'gm');
        const canReopen = canMoveCondition(c.status, 'reopen', 'gm');

        return (
          <div key={c.id} className="cond__row" style={{ padding: '10px 0' }}>
            <div style={{ display: 'flex', gap: 8, alignItems: 'baseline' }}>
              <strong style={{ flex: 1 }}>{c.customer}</strong>
              <Badge tone={late ? 'danger' : closed ? 'ok' : 'warn'}>
                {late ? 'Overdue' : closed ? 'Closed' : c.status}
              </Badge>
            </div>

            <p style={{ margin: '6px 0' }}>{c.condition}</p>

            <p className="small" style={{ margin: 0 }}>
              {/* Said out loud rather than left blank — an empty slot reads as
                  a rendering fault, not as "there is no deadline". */}
              {c.dueDate ? `Due ${c.dueDate}` : 'No deadline'}
              {c.salesPerson ? ` · ${c.salesPerson}` : ''}
              {c.salesOrder ? ` · ${c.salesOrder}` : ''}
            </p>

            {c.response && (
              <blockquote
                style={{
                  margin: '8px 0',
                  padding: '6px 10px',
                  borderLeft: '3px solid var(--border)',
                }}
              >
                <span className="small">The rep answered</span>
                <div>{c.response}</div>
              </blockquote>
            )}

            {closed && c.closeNote && <p className="small">Closed: {c.closeNote}</p>}

            {(canClose || canReopen) && (
              <div style={{ marginTop: 8 }}>
                {canClose && (
                  <Textarea
                    rows={2}
                    placeholder="Note on closing (optional)"
                    value={notes[c.id] ?? ''}
                    onChange={(e) => setNotes((n) => ({ ...n, [c.id]: e.target.value }))}
                  />
                )}
                <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
                  {canClose && (
                    <Button
                      size="sm"
                      variant="primary"
                      loading={busy === c.id}
                      onClick={() => void decide(c, 'close')}
                    >
                      Close it
                    </Button>
                  )}
                  {canReopen && (
                    <Button
                      size="sm"
                      loading={busy === c.id}
                      onClick={() => void decide(c, 'reopen')}
                    >
                      {closed ? 'Reopen' : 'Send back'}
                    </Button>
                  )}
                </div>
              </div>
            )}
          </div>
        );
      })}
    </Card>
  );
}
