/**
 * "Reload from SAP" — the on-demand credit-limit refresh.
 *
 * HOW IT WORKS, AND WHY IT IS NOT A NORMAL BUTTON
 *
 * Frappe Cloud cannot reach the SAP LAN, so this never speaks to SAP. Pressing
 * the button raises a flag on a Single doc; a poller on the on-prem Windows
 * server picks it up within about two minutes, runs the sync, and writes the
 * outcome back. So there is no response to await — the page polls until the
 * status settles.
 *
 * THE COOLDOWN IS NOT A UI PREFERENCE
 *
 * The SAP Service Layer licence pool is tiny. Logging in inside the window
 * returns HTTP 500 for 20-30 minutes and takes the integration down for
 * everyone — two days were spent diagnosing exactly that. The refusal
 * therefore lives in the `manna_sap_request_sync` Server Script, where a
 * browser console cannot reach it. Everything here only *explains* the
 * refusal; disabling the button is a courtesy, not the control.
 *
 * The countdown is drawn from `cooldown_until` returned by the server, never
 * from a timer started locally. A clock that began when this tab opened would
 * disagree with the one enforcing the rule.
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { Api, type SapSyncState } from '@/api/client';
import { serverNow } from '@/domain/serverClock';
import { useAppDispatch } from '@/store/hooks';
import { pushToast } from '@/store/slices/notificationsSlice';
import { Alert, Button, Card } from '@/components/ui';

/** Statuses where a run is in flight and the page should keep polling. */
const BUSY = new Set(['Queued', 'Running']);

/** How long ago, in words. Exact timestamps say less than "12 minutes ago". */
function relative(iso: string | null, now: Date): string {
  if (!iso) return 'Never';
  const then = new Date(iso);
  if (Number.isNaN(then.getTime())) return 'Never';
  const mins = Math.floor((now.getTime() - then.getTime()) / 60000);
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

export function SapSyncPanel() {
  const dispatch = useAppDispatch();

  const [state, setState] = useState<SapSyncState | null>(null);
  const [asking, setAsking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** Ticks once a second so the countdown and "x minutes ago" stay honest. */
  const [, setTick] = useState(0);

  // Held in a ref so the polling loop can stop itself without re-subscribing.
  const polling = useRef(false);

  const read = useCallback(async () => {
    try {
      const s = await Api.sales.getSapSyncStatus();
      setState(s);
      setError(null);
      return s;
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Could not read the sync status.');
      return null;
    }
  }, []);

  useEffect(() => {
    void read();
  }, [read]);

  useEffect(() => {
    const t = window.setInterval(() => setTick((n) => n + 1), 1000);
    return () => window.clearInterval(t);
  }, []);

  /*
   * Poll every 10 seconds until the run settles, then say what happened once.
   *
   * Ten seconds because a run takes about two minutes: often enough that the
   * result feels prompt, rare enough that a forgotten open tab is not hammering
   * the site all afternoon. The loop stops on unmount.
   */
  const pollUntilSettled = useCallback(async () => {
    if (polling.current) return;
    polling.current = true;
    try {
      // A hard ceiling, so a poller that never writes back cannot leave this
      // spinning forever. Ten minutes is five times a normal run.
      for (let i = 0; i < 60 && polling.current; i += 1) {
        await new Promise((r) => setTimeout(r, 10_000));
        if (!polling.current) return;
        const s = await read();
        if (s && !BUSY.has(s.status)) {
          dispatch(
            pushToast(
              s.lastResultMessage || `SAP sync ${s.status.toLowerCase()}.`,
              s.status === 'Success' ? 'success' : 'warning',
            ),
          );
          return;
        }
      }
    } finally {
      polling.current = false;
    }
  }, [dispatch, read]);

  useEffect(() => {
    // Someone else may have started a run — pick up a live one on mount.
    if (state && BUSY.has(state.status)) void pollUntilSettled();
    return () => {
      polling.current = false;
    };
  }, [state, pollUntilSettled]);

  const now = serverNow();
  const busy = state ? BUSY.has(state.status) : false;
  const cooldownLeft = state?.cooldownUntil
    ? (new Date(state.cooldownUntil).getTime() - now.getTime()) / 1000
    : 0;
  const cooling = cooldownLeft > 0;

  const request = async () => {
    setAsking(true);
    try {
      const r = await Api.sales.requestSapSync();
      // A refusal is a normal answer, not a failure: the server is the only
      // thing that knows whether the licence pool can take another login.
      dispatch(pushToast(r.message, r.ok ? 'success' : 'warning'));
      await read();
      if (r.ok) void pollUntilSettled();
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

  const label = busy
    ? `Syncing… (${state?.status.toLowerCase()})`
    : cooling
      ? `Next refresh in ${mmss(cooldownLeft)}`
      : 'Reload from SAP';

  return (
    <Card title="Credit limits from SAP">
      {error && (
        <Alert tone="danger" title="Could not read the sync status">
          {error}
        </Alert>
      )}

      <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
        <Button
          variant="primary"
          onClick={() => void request()}
          disabled={busy || cooling || asking}
          loading={asking || busy}
        >
          {label}
        </Button>
        <span className="small dim">
          Last synced from SAP: <b>{relative(state?.lastSyncAt ?? null, now)}</b>
        </span>
      </div>

      {state?.lastResultMessage && (
        <p className="small" style={{ marginTop: 10, marginBottom: 0 }}>
          {state.lastResultMessage}
          {state.lastRowsChanged > 0 && (
            <>
              {' · '}
              <b>{state.lastRowsChanged}</b> customer
              {state.lastRowsChanged === 1 ? '' : 's'} changed
            </>
          )}
        </p>
      )}

      {cooling && (
        <p className="small dim" style={{ marginTop: 6, marginBottom: 0 }}>
          {/* Said plainly, because "why is the button greyed out" is otherwise a
              question somebody asks IT rather than reads off the screen. */}
          SAP allows one refresh every 25 minutes. Each customer&rsquo;s own
          &ldquo;last synced&rdquo; date is on their record.
        </p>
      )}
    </Card>
  );
}
