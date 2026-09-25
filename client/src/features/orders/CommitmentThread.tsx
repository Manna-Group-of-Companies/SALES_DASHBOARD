/**
 * The rep's commitment on an over-limit order, and the conversation under it.
 *
 * The rep writes what the customer promised when raising the order; the sales
 * manager and the GM add what they know beneath it; the GM decides with all of
 * it in front of them. Shown on the sales manager's review and on the GM's,
 * because the whole point is that both read the same words — see
 * `shared/fixtures/credit_commitment.json`.
 *
 * Who may add a comment is `orderActions(...).comment`, asked again by
 * `Api.sales.addCreditComment` against the order as stored.
 */

import { useCallback, useEffect, useState } from 'react';
import { Api, type CreditComment } from '@/api/client';
import { hasCommitment, orderActions } from '@/domain/creditCommitment';
import { formatDate } from '@/domain/orderRules';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Button, Card, Textarea } from '@/components/ui';

export function CommitmentThread({
  order,
  overLimit,
  reloadKey,
}: {
  order: {
    id: string;
    rep: string;
    poStatus: string;
    creditCommitment?: string;
    creditCommitmentDue?: string;
  };
  overLimit: boolean;
  /** Changes when the page posts a comment itself, e.g. a note sent with an escalation. */
  reloadKey?: unknown;
}) {
  const user = useAppSelector(selectUser);
  const [comments, setComments] = useState<CreditComment[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const [busy, setBusy] = useState(false);

  const load = useCallback(() => {
    Api.sales
      .listCreditComments([order.id])
      .then((c) => {
        setComments(c);
        setError(null);
      })
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : 'Could not read the comments.'),
      )
      .finally(() => setLoaded(true));
  }, [order.id]);

  useEffect(load, [load, reloadKey]);

  const committed = hasCommitment(order.creditCommitment);
  const mayComment = orderActions(user?.role, order.poStatus, overLimit).comment;

  // Nothing to say on an order that never needed a commitment and has none.
  if (!committed && !overLimit && comments.length === 0) return null;

  const post = async () => {
    if (!user) return;
    setBusy(true);
    setError(null);
    try {
      await Api.sales.addCreditComment({
        salesOrder: order.id,
        comment: draft,
        role: user.role,
        author: user.name || user.id,
      });
      setDraft('');
      load();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the comment.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card title="The rep's commitment" className="commit">
      {committed ? (
        <blockquote className="commit__quote">
          <div className="commit__words">{order.creditCommitment}</div>
          <div className="commit__meta">
            {order.rep || 'The rep'}
            {order.creditCommitmentDue
              ? ` · to be met by ${formatDate(order.creditCommitmentDue)}`
              : ' · no date given'}
          </div>
        </blockquote>
      ) : (
        /* Said out loud, so an empty box is not read as a page that failed to
           load. Orders raised before 24 Sep 2026 have none, and so does one
           pushed over the limit after the rep sent it. */
        <Alert tone="warn" title="No commitment from the rep">
          This order was raised before commitments were asked for, or went over the limit after
          the rep sent it. Ask the rep what the customer has promised.
        </Alert>
      )}

      {comments.length > 0 && (
        <ol className="commit__thread">
          {comments.map((c) => (
            <li key={c.id} className="commit__item">
              <div className="commit__meta">
                <b>{c.author}</b>
                {c.authorRole ? ` · ${c.authorRole}` : ''}
                {c.postedOn ? ` · ${formatDate(c.postedOn.slice(0, 10))}` : ''}
              </div>
              <div className="commit__words">{c.comment}</div>
            </li>
          ))}
        </ol>
      )}

      {error && (
        <div style={{ marginTop: 10 }}>
          <Alert tone="danger" title="Comments">
            {error}
          </Alert>
        </div>
      )}

      {loaded && mayComment && (
        <div className="commit__add">
          <Textarea
            rows={2}
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            placeholder="Add what you know — payment history, what to collect first…"
            aria-label="Add a comment to the commitment"
          />
          <Button size="sm" onClick={() => void post()} loading={busy} disabled={!draft.trim()}>
            Add comment
          </Button>
        </div>
      )}

      {committed && (
        <p className="note" style={{ marginTop: 8, marginBottom: 0 }}>
          When the general manager approves, this becomes the rep's condition — with these
          comments beside it — on their phone until the GM closes it.
        </p>
      )}
    </Card>
  );
}
