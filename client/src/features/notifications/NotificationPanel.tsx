/**
 * The notification centre.
 *
 * Two tiers, deliberately: ordinary items are read-and-forget, but anything
 * carrying `requiresAck` (a post-approval order change, 3.3) is pinned to the
 * top with an explicit Acknowledge button and cannot be cleared by scrolling
 * past it. That is the mechanism behind "no order change is ever missed on the
 * production floor".
 */

import { useNavigate } from 'react-router-dom';
import type { AppNotification } from '@/domain/types';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import {
  acknowledgeNotification,
  markAllNotificationsRead,
  markNotificationRead,
  togglePanel,
} from '@/store/slices/notificationsSlice';
import { selectNotificationFeed, selectUser } from '@/store/selectors';
import { Button, Empty, Icon } from '@/components/ui';
import { relativeTime } from '@/components/common/format';

export function NotificationPanel() {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const user = useAppSelector(selectUser);
  const feed = useAppSelector(selectNotificationFeed);

  if (!user) return null;

  // Unacknowledged criticals float to the top regardless of age.
  const pending = feed.filter((n) => n.requiresAck && !n.ackedAt);
  const rest = feed.filter((n) => !(n.requiresAck && !n.ackedAt));
  const ordered = [...pending, ...rest];

  const close = () => dispatch(togglePanel(false));

  const open = (n: AppNotification) => {
    if (!n.readAt) dispatch(markNotificationRead({ id: n.id, user }));
    if (n.orderId) {
      navigate(`/orders/${n.orderId}`);
      close();
    }
  };

  return (
    <aside className="notif-panel" role="dialog" aria-label="Notifications">
      <header className="notif-panel__head">
        <strong className="grow">Notifications</strong>
        {feed.some((n) => !n.readAt) && (
          <Button size="sm" variant="ghost" onClick={() => dispatch(markAllNotificationsRead(user))}>
            Mark all read
          </Button>
        )}
        <Button size="sm" variant="ghost" iconOnly onClick={close} aria-label="Close">
          <Icon name="x" />
        </Button>
      </header>

      <div className="notif-panel__list">
        {ordered.length === 0 && <Empty title="No notifications" />}

        {ordered.map((n) => {
          const needsAck = Boolean(n.requiresAck && !n.ackedAt);
          return (
            <div
              key={n.id}
              className={`notif ${!n.readAt ? 'is-unread' : ''} ${needsAck ? 'needs-ack' : ''}`}
              onClick={() => open(n)}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') open(n);
              }}
            >
              <span className={`notif__icon notif__icon--${n.severity}`} aria-hidden />
              <div className="grow">
                <div className="notif__title">{n.title}</div>
                <div className="notif__body">{n.body}</div>
                <div className="notif__meta">{relativeTime(n.createdAt)}</div>

                {needsAck && (
                  <Button
                    size="sm"
                    variant="danger"
                    style={{ marginTop: 8 }}
                    onClick={(e) => {
                      e.stopPropagation();
                      dispatch(acknowledgeNotification({ id: n.id, user }));
                    }}
                  >
                    Acknowledge
                  </Button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </aside>
  );
}
