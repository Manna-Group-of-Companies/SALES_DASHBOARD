/**
 * A3 — Approvals inbox.
 *
 * Everything the manager owes a decision on **except orders**. Four queues in
 * one list, because two places to look was two places to miss one.
 *
 * Orders are deliberately not here. Approving an order fixes a price
 * permanently, commits stock and can convert a party — that needs the lines,
 * the stock position and the credit picture in front of it, and a card in an
 * inbox cannot carry those. Orders are decided in Team Orders and nowhere else.
 *
 * The three location queues each show **the photo and a map link**. The
 * manager is verifying that a photograph matches a place; coordinates alone
 * are not a thing a person can recognise.
 */

import { useEffect, useMemo, useState } from 'react';
import { scopeFor, NO_TEAM_MESSAGE } from '@/domain/sales';
import { Api, type InboxItem, type InboxKind } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Segmented } from '@/components/ui';
import { money } from '@/components/common/format';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import './approvals.css';

type Filter = 'all' | InboxKind;

// The "Proforma credit release" queue went on 26 Sep 2026: a proforma held on
// credit now unlocks when the GM approves the order
// (shared/fixtures/proforma_release.json). Sites are what is left.
const KIND_LABEL: Record<InboxKind, string> = {
  site: 'Customer site',
};

export function ApprovalsInboxPage() {
  const user = useAppSelector(selectUser);

  const [items, setItems] = useState<InboxItem[]>([]);
  const [filter, setFilter] = useState<Filter>('all');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.attendance
      .listSalesPeople()
      .then(async (p) => {
        if (!live) return;
        const team = scopeFor(p, user?.salesPerson);
        /* Fail closed: an unresolved team must show nothing, never everyone. */
        if (!team) {
          setError(NO_TEAM_MESSAGE);
          return;
        }
        const list = await Api.sales.listApprovalInbox(team);
        if (live) setItems(list);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read the inbox.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick, user]);

  const counts = useMemo(() => {
    const c: Record<InboxKind, number> = { site: 0 };
    for (const i of items) c[i.kind] += 1;
    return c;
  }, [items]);

  const rows = useMemo(
    () => (filter === 'all' ? items : items.filter((i) => i.kind === filter)),
    [items, filter],
  );

  const decide = async (item: InboxItem, approve: boolean) => {
    setBusy(`${item.kind}-${item.id}`);
    setError(null);
    try {
      await Api.sales.decideInboxItem({
        kind: item.kind,
        id: item.id,
        approve,
        latitude: item.latitude,
        longitude: item.longitude,
      });
      // Drop the card rather than refetching four queues to learn that one row
      // changed.
      setItems((cur) => cur.filter((i) => !(i.id === item.id && i.kind === item.kind)));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the decision.');
    } finally {
      setBusy(null);
    }
  };

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Approvals</div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not load or save">
          {error}
        </Alert>
      )}

      <div className="cal__toolbar">
        <Segmented
          ariaLabel="Queue"
          value={filter}
          onChange={setFilter}
          options={[
            { value: 'all', label: `All (${items.length})` },
            { value: 'site', label: `Sites (${counts.site})` },
          ]}
        />
      </div>

      {loading && <Empty icon="◔" title="Loading…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="✓" title="No approvals waiting" />
      )}

      <div className="loc__grid">
        {rows.map((item) => {
          const key = `${item.kind}-${item.id}`;
          // Every kind left is a place to verify.
          const isLocation = true;
          const hasCoords = Boolean(item.latitude && item.longitude);
          return (
            <Card
              key={key}
              title={
                <span className="odo__title">
                  <span>{item.title}</span>
                  <Badge tone="neutral">{KIND_LABEL[item.kind]}</Badge>
                </span>
              }
            >
              {isLocation && (
                <div className="loc__photo">
                  {item.photo ? (
                    <a href={item.photo} target="_blank" rel="noreferrer">
                      <img src={item.photo} alt={`${item.party ?? item.id}`} loading="lazy" />
                    </a>
                  ) : (
                    <div className="loc__photo--empty">No photo</div>
                  )}
                </div>
              )}

              <table className="table loc__facts">
                <tbody>
                  <tr>
                    <td className="dim">Document</td>
                    <td className="mono small">{item.id}</td>
                  </tr>
                  <tr>
                    <td className="dim">Party</td>
                    <td>{item.party || '—'}</td>
                  </tr>
                  <tr>
                    <td className="dim">Representative</td>
                    <td>{item.rep || '—'}</td>
                  </tr>
                  {item.amount != null && (
                    <tr>
                      <td className="dim">Amount</td>
                      <td className="num">{money(item.amount, 0)}</td>
                    </tr>
                  )}
                  {item.route && (
                    <tr>
                      <td className="dim">Route</td>
                      <td>{item.route}</td>
                    </tr>
                  )}
                  {isLocation && (
                    <tr>
                      <td className="dim">Coordinates</td>
                      <td className="num">
                        {hasCoords ? (
                          <a
                            href={`https://www.google.com/maps?q=${item.latitude},${item.longitude}`}
                            target="_blank"
                            rel="noreferrer"
                          >
                            {item.latitude!.toFixed(5)}, {item.longitude!.toFixed(5)}
                          </a>
                        ) : (
                          <span className="dim">Not captured</span>
                        )}
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>

              <div className="loc__actions">
                <Button
                  size="sm"
                  onClick={() => decide(item, true)}
                  loading={busy === key}
                  disabled={busy !== null || (isLocation && !hasCoords)}
                  title={isLocation && !hasCoords ? 'No coordinates captured' : undefined}
                >
                  Verify
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => decide(item, false)}
                  disabled={busy !== null}
                >
                  Send back
                </Button>
              </div>
            </Card>
          );
        })}
      </div>
    </div>
  );
}
