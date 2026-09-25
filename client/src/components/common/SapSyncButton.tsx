/**
 * "Sync with SAP" for a page header, with the sync's status beside it.
 *
 * Replaces the plain Refresh button on screens whose figures come from SAP
 * (the production queue and order, 25 September 2026). A Refresh there only
 * re-read ERPNext, which since the timers went on 24 September is as fresh as
 * the last time anybody pressed Sync — so it looked like it did something and
 * mostly did not. This asks SAP, waits for the office server to answer, then
 * re-reads the page.
 *
 * What it says, and when:
 *
 *   - resting:          "Synced 12 minutes ago"  (or "Last sync failed")
 *   - asked, waiting:   "Waiting for the office server…"
 *   - running:          "Syncing with SAP…"
 *   - finished:         re-reads the page, then "Synced just now"
 *   - nobody answering: says so after three minutes, instead of spinning
 *
 * Frappe Cloud cannot reach SAP, so a press raises a flag that a watcher on
 * the office server reads every 15 seconds (`Invoke-FlagWatch.ps1`). The
 * header's Sync button asks every sync at once; this asks only the one the
 * page is built from.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { Api } from '@/api/client';
import { agoText } from '@/domain/serverDate';
import { serverNow } from '@/domain/serverClock';
import { useAppDispatch } from '@/store/hooks';
import { pushToast } from '@/store/slices/notificationsSlice';
import { Button } from '@/components/ui';

/** One sync's state, in the shape this button reads. */
export interface SyncReading {
  status: 'Idle' | 'Queued' | 'Running' | 'Success' | 'Failed';
  lastSyncAt: string | null;
  message: string;
}

export interface SapSyncTarget {
  /** What is being synced, for messages — "orders", "stock". */
  what: string;
  read: () => Promise<SyncReading>;
  request: () => Promise<void>;
}

/** The order sync: pushes approved orders, brings SAP's status and invoices back. */
export const ORDER_SYNC: SapSyncTarget = {
  what: 'orders',
  read: async () => {
    const s = await Api.sales.getOrderSyncState();
    // The Single has no Queued status: a waiting request is the raised flag.
    const status =
      s.status === 'Running'
        ? 'Running'
        : s.queued
          ? 'Queued'
          : s.status === 'Failed'
            ? 'Failed'
            : s.status === 'Success'
              ? 'Success'
              : 'Idle';
    return { status, lastSyncAt: s.lastSyncAt, message: s.lastResultMessage };
  },
  request: async () => {
    await Api.sales.requestOrderSync();
  },
};

const POLL_MS = 3_000;
/** The watcher looks every 15 s and waits out a pause of a minute at most. */
const UNCLAIMED_MS = 3 * 60_000;
/** Thirty times a normal run; a poller that never writes back cannot spin for ever. */
const GIVE_UP_MS = 6 * 60_000;

const busy = (r: SyncReading | null) => r?.status === 'Queued' || r?.status === 'Running';

export function SapSyncButton({
  target,
  onSynced,
}: {
  target: SapSyncTarget;
  /** Re-read the page. Called once a run the button was watching succeeds. */
  onSynced: () => void;
}) {
  const dispatch = useAppDispatch();
  const [reading, setReading] = useState<SyncReading | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [askedAt, setAskedAt] = useState<number | null>(null);
  const [asking, setAsking] = useState(false);
  /** Ticks every 15 s so "12 minutes ago" and the unclaimed warning stay true. */
  const [, setTick] = useState(0);
  const polling = useRef(false);
  // Held in a ref so the polling loop does not depend on it: a page passing a
  // fresh arrow each render would otherwise restart — and so stop — the loop.
  const onSyncedRef = useRef(onSynced);
  useEffect(() => {
    onSyncedRef.current = onSynced;
  }, [onSynced]);

  const { read, request, what } = target;

  const readOnce = useCallback(async () => {
    try {
      const r = await read();
      setReading(r);
      setError(null);
      return r;
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Could not read the sync status.');
      return null;
    }
  }, [read]);

  const watch = useCallback(async () => {
    if (polling.current) return;
    polling.current = true;
    const started = Date.now();
    try {
      while (polling.current && Date.now() - started < GIVE_UP_MS) {
        await new Promise((res) => setTimeout(res, POLL_MS));
        if (!polling.current) return;
        const r = await readOnce();
        if (r && !busy(r)) {
          if (r.status === 'Success') {
            onSyncedRef.current();
            dispatch(pushToast(`Synced ${what} with SAP.`, 'success'));
          } else {
            dispatch(pushToast(r.message || `The SAP sync of ${what} failed.`, 'warning'));
          }
          setAskedAt(null);
          return;
        }
      }
    } finally {
      polling.current = false;
    }
  }, [readOnce, dispatch, what]);

  useEffect(() => {
    void readOnce().then((r) => {
      // Somebody else's run may be in flight — follow it.
      if (busy(r)) void watch();
    });
    const t = window.setInterval(() => setTick((n) => n + 1), 15_000);
    return () => {
      window.clearInterval(t);
      polling.current = false;
    };
  }, [readOnce, watch]);

  const press = async () => {
    setAsking(true);
    try {
      await request();
      setAskedAt(Date.now());
      setReading((r) => ({ status: 'Queued', lastSyncAt: r?.lastSyncAt ?? null, message: '' }));
      void watch();
    } catch (e: unknown) {
      dispatch(
        pushToast(e instanceof Error ? e.message : 'Could not reach the sync service.', 'critical'),
      );
    } finally {
      setAsking(false);
    }
  };

  const now = serverNow();
  const running = reading?.status === 'Running';
  const queued = reading?.status === 'Queued';
  const unclaimed = queued && askedAt !== null && Date.now() - askedAt > UNCLAIMED_MS;

  let text: string;
  let tone: string;
  if (error) {
    text = 'Sync status unavailable';
    tone = 'var(--danger, #b91c1c)';
  } else if (unclaimed) {
    text = 'The office server has not picked this up — tell IT';
    tone = 'var(--warn, #b45309)';
  } else if (running) {
    text = 'Syncing with SAP…';
    tone = 'var(--text-2, inherit)';
  } else if (queued) {
    text = 'Waiting for the office server…';
    tone = 'var(--text-2, inherit)';
  } else if (reading?.status === 'Failed') {
    text = `Last sync failed · ${agoText(reading.lastSyncAt, now)}`;
    tone = 'var(--danger, #b91c1c)';
  } else {
    text = `Synced ${agoText(reading?.lastSyncAt, now)}`;
    tone = 'var(--text-3, inherit)';
  }

  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
      <span
        className="small"
        style={{ color: tone }}
        title={error ?? (reading?.status === 'Failed' ? reading.message : undefined)}
        aria-live="polite"
      >
        {text}
      </span>
      <Button
        size="sm"
        variant="primary"
        onClick={() => void press()}
        loading={asking || busy(reading)}
        disabled={asking || busy(reading)}
      >
        ⟳ Sync with SAP
      </Button>
    </span>
  );
}
