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
 * office server reads the flags every 15 seconds and runs whichever are up
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
 * The order sync: everybody. Stock and credit limits: the Manna Treads team
 * only — the rule `SapRefreshPanel` and both Server Scripts apply, since those
 * two syncs write into Manna Treads' books.
 *
 * A sync that cannot be asked, or whose status cannot be read, is not fatal:
 * the others still run, and the result names the one that did not answer.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { Api } from '@/api/client';
import { Button } from '@/components/ui';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';

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
 * The watcher looks every 15 seconds and a run takes about 30, so a flag still
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
  const isTreads = user?.salesCompany === 'Manna Treads';
  const [phase, setPhase] = useState<Phase>({ kind: 'idle' });
  const timer = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (timer.current) window.clearTimeout(timer.current);
    },
    [],
  );

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
    [onSettled],
  );

  const press = useCallback(async () => {
    if (timer.current) window.clearTimeout(timer.current);
    const kinds: Kind[] = isTreads ? ['orders', 'stock', 'credit'] : ['orders'];
    setPhase({ kind: 'waiting', pending: kinds });
    const results = await Promise.allSettled(kinds.map(ask));
    const asked = kinds.filter((_, i) => results[i].status === 'fulfilled');
    const notAsked = kinds.filter((_, i) => results[i].status === 'rejected');
    if (asked.length === 0) {
      setPhase({ kind: 'done', failed: notAsked });
      return;
    }
    watch(asked, Date.now(), notAsked);
  }, [isTreads, watch]);

  const busy = phase.kind === 'waiting';

  return (
    <div className="sync-all">
      {phase.kind === 'waiting' && <span className="tiny dim">Syncing {list(phase.pending)}…</span>}
      {phase.kind === 'done' && (
        <>
          <span className="tiny dim">
            {phase.failed.length === 0
              ? 'Synced with SAP'
              : `Synced — ${list(phase.failed)} did not go through`}
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
          className="tiny dim"
          title="The request is saved and will run when the office sync picks it up."
        >
          Waiting on the office server for {list(phase.pending)}
        </span>
      )}
      <button
        className={`bell ${busy ? 'bell--busy' : ''}`}
        onClick={() => void press()}
        disabled={busy}
        aria-label="Sync with SAP"
        title={busy ? 'Syncing with SAP' : 'Sync with SAP — fetch the latest orders, stock and credit'}
      >
        ⟳
      </button>
    </div>
  );
}
