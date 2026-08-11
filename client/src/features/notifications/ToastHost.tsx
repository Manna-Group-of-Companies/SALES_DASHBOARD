import { useEffect, useRef } from 'react';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { dismissToast } from '@/store/slices/notificationsSlice';

const ICON = { success: '✓', info: 'ℹ', warning: '⚠', critical: '⚠' } as const;
const TTL_MS = 4500;

/** Transient confirmations. The persistent record lives in the panel. */
export function ToastHost() {
  const dispatch = useAppDispatch();
  const toasts = useAppSelector((s) => s.notifications.toasts);

  /**
   * Timers are tracked per toast id. Scheduling them from a plain effect over
   * the whole array meant every new toast cleared and restarted the countdown
   * on the ones already showing, so a burst of activity could pin the first
   * message on screen indefinitely.
   */
  const timers = useRef(new Map<string, number>());

  useEffect(() => {
    const live = new Set(toasts.map((t) => t.id));

    // Drop timers for toasts that have already gone.
    timers.current.forEach((handle, id) => {
      if (!live.has(id)) {
        window.clearTimeout(handle);
        timers.current.delete(id);
      }
    });

    // Schedule newcomers once. Criticals stay until dismissed by hand.
    toasts.forEach((t) => {
      if (t.severity === 'critical' || timers.current.has(t.id)) return;
      const handle = window.setTimeout(() => {
        timers.current.delete(t.id);
        dispatch(dismissToast(t.id));
      }, TTL_MS);
      timers.current.set(t.id, handle);
    });
  }, [toasts, dispatch]);

  // Clear everything outstanding when the host unmounts (e.g. on sign-out).
  useEffect(() => {
    const handles = timers.current;
    return () => {
      handles.forEach((h) => window.clearTimeout(h));
      handles.clear();
    };
  }, []);

  if (!toasts.length) return null;

  return (
    <div className="toast-host" role="status" aria-live="polite">
      {toasts.map((t) => (
        <div key={t.id} className={`toast toast--${t.severity}`}>
          <span aria-hidden>{ICON[t.severity]}</span>
          <span className="grow">{t.message}</span>
          <button
            className="btn btn--ghost btn--sm btn--icon"
            onClick={() => dispatch(dismissToast(t.id))}
            aria-label="Dismiss"
          >
            ✕
          </button>
        </div>
      ))}
    </div>
  );
}
