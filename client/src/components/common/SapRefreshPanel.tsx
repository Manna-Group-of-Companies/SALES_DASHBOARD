/**
 * "Reload from SAP" — an on-demand refresh of something the office server
 * copies out of SAP. Credit limits and warehouse stock both use it.
 *
 * HOW IT WORKS, AND WHY IT IS NOT A NORMAL BUTTON
 *
 * Frappe Cloud cannot reach the SAP LAN, so this never speaks to SAP. Pressing
 * the button raises a flag on a Single doc; a watcher on the office server
 * reads the flags every 15 seconds, runs the sync, and writes the outcome
 * back. So there is no response to await — the page polls until the status
 * settles, and shows the result where the button is rather than leaving
 * anyone to refresh and go looking. From 24 Sep 2026 nothing runs on a timer:
 * this, and the Sync button in the header, are the only way these refresh.
 *
 * THE COOLDOWN SPACES RUNS; IT NEVER REFUSES ONE
 *
 * It was 25 minutes, because leaked Service Layer sessions aged out at SAP's
 * 30-minute idle timeout and a fresh login inside that window returned HTTP
 * 500 — two days went into diagnosing that. The sync scripts now always log
 * out in a `finally`, and on 9 September 2026 the Service Layer was verified
 * handling back-to-back logins, four concurrent sessions and six consecutive
 * runs with no gap, every one under ten seconds.
 *
 * So it is a minute or two now (credit 2, stock 1), there only so rapid
 * presses cannot stack SAP logins. Since 24 Sep 2026 a press inside it is
 * queued, not refused: the office poller runs it as soon as the pause is over,
 * and the Server Script's message says how long that is. The button therefore
 * stays live; the pause is only explained.
 *
 * The countdown is drawn from `cooldown_until` returned by the server, never
 * from a timer started locally. A clock that began when this tab opened would
 * disagree with the one keeping the pause.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import type { SapSyncRequestResult, SapSyncState } from '@/api/client';
import { serverNow } from '@/domain/serverClock';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { pushToast } from '@/store/slices/notificationsSlice';
import { Alert, Button, Card } from '@/components/ui';

/** Statuses where a run is in flight and the page should keep polling. */
const BUSY = new Set(['Queued', 'Running']);

/**
 * How long a request may sit unclaimed before the panel says so.
 *
 * The watcher looks every 15 seconds, and the longest a request may wait on
 * the pause after a run is two minutes. Three minutes unclaimed means it is
 * not looking — the task is not running, or its login to ERPNext is being
 * refused — and the person who pressed the button should hear that rather
 * than watch "Syncing…" until the polling gives up. That was every sync on
 * this server from 22 September 2026, when the ERPNext API secret stopped
 * working.
 */
const UNCLAIMED_AFTER_MS = 3 * 60_000;

export interface SapRefreshTarget {
  /** Card heading — "Credit limits from SAP". */
  title: string;
  getStatus: () => Promise<SapSyncState>;
  request: () => Promise<SapSyncRequestResult>;
  /** What `lastRowsChanged` counts, singular — "customer", "item". */
  noun: string;
  /** Said under the button while a run is in flight. */
  busyNote: string;
  /** Called once a run finishes successfully, so the page can re-read. */
  onSynced?: () => void;
}

/**
 * A server datetime, whichever way the Server Script wrote it.
 *
 * The credit scripts send `isoformat()`; the stock scripts send Python's
 * `str()` — `2026-09-24 16:33:26.747115`, a space and microseconds. Chrome
 * reads both. Safari reads the second as Invalid Date, which would put "Last
 * synced: Never" and no cooldown on every iPhone. So the space becomes a `T`
 * and the fraction is cut to milliseconds before parsing. Either way it is
 * read as local time, as it always was.
 */
function parseServerDate(v: string | null | undefined): number {
  if (!v) return NaN;
  const m = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2})?)(\.\d{1,3})?\d*$/.exec(v.trim());
  return new Date(m ? `${m[1]}T${m[2]}${m[3] ?? ''}` : v).getTime();
}

/** How long ago, in words. Exact timestamps say less than "12 minutes ago". */
function relative(iso: string | null, now: Date): string {
  const then = parseServerDate(iso);
  if (Number.isNaN(then)) return 'Never';
  const mins = Math.floor((now.getTime() - then) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins} minute${mins === 1 ? '' : 's'} ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs} hour${hrs === 1 ? '' : 's'} ago`;
  const days = Math.floor(hrs / 24);
  return `${days} day${days === 1 ? '' : 's'} ago`;
}

function mmss(seconds: number): string {
  const s = Math.max(0, Math.ceil(seconds));
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}

export function SapRefreshPanel({ target }: { target: SapRefreshTarget }) {
  const dispatch = useAppDispatch();
  const user = useAppSelector(selectUser);

  const [state, setState] = useState<SapSyncState | null>(null);
  const [asking, setAsking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** Ticks once a second so the countdown and "x minutes ago" stay honest. */
  const [, setTick] = useState(0);

  // Held in a ref so the polling loop can stop itself without re-subscribing.
  const polling = useRef(false);

  const { getStatus, request: ask, onSynced } = target;

  /*
   * Manna Treads only. Both syncs write into Manna Treads — credit limits from
   * MANNA_TREADS_LIVE, stock into `Finished Goods - MT` — so a Retreads or UAE
   * login pressing this would spend the SAP login and the cooldown on a book
   * that is not theirs, and read "0 changed" every time without being told
   * why. The credit Server Script refuses them; the stock one accepts any
   * signed-in user, because reps promise from that stock. Either way this is
   * where the button is offered, and the status poll only runs for Treads.
   */
  const isTreads = user?.salesCompany === 'Manna Treads';

  const read = useCallback(async () => {
    try {
      const s = await getStatus();
      setState(s);
      setError(null);
      return s;
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Could not read the sync status.');
      return null;
    }
  }, [getStatus]);

  useEffect(() => {
    if (isTreads) void read();
  }, [read, isTreads]);

  useEffect(() => {
    const t = window.setInterval(() => setTick((n) => n + 1), 1000);
    return () => window.clearInterval(t);
  }, []);

  /*
   * Poll every 3 seconds until the run settles, then say what happened once.
   *
   * Three, because a run finishes in seconds — at a ten-second interval a sync
   * that had already succeeded could sit looking unfinished for most of its
   * own duration. The ceiling below stops a poller that never writes back from
   * spinning forever. The loop stops on unmount.
   */
  const pollUntilSettled = useCallback(async () => {
    if (polling.current) return;
    polling.current = true;
    try {
      // Five minutes: thirty times a normal run.
      for (let i = 0; i < 100 && polling.current; i += 1) {
        await new Promise((r) => setTimeout(r, 3_000));
        if (!polling.current) return;
        const s = await read();
        if (s && !BUSY.has(s.status)) {
          dispatch(
            pushToast(
              s.lastResultMessage || `SAP sync ${s.status.toLowerCase()}.`,
              s.status === 'Success' ? 'success' : 'warning',
            ),
          );
          if (s.status === 'Success') onSynced?.();
          return;
        }
      }
    } finally {
      polling.current = false;
    }
  }, [dispatch, read, onSynced]);

  useEffect(() => {
    // Someone else may have started a run — pick up a live one on mount.
    if (state && BUSY.has(state.status)) void pollUntilSettled();
    return () => {
      polling.current = false;
    };
  }, [state, pollUntilSettled]);

  const now = serverNow();
  const busy = state ? BUSY.has(state.status) : false;
  const cooldownAt = parseServerDate(state?.cooldownUntil);
  const cooldownLeft = Number.isFinite(cooldownAt) ? (cooldownAt - now.getTime()) / 1000 : 0;
  const cooling = cooldownLeft > 0;
  const requestedAt = parseServerDate(state?.requestedAt);
  const unclaimed =
    state?.status === 'Queued' &&
    Number.isFinite(requestedAt) &&
    now.getTime() - requestedAt > UNCLAIMED_AFTER_MS;

  const request = async () => {
    setAsking(true);
    try {
      const r = await ask();
      // Always queued. The server's message is the one to show: only it knows
      // whether a run is in flight or the pause after one is still open, and
      // so how long this request will wait.
      dispatch(pushToast(r.message, r.ok ? 'success' : 'warning'));
      await read();
      void pollUntilSettled();
    } catch (e: unknown) {
      dispatch(
        pushToast(
          e instanceof Error ? e.message : 'Could not reach the sync service.',
          'critical',
        ),
      );
    } finally {
      setAsking(false);
    }
  };

  const label = busy ? `Syncing… (${state?.status.toLowerCase()})` : 'Reload from SAP';

  if (!isTreads) return null;

  return (
    <Card title={target.title}>
      {error && (
        <Alert tone="danger" title="Could not read the sync status">
          {error}
        </Alert>
      )}

      <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
        <Button
          variant="primary"
          onClick={() => void request()}
          disabled={busy || asking}
          loading={asking || busy}
        >
          {label}
        </Button>
        <span className="small dim">
          Last synced from SAP: <b>{relative(state?.lastSyncAt ?? null, now)}</b>
        </span>
      </div>

      {unclaimed && (
        <div style={{ marginTop: 10 }}>
          <Alert tone="warn" title="Nobody has picked this request up">
            It was queued {relative(state?.requestedAt ?? null, now)} and the office server has not
            started it. The SAP link on that server is down or cannot sign in to ERPNext — the
            figures on this page are from the last successful sync. Tell IT.
          </Alert>
        </div>
      )}

      {busy && !unclaimed && (
        // Said inline as well as in a toast. A toast can be missed or
        // dismissed, and the person who pressed the button is looking at the
        // button.
        <p className="small" style={{ marginTop: 10, marginBottom: 0 }}>
          {target.busyNote}
        </p>
      )}

      {!busy && state?.lastResultMessage && (
        <p className="small" style={{ marginTop: 10, marginBottom: 0 }}>
          {state.lastResultMessage}
          {state.lastRowsChanged > 0 && (
            <>
              {' · '}
              <b>{state.lastRowsChanged}</b> {target.noun}
              {state.lastRowsChanged === 1 ? '' : 's'} changed
            </>
          )}
          {state.lastSyncAt && state.status === 'Success' && (
            <span className="dim"> · {relative(state.lastSyncAt, now)}</span>
          )}
        </p>
      )}

      {cooling && !busy && (
        <p className="small dim" style={{ marginTop: 6, marginBottom: 0 }}>
          {/* Said plainly, so a request that takes a minute to start is not
              mistaken for one that was lost. */}
          Read from SAP a moment ago. Another reload now starts in{' '}
          {mmss(cooldownLeft)}, once the short pause between syncs is over.
        </p>
      )}
    </Card>
  );
}
