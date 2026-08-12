/**
 * Location verification — its own screen, and only this.
 *
 * Kept apart from order approval on purpose. Approving an order fixes a price
 * permanently and commits stock; verifying a location is recognising a
 * shopfront. Those need different attention, and putting them in one queue
 * means whichever is more numerous buries the other — there are 74 locations
 * waiting and a handful of orders, so the orders would vanish.
 *
 * **The photograph is the decision.** A manager verifies by recognising the
 * place, not by reading coordinates, so the image gets the room and everything
 * else sits underneath it. Clicking one opens it full size, because a shop
 * sign is often the only thing that identifies a small roadside unit and a
 * thumbnail will not resolve it.
 *
 * Approving copies the captured coordinates into the **verified** fields.
 * Those are what the 100 m punch-in check measures against — verifying without
 * copying them verifies nobody.
 */

import { useEffect, useMemo, useState } from 'react';
import type { LocationCheck, SalesPerson } from '@/domain/types';
import { scopeFor, NO_TEAM_MESSAGE } from '@/domain/sales';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Input, Segmented, Select } from '@/components/ui';
import { Tile } from '@/components/common/Tile';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/hr/attendance.css';
import './approvals.css';

type Kind = 'all' | 'customer' | 'lead' | 'site';

export function LocationVerificationPage() {
  const user = useAppSelector(selectUser);

  const [queue, setQueue] = useState<LocationCheck[]>([]);
  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [kind, setKind] = useState<Kind>('all');
  const [rep, setRep] = useState('');
  const [query, setQuery] = useState('');
  const [zoomed, setZoomed] = useState<LocationCheck | null>(null);
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.attendance
      .listSalesPeople()
      .then(async (p) => {
        if (!live) return;
        setPeople(p);
        // A manager only ever decides their own team's captures.
        const team = scopeFor(p, user?.salesPerson);
        /* Fail closed: an unresolved team must show nothing, never everyone. */
        if (!team) {
          setError(NO_TEAM_MESSAGE);
          return;
        }
        const q = await Api.sales.listLocationQueue(team);
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

  /** Close the enlarged photo on Escape, as any lightbox should. */
  useEffect(() => {
    if (!zoomed) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setZoomed(null);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [zoomed]);

  /** Only reps who actually have something waiting — an empty option is noise. */
  const repOptions = useMemo(() => {
    const waiting = new Set(queue.map((q) => q.capturedBy || q.rep).filter(Boolean));
    return people
      .filter((p) => p.enabled && !p.isGroup && waiting.has(p.id))
      .sort((a, b) => a.name.localeCompare(b.name));
  }, [people, queue]);

  const rows = useMemo(() => {
    let list = queue;
    if (kind !== 'all') list = list.filter((q) => q.kind === kind);
    if (rep) list = list.filter((q) => q.capturedBy === rep || q.rep === rep);
    const s = query.trim().toLowerCase();
    if (s) list = list.filter((q) => q.name.toLowerCase().includes(s));
    return list;
  }, [queue, kind, rep, query]);

  const counts = useMemo(
    () => ({
      customers: queue.filter((q) => q.kind === 'customer').length,
      leads: queue.filter((q) => q.kind === 'lead').length,
      noPhoto: queue.filter((q) => !q.bannerPhoto).length,
    }),
    [queue],
  );

  /** How many each rep has waiting, so the dropdown shows the workload. */
  const perRep = useMemo(() => {
    const m = new Map<string, number>();
    for (const q of queue) {
      const who = q.capturedBy || q.rep;
      if (who) m.set(who, (m.get(who) ?? 0) + 1);
    }
    return m;
  }, [queue]);

  const decide = async (item: LocationCheck, approve: boolean) => {
    setBusy(`${item.kind}-${item.id}`);
    setError(null);
    try {
      await Api.sales.decideLocation({
        kind: item.kind,
        id: item.id,
        approve,
        latitude: item.latitude,
        longitude: item.longitude,
      });
      // Drop it from the queue rather than refetching thousands of records to
      // discover the one row that changed.
      setQueue((cur) => cur.filter((q) => !(q.id === item.id && q.kind === item.kind)));
      setZoomed(null);
      setDone(
        approve
          ? `${item.name} verified — its coordinates are now the ones punch-in is measured against.`
          : `${item.name} sent back. The rep is asked to capture it again.`,
      );
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
          <div className="page-head__title">Location verification</div>
          <div className="page-head__sub">
            Check the photo against the name, then verify or send it back
          </div>
        </div>
        <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
      </div>

      {error && (
        <Alert tone="danger" title="Could not read or save">
          {error}
        </Alert>
      )}
      {done && !error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="ok" title={done} />
        </div>
      )}

      <div className="tiles" style={{ marginBottom: 14 }}>
        <Tile
          label="Waiting on you"
          value={String(queue.length)}
          tone={queue.length ? 'warn' : 'ok'}
          foot={queue.length ? 'Captures to check' : 'Queue clear'}
        />
        <Tile label="Customers" value={String(counts.customers)} foot="Already on the books" />
        <Tile label="Leads" value={String(counts.leads)} foot="Not yet converted" />
        <Tile
          label="No photo"
          value={String(counts.noPhoto)}
          tone={counts.noPhoto ? 'warn' : undefined}
          foot="Nothing to recognise"
        />
      </div>

      <div className="cal__toolbar">
        <Select value={rep} onChange={(e) => setRep(e.target.value)} aria-label="Representative">
          <option value="">All representatives ({queue.length})</option>
          {repOptions.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name} ({perRep.get(p.id) ?? 0})
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
        <Input
          placeholder="Search by name…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          aria-label="Search the queue"
        />
      </div>

      {loading && <Empty icon="◔" title="Reading the queue…" />}

      {!loading && !error && rows.length === 0 && (
        <Empty icon="✓" title="Nothing waiting on a location decision">
          {queue.length > 0
            ? 'Nothing matches this filter — clear the rep or the search.'
            : 'A capture appears here the first time a rep visits a shop.'}
        </Empty>
      )}

      <div className="loc__grid">
        {rows.map((item) => {
          const key = `${item.kind}-${item.id}`;
          const hasFix = Boolean(item.latitude && item.longitude);
          return (
            <Card
              key={key}
              title={
                <span className="odo__title">
                  <span>{item.name}</span>
                  <Badge tone={item.kind === 'lead' ? 'accent' : item.kind === 'site' ? 'warn' : 'neutral'}>
                    {item.kind}
                  </Badge>
                </span>
              }
            >
              {/* The photo is the decision, so it leads and it is large. */}
              <div className="loc__photo">
                {item.bannerPhoto ? (
                  <button
                    type="button"
                    className="loc__zoom"
                    onClick={() => setZoomed(item)}
                    title="Click to see it full size"
                  >
                    <img src={item.bannerPhoto} alt={`${item.name} shopfront`} loading="lazy" />
                    <span className="loc__zoom-hint">Click to enlarge</span>
                  </button>
                ) : (
                  <div className="loc__photo--empty">
                    No shop photo was captured.
                    <br />
                    There is nothing to recognise this place by.
                  </div>
                )}
              </div>

              {/*
                Everything on the record, because the decision is whether the
                photograph is this place. A sign matches a name, a town and a
                trade — not a document id — and the mobile number is the only
                way to query a doubtful one without going back through the rep.
              */}
              <table className="table loc__facts">
                <tbody>
                  {item.companyName && (
                    <tr>
                      <td className="dim">Trading as</td>
                      <td>{item.companyName}</td>
                    </tr>
                  )}
                  {item.shopType && (
                    <tr>
                      <td className="dim">Trade</td>
                      <td>{item.shopType}</td>
                    </tr>
                  )}
                  {(item.city || item.address) && (
                    <tr>
                      <td className="dim">Place</td>
                      <td>
                        {item.city && <b>{item.city}</b>}
                        {item.city && item.address && item.address !== item.city && ' · '}
                        {item.address !== item.city ? item.address : ''}
                      </td>
                    </tr>
                  )}
                  <tr>
                    <td className="dim">Mobile</td>
                    <td>
                      {item.mobile ? (
                        <a href={`tel:${item.mobile}`}>{item.mobile}</a>
                      ) : (
                        <span className="dim">not recorded</span>
                      )}
                    </td>
                  </tr>
                  {item.gstin && (
                    <tr>
                      <td className="dim">GST</td>
                      <td className="mono small">{item.gstin}</td>
                    </tr>
                  )}
                  <tr>
                    <td className="dim">Captured by</td>
                    <td>{item.capturedBy || item.rep || '—'}</td>
                  </tr>
                  <tr>
                    <td className="dim">Route</td>
                    <td>{item.route || <span className="dim">none set</span>}</td>
                  </tr>
                  <tr>
                    <td className="dim">Coordinates</td>
                    <td className="num">
                      {hasFix ? (
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
                  <tr>
                    <td className="dim">Record</td>
                    <td className="mono tiny dim">{item.id}</td>
                  </tr>
                </tbody>
              </table>

              <div className="loc__actions">
                <Button
                  size="sm"
                  onClick={() => decide(item, true)}
                  loading={busy === key}
                  disabled={busy !== null || !hasFix}
                  title={
                    hasFix
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
          );
        })}
      </div>

      {/*
        Full-size photo. A shop sign is often the only thing identifying a small
        roadside unit, and a card-sized thumbnail will not resolve it — so the
        decision buttons come with the enlarged view rather than making the
        manager close it and find the card again.
      */}
      {zoomed && (
        <div
          className="lightbox"
          role="dialog"
          aria-modal="true"
          aria-label={`${zoomed.name} shopfront`}
          onClick={() => setZoomed(null)}
        >
          <div className="lightbox__inner" onClick={(e) => e.stopPropagation()}>
            <img src={zoomed.bannerPhoto} alt={`${zoomed.name} shopfront`} />
            <div className="lightbox__bar">
              <span className="grow">
                <b>{zoomed.name}</b>
                <span className="dim small">
                  {' '}
                  · captured by {zoomed.capturedBy || zoomed.rep || 'unknown'}
                </span>
              </span>
              <Button
                size="sm"
                onClick={() => decide(zoomed, true)}
                loading={busy === `${zoomed.kind}-${zoomed.id}`}
                disabled={busy !== null || !(zoomed.latitude && zoomed.longitude)}
              >
                Verify
              </Button>
              <Button
                size="sm"
                variant="ghost"
                onClick={() => decide(zoomed, false)}
                disabled={busy !== null}
              >
                Send back
              </Button>
              <Button size="sm" variant="ghost" onClick={() => setZoomed(null)}>
                Close
              </Button>
            </div>
          </div>
        </div>
      )}

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
