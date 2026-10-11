/**
 * Sync — one button in the header of every screen.
 *
 * From 24 September 2026 nothing syncs with SAP on a timer. Orders, stock and
 * credit limits move only when somebody presses this, or approves an order
 * (which raises the order flag by itself — see `decideOrder`).
 *
 * WHAT A PRESS DOES
 *
 * Frappe Cloud has no route to the SAP LAN, so nothing here talks to SAP. It
 * raises one flag per sync on that sync's ERPNext Single; a watcher on the
 * office server reads the flags every 5 seconds and runs whichever are up
 * (`sap-order-sync/Invoke-FlagWatch.ps1`). So there is nothing to await — the
 * button polls the statuses until they settle, then offers to reload.
 *
 * WHY IT OFFERS TO RELOAD RATHER THAN RELOADING
 *
 * A sync takes about half a minute. Remounting the page by itself when it
 * lands would throw away whatever the manager had started typing in the
 * meantime. The shared lists (orders, stock) refresh on their own the moment
 * the syncs settle; the page itself reloads on the click.
 *
 * WHO RAISES WHICH FLAG
 *
 * `syncsFor` in `domain/syncScope.ts` decides, and `SapRefreshPanel` asks the
 * same function. Orders: everybody. Stock (with the items and the two weight
 * UDFs): everybody except a login of another unit. Credit: the Manna Treads
 * sales team and the GM. Until 25 September 2026 stock and credit were for
 * Treads sales logins only, so the GM approved on credit figures he could not
 * refresh.
 *
 * A sync that cannot be asked, or whose status cannot be read, is not fatal:
 * the others still run, and the result names the one that did not answer.
 *
 * AT REST IT SAYS HOW OLD SAP'S FIGURES ARE (11 Oct 2026, the user's request)
 *
 * "Synced today 18:52", or "Orders sync failed · last good 27 Sep 14:52" — the
 * oldest last good run among this login's syncs, with every sync in the
 * tooltip (`syncSummary`). This button is the only thing that talks to SAP;
 * a page's Refresh re-reads ERPNext and nothing else.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { Api } from '@/api/client';
import { Button, Icon } from '@/components/ui';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { serverNow } from '@/domain/serverClock';
import { syncsFor, syncSummary, type SyncReading, type SyncSummary } from '@/domain/syncScope';

type Kind = 'orders' | 'stock' | 'credit';

const LABEL: Record<Kind, string> = {
  orders: 'orders',
  stock: 'stock',
  credit: 'credit limits',
};

/** Statuses meaning a run is waiting or in flight. */
const BUSY = new Set(['Queued', 'Running']);

const POLL_MS = 4_000;

/**
 * The watcher looks every 5 seconds and a run takes about 30, so a flag still
 * up after four minutes means the office side is not picking anything up.
 */
const GIVE_UP_MS = 4 * 60_000;

type Phase =
  | { kind: 'idle' }
  | { kind: 'waiting'; pending: Kind[] }
  | { kind: 'done'; failed: Kind[] }
  | { kind: 'stalled'; pending: Kind[] };

function list(kinds: Kind[]): string {
  const names = kinds.map((k) => LABEL[k]);
  if (names.length <= 1) return names.join('');
  return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}

function capitalise(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function ask(k: Kind): Promise<unknown> {
  if (k === 'orders') return Api.sales.requestOrderSync();
  if (k === 'stock') return Api.sales.requestStockSync();
  return Api.sales.requestSapSync();
}

async function read(k: Kind): Promise<{ busy: boolean; failed: boolean }> {
  if (k === 'orders') {
    const s = await Api.sales.getOrderSyncState();
    return { busy: s.queued || s.status === 'Running', failed: s.status === 'Failed' };
  }
  const s = k === 'stock' ? await Api.sales.getStockSyncStatus() : await Api.sales.getSapSyncStatus();
  return { busy: BUSY.has(s.status), failed: s.status === 'Failed' };
}

/** One sync's status and last good run, for the resting line. */
async function reading(k: Kind): Promise<SyncReading> {
  if (k === 'orders') {
    const s = await Api.sales.getOrderSyncState();
    return { kind: k, status: s.status, queued: s.queued, lastSyncAt: s.lastSyncAt };
  }
  const s = k === 'stock' ? await Api.sales.getStockSyncStatus() : await Api.sales.getSapSyncStatus();
  return { kind: k, status: s.status, lastSyncAt: s.lastSyncAt };
}

/** How often the resting line re-reads while the tab is in view. */
const REST_MS = 3 * 60_000;

export function SyncAllButton({
  onSettled,
  onReload,
}: {
  /** Called once every requested sync has settled, to refresh shared lists. */
  onSettled: () => void;
  /** Called when the user asks to reload the page they are on. */
  onReload: () => void;
}) {
  const user = useAppSelector(selectUser);
  const [phase, setPhase] = useState<Phase>({ kind: 'idle' });
  const [rest, setRest] = useState<SyncSummary | null>(null);
  const timer = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (timer.current) window.clearTimeout(timer.current);
    },
    [],
  );

  /** Re-reads every sync this login covers. One that will not answer is left out. */
  const readRest = useCallback(async () => {
    const kinds: Kind[] = syncsFor(user);
    const got = await Promise.allSettled(kinds.map(reading));
    const readings = got.flatMap((g) => (g.status === 'fulfilled' ? [g.value] : []));
    setRest(syncSummary(readings, serverNow()));
  }, [user]);

  // On sign-in, every few minutes while the tab is in view, and on coming back
  // to it — someone else's press, or approving an order, moves these too.
  useEffect(() => {
    void readRest();
    const every = window.setInterval(() => {
      if (document.visibilityState === 'visible') void readRest();
    }, REST_MS);
    const onFocus = () => void readRest();
    window.addEventListener('focus', onFocus);
    return () => {
      window.clearInterval(every);
      window.removeEventListener('focus', onFocus);
    };
  }, [readRest]);

  const watch = useCallback(
    (pending: Kind[], since: number, failed: Kind[]) => {
      timer.current = window.setTimeout(async () => {
        const still: Kind[] = [];
        const nowFailed = [...failed];
        for (const k of pending) {
          try {
            const s = await read(k);
            if (s.busy) still.push(k);
            else if (s.failed) nowFailed.push(k);
          } catch {
            // Unreadable is not "still going": stop waiting on it and say so.
            nowFailed.push(k);
          }
        }
        if (still.length === 0) {
          setPhase({ kind: 'done', failed: nowFailed });
          void readRest();
          onSettled();
          return;
        }
        if (Date.now() - since > GIVE_UP_MS) {
          setPhase({ kind: 'stalled', pending: still });
          return;
        }
        setPhase({ kind: 'waiting', pending: still });
        watch(still, since, nowFailed);
      }, POLL_MS);
    },
    [onSettled, readRest],
  );

  const press = useCallback(async () => {
    if (timer.current) window.clearTimeout(timer.current);
    const kinds: Kind[] = syncsFor(user);
    if (kinds.length === 0) return;
    setPhase({ kind: 'waiting', pending: kinds });
    const results = await Promise.allSettled(kinds.map(ask));
    const asked = kinds.filter((_, i) => results[i].status === 'fulfilled');
    const notAsked = kinds.filter((_, i) => results[i].status === 'rejected');
    if (asked.length === 0) {
      setPhase({ kind: 'done', failed: notAsked });
      return;
    }
    watch(asked, Date.now(), notAsked);
  }, [user, watch]);

  const busy = phase.kind === 'waiting';

  return (
    <div className="sync-all">
      {phase.kind === 'waiting' && (
        <span className="sync-all__status" title={`Syncing ${list(phase.pending)}`}>
          Syncing {list(phase.pending)}…
        </span>
      )}
      {/* At rest: the status and when SAP was last read. */}
      {phase.kind === 'idle' && rest && (
        <span
          className={`sync-all__status ${rest.tone === 'warn' ? 'is-warn' : ''}`}
          title={rest.detail}
          aria-live="polite"
        >
          {rest.text}
        </span>
      )}
      {phase.kind === 'done' && (
        <>
          <span
            className={`sync-all__status ${phase.failed.length || rest?.tone === 'warn' ? 'is-warn' : ''}`}
            title={phase.failed.length ? `Not synced: ${list(phase.failed)}` : rest?.detail}
          >
            {phase.failed.length
              ? `${capitalise(list(phase.failed))} not synced`
              : (rest?.text ?? 'Synced')}
          </span>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => {
              setPhase({ kind: 'idle' });
              onReload();
            }}
          >
            Reload
          </Button>
        </>
      )}
      {phase.kind === 'stalled' && (
        <span
          className="sync-all__status is-warn"
          title={`Queued: ${list(phase.pending)}. Runs when the office server picks it up.`}
        >
          Waiting for office server
        </span>
      )}
      <Button
        className="sync-all__btn"
        onClick={() => void press()}
        disabled={busy}
        aria-label="Sync with SAP"
        title="Sync with SAP"
      >
        <Icon name="refresh" className={busy ? 'is-spinning' : ''} />
        <span className="sync-all__label">Sync</span>
      </Button>
    </div>
  );
}
