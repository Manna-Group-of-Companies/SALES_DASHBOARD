/**
 * Role-aware application shell.
 *
 * The navigation is generated from the signed-in user's role, so a Stock
 * Manager simply has no route to the approval queue and a Production Manager
 * has none to the customer list. Counts on the nav items are live, which is
 * most of what "always be able to see current status without having to ask
 * around" needs.
 */

import { useEffect, useState } from 'react';
import { NavLink, Outlet, useLocation } from 'react-router-dom';
import type { Role } from '@/domain/types';
import { ROLE_LABEL } from '@/domain/types';
import { USE_MOCK, MIN_STOCK_POLL_MS } from '@/api/config';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import {
  selectActiveEmployees,
  selectFreezingSoon,
  selectLowStockItems,
  selectPendingAcks,
  selectPendingApproval,
  selectPendingLeave,
  selectProductionQueue,
  selectUnreadCount,
  selectUser,
  selectVisibleOrders,
  selectWeeklyBuckets,
} from '@/store/selectors';
import { loadNotifications, togglePanel } from '@/store/slices/notificationsSlice';
import { loadOrders } from '@/store/slices/ordersSlice';
import { refreshMinStock } from '@/store/slices/minStockSlice';
import { loadCatalog } from '@/store/slices/catalogSlice';
import { loadHr } from '@/store/slices/hrSlice';
import { signOut } from '@/store/slices/authSlice';
import { onDbChange } from '@/api/mock/db';
import { Button } from '@/components/ui';
import { initials } from '@/components/common/format';
import { NotificationPanel } from '@/features/notifications/NotificationPanel';
import { ToastHost } from '@/features/notifications/ToastHost';
import './layout.css';

interface NavItem {
  to: string;
  label: string;
  icon: string;
  roles: Role[];
  /** Live count shown on the right of the item. */
  count?: number;
  urgent?: boolean;
  group: string;
}

export function AppShell() {
  const dispatch = useAppDispatch();
  const location = useLocation();
  const user = useAppSelector(selectUser);
  const unread = useAppSelector(selectUnreadCount);
  const pendingAcks = useAppSelector(selectPendingAcks);
  const panelOpen = useAppSelector((s) => s.notifications.panelOpen);

  const myOrders = useAppSelector(selectVisibleOrders);
  const awaitingApproval = useAppSelector(selectPendingApproval);
  const productionQueue = useAppSelector(selectProductionQueue);
  const weeklyBuckets = useAppSelector(selectWeeklyBuckets);
  const lowStock = useAppSelector(selectLowStockItems);
  const freezingSoon = useAppSelector(selectFreezingSoon);
  const headcount = useAppSelector(selectActiveEmployees).length;
  const pendingLeave = useAppSelector(selectPendingLeave);

  const [navOpen, setNavOpen] = useState(false);

  // HR works on an entirely different set of records — loading the product
  // catalogue and the order book for them would be pure waste.
  const isHr = user?.role === 'hr';

  // Initial load for whoever just signed in.
  useEffect(() => {
    if (!user) return;
    if (isHr) {
      void dispatch(loadHr());
    } else {
      void dispatch(loadCatalog(user.salesPerson));
      void dispatch(loadOrders(undefined));
      void dispatch(refreshMinStock());
    }
    void dispatch(loadNotifications(user));
  }, [dispatch, user, isHr]);

  // Keep the shared stock ledger fresh so one rep's booking shows up on
  // another rep's screen (1.2). In mock mode the storage event makes this
  // near-instant across tabs; the poll is the backstop.
  useEffect(() => {
    if (!user) return;
    const id = setInterval(() => {
      if (isHr) void dispatch(loadHr());
      else void dispatch(refreshMinStock());
      void dispatch(loadNotifications(user));
    }, MIN_STOCK_POLL_MS);
    return () => clearInterval(id);
  }, [dispatch, user, isHr]);

  // Mock mode only: react immediately when another tab writes to the shared DB.
  useEffect(() => {
    if (!USE_MOCK || !user) return;
    return onDbChange(() => {
      if (isHr) {
        void dispatch(loadHr());
      } else {
        void dispatch(refreshMinStock());
        void dispatch(loadOrders(undefined));
      }
      void dispatch(loadNotifications(user));
    });
  }, [dispatch, user, isHr]);

  useEffect(() => {
    setNavOpen(false);
  }, [location.pathname]);

  if (!user) return null;

  const items: NavItem[] = [
    // No sales-side dashboard: every role opens on the screen it works in, so
    // "/" only ever redirects. HR keeps its people overview.
    { to: '/', label: 'HR Dashboard', icon: '◫', roles: ['hr'], group: 'Overview' },

    { to: '/customers', label: 'Customers', icon: '👥', roles: ['sales_manager'], group: 'Sales' },
    { to: '/orders', label: 'All Orders', icon: '📄', roles: ['sales_manager'], count: myOrders.length, group: 'Sales' },
    { to: '/approvals', label: 'Approvals', icon: '✔', roles: ['sales_manager'], count: awaitingApproval.length, urgent: awaitingApproval.length > 0, group: 'Sales' },

    { to: '/production', label: 'Production Board', icon: '⚙', roles: ['production_manager'], count: productionQueue.length, group: 'Production' },
    { to: '/dispatch', label: 'Weekly Compile', icon: '🗂', roles: ['production_manager'], count: weeklyBuckets.length, group: 'Production' },

    { to: '/stock', label: 'Minimum Stock', icon: '📦', roles: ['sales_manager', 'production_manager', 'stock_manager'], count: lowStock.length, urgent: lowStock.length > 0, group: 'Stock' },
    { to: '/stock/aging', label: 'Aging Stock', icon: '🕰', roles: ['sales_manager', 'production_manager'], group: 'Stock' },
    { to: '/stock/replenish', label: 'Replenishment', icon: '↻', roles: ['stock_manager', 'production_manager'], group: 'Stock' },

    { to: '/hr/employees', label: 'Employees', icon: '🧑', roles: ['hr'], count: headcount, group: 'People' },
    { to: '/hr/leave', label: 'Leave Requests', icon: '🗓', roles: ['hr'], count: pendingLeave.length, urgent: pendingLeave.length > 0, group: 'People' },

    { to: '/import', label: 'Data Import', icon: '⬆', roles: ['sales_manager', 'stock_manager'], group: 'Admin' },
  ];

  const visible = items.filter((i) => i.roles.includes(user.role));
  const groups = [...new Set(visible.map((i) => i.group))];

  // Matched against the visible items, not all of them: "/" is the Dashboard
  // for most roles and the HR Dashboard for HR.
  const title = visible.find((i) => i.to === location.pathname)?.label ?? 'Sales';

  return (
    <div className="shell">
      <nav className={`sidebar ${navOpen ? 'is-open' : ''}`}>
        <div className="sidebar__brand">
          <div className="sidebar__logo">MT</div>
          <div>
            <div className="sidebar__name">Manna Treads</div>
            <div className="sidebar__sub">Sales</div>
          </div>
        </div>

        <div className="sidebar__nav">
          {groups.map((group) => (
            <div key={group}>
              <div className="sidebar__group">{group}</div>
              {visible
                .filter((i) => i.group === group)
                .map((item) => (
                  <NavLink
                    key={`${item.to}-${item.label}`}
                    to={item.to}
                    end={item.to === '/'}
                    className={({ isActive }) => `navlink ${isActive ? 'is-active' : ''}`}
                  >
                    <span className="navlink__icon" aria-hidden>
                      {item.icon}
                    </span>
                    <span className="grow">{item.label}</span>
                    {item.count != null && item.count > 0 && (
                      <span className={`navlink__badge ${item.urgent ? '' : 'navlink__badge--muted'}`}>
                        {item.count}
                      </span>
                    )}
                  </NavLink>
                ))}
            </div>
          ))}
        </div>

        <div className="sidebar__footer">
          <div className="user-chip" aria-live="polite">
            <div className="avatar">{initials(user.name)}</div>
            <div className="grow" style={{ minWidth: 0 }}>
              <div className="user-chip__name">{user.name}</div>
              <div className="user-chip__role">{ROLE_LABEL[user.role]}</div>
            </div>
          </div>
          <Button size="sm" variant="ghost" block onClick={() => dispatch(signOut())}>
            Sign out
          </Button>
        </div>
      </nav>

      <div className="main">
        <header className="header">
          {/* Shown only under 860px, where the sidebar collapses off-canvas. */}
          <Button
            variant="ghost"
            size="sm"
            iconOnly
            className="nav-toggle"
            onClick={() => setNavOpen((v) => !v)}
            aria-label="Toggle navigation"
          >
            ☰
          </Button>
          <div className="grow">
            <div className="header__title">{title}</div>
            {freezingSoon.length > 0 && user.role !== 'production_manager' && (
              <div className="header__sub">
                ⏳ {freezingSoon.length} order{freezingSoon.length === 1 ? '' : 's'} freeze within 24
                hours
              </div>
            )}
          </div>

          <button
            className={`bell ${pendingAcks.length ? 'bell--urgent' : ''}`}
            onClick={() => dispatch(togglePanel())}
            aria-label={`Notifications${unread ? `, ${unread} unread` : ''}`}
          >
            🔔
            {unread > 0 && <span className="bell__count">{unread > 99 ? '99+' : unread}</span>}
          </button>
        </header>

        {/*
          Unacknowledged post-approval changes are not merely listed — they take
          over the top of the Production Manager's screen until acknowledged (3.3).
        */}
        {user.role === 'production_manager' && pendingAcks.length > 0 && (
          <div className="ack-banner">
            <span aria-hidden style={{ fontSize: 16 }}>
              ⚠️
            </span>
            <span className="ack-banner__text grow">
              {pendingAcks.length} order change{pendingAcks.length === 1 ? '' : 's'} after approval
              need{pendingAcks.length === 1 ? 's' : ''} your acknowledgement.
            </span>
            <Button size="sm" variant="danger" onClick={() => dispatch(togglePanel(true))}>
              Review now
            </Button>
          </div>
        )}

        <main className="content">
          <Outlet />
        </main>
      </div>

      {panelOpen && <NotificationPanel />}
      <ToastHost />
    </div>
  );
}
