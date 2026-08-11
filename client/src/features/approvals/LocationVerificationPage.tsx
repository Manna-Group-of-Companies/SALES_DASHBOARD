/**
 * Location verification — customers and leads in one queue.
 *
 * A rep captures a shop's coordinates and photo the first time they visit.
 * The manager checks the photo against the name and either verifies it or
 * sends it back to be captured again.
 *
 * Both queues have the same shape and the same decision, so they are one
 * screen rather than two. Splitting them would mean two places to check and
 * two counts to keep in your head.
 *
 * Approving copies the captured coordinates into the **verified** fields.
 * Those are what the 100 m punch-in check runs against — verifying without
 * copying them verifies nobody.
 */

import { useEffect, useMemo, useState } from 'react';
import type { LocationCheck, SalesPerson } from '@/domain/types';
import { managesTeam as managesTeamOf, teamOf } from '@/domain/sales';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Segmented, Select } from '@/components/ui';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import './approvals.css';

type Kind = 'all' | 'customer' | 'lead';

export function LocationVerificationPage() {
  const user = useAppSelector(selectUser);

  const [queue, setQueue] = useState<LocationCheck[]>([]);
  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [kind, setKind] = useState<Kind>('all');
  const [rep, setRep] = useState('');
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const myTeam = useMemo(() => teamOf(people, user?.salesPerson), [people, user]);
  const managesTeam = useMemo(() => managesTeamOf(people, user?.salesPerson), [people, user]);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.attendance
      .listSalesPeople()
      .then(async (p) => {
        if (!live) return;
        setPeople(p);
        const team = teamOf(p, user?.salesPerson);
        // A manager only ever decides their own team's captures.
        const q = await Api.sales.listLocationQueue(team.length ? team : undefined);
        if (live) setQueue(q);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read the queue.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [tick, user]);

  const repOptions = useMemo(
    () =>
      people
        .filter((p) => p.enabled && !p.isGroup && (!myTeam.length || myTeam.includes(p.id)))
        .sort((a, b) => a.name.localeCompare(b.name)),
    [people, myTeam],
  );

  const rows = useMemo(() => {
    let list = queue;
    if (kind !== 'all') list = list.filter((q) => q.kind === kind);
    if (rep) list = list.filter((q) => q.rep === rep || q.capturedBy === rep);
    return list;
  }, [queue, kind, rep]);

  const decide = async (item: LocationCheck, approve: boolean) => {
    setBusy(item.id);
    setError(null);
    try {
      await Api.sales.decideLocation({
        kind: item.kind,
        id: item.id,
        approve,
        latitude: item.latitude,
        longitude: item.longitude,
      });
      // Drop it from the queue rather than refetching 3,600 records to
      // discover the one row that changed.
      setQueue((cur) => cur.filter((q) => !(q.id === item.id && q.kind === item.kind)));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the decision.');
    } finally {
      setBusy(null);
    }
  };

  const counts = useMemo(
    () => ({
      customers: queue.filter((q) => q.kind === 'customer').length,
      leads: queue.filter((q) => q.kind === 'lead').length,
    }),
    [queue],
  );

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Location verification</div>
          <div className="page-head__sub">
            Captured on a first visit — check the photo, then verify or send it back
          </div>
        </div>
        <div className="cal__nav">
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read or save">
          {error}
        </Alert>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile
          label="Waiting on you"
          value={String(queue.length)}
          tone={queue.length ? 'warn' : 'ok'}
          foot={queue.length ? 'Captures to check' : 'Queue clear'}
        />
        <Tile label="Customers" value={String(counts.customers)} foot="Existing parties" />
        <Tile label="Leads" value={String(counts.leads)} foot="Not yet converted" />
        {managesTeam && (
          <Tile label="Your team" value={String(myTeam.length)} foot="Reps you decide for" />
        )}
      </div>

      <div className="cal__toolbar">
        <Select value={rep} onChange={(e) => setRep(e.target.value)} aria-label="Representative">
          <option value="">All representatives</option>
          {repOptions.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </Select>
        <Segmented
          ariaLabel="Type"
          value={kind}
          onChange={setKind}
          options={[
            { value: 'all', label: `All (${queue.length})` },
            { value: 'customer', label: `Customers (${counts.customers})` },
            { value: 'lead', label: `Leads (${counts.leads})` },
          ]}
        />
      </div>

      {loading && <Empty icon="◔" title="Reading the queue…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="✓" title="Nothing waiting on a location decision">
          A capture appears here the first time a rep visits a shop.
        </Empty>
      )}

      <div className="loc__grid">
        {rows.map((item) => (
          <Card
            key={`${item.kind}-${item.id}`}
            title={
              <span className="odo__title">
                <span>{item.name}</span>
                <Badge tone={item.kind === 'lead' ? 'accent' : 'neutral'}>{item.kind}</Badge>
              </span>
            }
          >
            <div className="loc__photo">
              {item.bannerPhoto ? (
                <a href={item.bannerPhoto} target="_blank" rel="noreferrer">
                  <img src={item.bannerPhoto} alt={`${item.name} shopfront`} loading="lazy" />
                </a>
              ) : (
                <div className="loc__photo--empty">No shop photo captured</div>
              )}
            </div>

            <table className="table loc__facts">
              <tbody>
                <tr>
                  <td className="dim">Captured by</td>
                  <td>{item.capturedBy || item.rep || '—'}</td>
                </tr>
                <tr>
                  <td className="dim">Route</td>
                  <td>{item.route || <span className="dim">none set</span>}</td>
                </tr>
                {item.address && (
                  <tr>
                    <td className="dim">Address</td>
                    <td>{item.address}</td>
                  </tr>
                )}
                <tr>
                  <td className="dim">Coordinates</td>
                  <td className="num">
                    {item.latitude && item.longitude ? (
                      <a
                        href={`https://www.google.com/maps?q=${item.latitude},${item.longitude}`}
                        target="_blank"
                        rel="noreferrer"
                      >
                        {item.latitude.toFixed(5)}, {item.longitude.toFixed(5)}
                      </a>
                    ) : (
                      <span className="dim">not captured</span>
                    )}
                  </td>
                </tr>
              </tbody>
            </table>

            <div className="loc__actions">
              <Button
                size="sm"
                onClick={() => decide(item, true)}
                loading={busy === item.id}
                disabled={busy !== null || !(item.latitude && item.longitude)}
                title={
                  item.latitude && item.longitude
                    ? 'Copy these coordinates into the verified fields'
                    : 'Nothing was captured, so there is nothing to verify'
                }
              >
                Verify
              </Button>
              <Button
                size="sm"
                variant="ghost"
                onClick={() => decide(item, false)}
                disabled={busy !== null}
                title="Send it back for the rep to capture again"
              >
                Send back
              </Button>
            </div>
          </Card>
        ))}
      </div>

      {!loading && rows.length > 0 && (
        <p className="note" style={{ marginTop: 12 }}>
          Verifying copies the captured coordinates into the verified fields — those are what the
          100 m punch-in check measures against. Sending one back returns it to “Not Captured”, so
          the rep is asked to capture it again rather than leaving a rejected reading that still
          looks like a location.
        </p>
      )}
    </div>
  );
}
