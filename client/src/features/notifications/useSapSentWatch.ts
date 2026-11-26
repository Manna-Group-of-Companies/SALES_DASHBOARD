/**
 * Tells a sales manager or the GM when an order reaches SAP (the user,
 * 26 Nov 2026: "for now only the manager and the GM"; reps are not told).
 *
 * There is no server push and the bell's server store does not exist on the
 * live site, so this browser works it out: every minute it reads the orders
 * changed in the last week and `sapSentNews` says which have a SAP number they
 * did not have at the last look. Each one goes in the bell, as a toast, and -
 * when the user has allowed it - as a desktop notification.
 *
 * Only while a dashboard tab is open. A manager who has not opened it since is
 * told on their next visit, never twice: what has been seen is kept per user in
 * localStorage, and the first visit only takes the baseline.
 */
import { useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import type { AppNotification, User } from '@/domain/types';
import { sapSentHeadline, sapSentNews } from '@/domain/sapSent';
import { canOpenAs, scopeFor } from '@/domain/sales';
import { Api } from '@/api/client';
import { listSentCandidates, type SentCandidate } from '@/api/sapSentNews';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { pushToast, setLocalNotifications } from '@/store/slices/notificationsSlice';

const POLL_MS = 60_000;
/** Enough to never forget an order inside the week read; old ids fall off. */
const SEEN_CAP = 3000;
const FEED_CAP = 50;

const seenKey = (u: User) => `sapSentSeen:${u.id}`;
const feedKey = (u: User) => `sapSentFeed:${u.id}`;

function readJson<T>(key: string): T | null {
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : null;
  } catch {
    // Blocked or corrupt storage: the worst case is one more baseline.
    return null;
  }
}

function writeJson(key: string, v: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(v));
  } catch {
    /* nothing to do */
  }
}

/** Whether this login is told: the GM, and anyone who opens Team Orders. */
export function watchesSapSent(user: User | null | undefined): boolean {
  if (!user) return false;
  return user.role === 'general_manager' || canOpenAs(user.role, user.managedTeam, 'orders');
}

const linkFor = (user: User, id: string) =>
  user.role === 'general_manager' ? `/follow-up/${id}` : `/orders/${id}`;

function toNotification(user: User, o: SentCandidate, at: string): AppNotification {
  return {
    id: `local:sap:${o.id}`,
    kind: 'sent_to_sap',
    severity: 'info',
    title: `${o.customerName || o.id} - Sent to SAP`,
    body: [sapSentHeadline(o), o.id, o.rep].filter(Boolean).join(' · '),
    audience: [user.role],
    orderId: o.id,
    link: linkFor(user, o.id),
    createdAt: at,
  };
}

export function useSapSentWatch(user: User | null | undefined) {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const on = watchesSapSent(user);

  useEffect(() => {
    if (!user || !on) return;
    let live = true;
    dispatch(setLocalNotifications(readJson<AppNotification[]>(feedKey(user)) ?? []));

    // The GM reads every order; a manager their team, and nothing if the team
    // cannot be worked out - never everyone.
    const scope: Promise<string[] | undefined | null> =
      user.role === 'general_manager'
        ? Promise.resolve(undefined)
        : Api.attendance
            .listSalesPeople()
            .then((p) => scopeFor(p, user.salesPerson))
            .catch(() => null);

    const look = async () => {
      const reps = await scope;
      if (!live || reps === null) return;
      const orders = await listSentCandidates(reps).catch(() => null);
      if (!live || !orders) return;
      const { news, seen } = sapSentNews(readJson<string[]>(seenKey(user)), orders);
      writeJson(seenKey(user), seen.slice(-SEEN_CAP));
      if (!news.length) return;

      const at = new Date().toISOString();
      // Read back rather than kept in this closure: the bell's read marks are
      // written to storage by the effect below.
      const feed = [
        ...news.map((o) => toNotification(user, o, at)),
        ...(readJson<AppNotification[]>(feedKey(user)) ?? []),
      ].slice(0, FEED_CAP);
      writeJson(feedKey(user), feed);
      dispatch(setLocalNotifications(feed));
      dispatch(
        pushToast(
          news.length === 1
            ? `${news[0].customerName || news[0].id}: ${sapSentHeadline(news[0])}`
            : `${news.length} orders sent to SAP`,
          'success',
        ),
      );
      if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
        for (const o of news.slice(0, 5)) {
          try {
            const n = new Notification(`${o.customerName || o.id} - Sent to SAP`, {
              body: sapSentHeadline(o),
              tag: `sap-sent-${o.id}`,
            });
            n.onclick = () => {
              window.focus();
              navigate(linkFor(user, o.id));
              n.close();
            };
          } catch {
            /* some browsers only allow it from a service worker; the bell has it */
          }
        }
      }
    };

    void look();
    const t = window.setInterval(() => void look(), POLL_MS);
    const onVisible = () => {
      if (document.visibilityState === 'visible') void look();
    };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      live = false;
      window.clearInterval(t);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [user, on, dispatch, navigate]);

  // What the bell marks read is written back, so a reload keeps it read.
  const local = useAppSelector((s) => s.notifications.local);
  useEffect(() => {
    if (user && on && local.length) writeJson(feedKey(user), local);
  }, [user, on, local]);
}
