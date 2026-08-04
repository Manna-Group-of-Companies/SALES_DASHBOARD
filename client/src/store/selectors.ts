/**
 * Derived reads. Memoised where the computation is more than a filter, so the
 * order boards do not re-sort on every keystroke elsewhere in the app.
 */

import { createSelector } from '@reduxjs/toolkit';
import type { MinStockItem, Order } from '@/domain/types';
import { agingPriorityList, availableQty } from '@/domain/aging';
import {
  activeEmployees,
  headcountByDepartment,
  pendingLeave,
  summariseAttendance,
} from '@/domain/hrRules';
import { freezeUrgency, roleCanSee, toIsoDate } from '@/domain/orderRules';
import { bucketForGrouping } from '@/api/client';
import type { RootState } from './index';

export const selectUser = (s: RootState) => s.auth.user;
export const selectProducts = (s: RootState) => s.catalog.products;
export const selectCustomers = (s: RootState) => s.catalog.customers;
export const selectOrders = (s: RootState) => s.orders.list;
export const selectMinStockItems = (s: RootState) => s.minStock.items;
export const selectReservations = (s: RootState) => s.minStock.reservations;
export const selectNotificationFeed = (s: RootState) => s.notifications.feed;

/** Item code → min-stock row, for O(1) lookups while rendering the product grid. */
export const selectMinStockByCode = createSelector(
  selectMinStockItems,
  (items): Map<string, MinStockItem> => new Map(items.map((i) => [i.itemCode, i])),
);

/** Free-to-sell quantity per item code, after everyone's holds (1.2). */
export const selectAvailableByCode = createSelector(
  selectMinStockItems,
  (items): Map<string, number> => new Map(items.map((i) => [i.itemCode, availableQty(i)])),
);

/** Aged stock a rep should push first, worst first (1.6). */
export const selectAgingList = createSelector(selectMinStockItems, (items) =>
  agingPriorityList(items),
);

export const selectLowStockItems = createSelector(selectMinStockItems, (items) =>
  items.filter((i) => i.onHand < i.threshold),
);

/** Orders the signed-in user is allowed to see at all. */
export const selectVisibleOrders = createSelector(
  selectOrders,
  selectUser,
  (orders, user): Order[] => {
    if (!user) return [];
    return orders.filter((o) => roleCanSee(o, user.role));
  },
);

export const selectPendingApproval = createSelector(selectOrders, (orders) =>
  orders.filter((o) => o.status === 'pending_approval'),
);

export const selectProductionQueue = createSelector(selectOrders, (orders) =>
  orders.filter((o) => o.status === 'approved' || o.status === 'in_production'),
);

/** Dispatched orders waiting to be compiled into a week (3.4). */
export const selectWeeklyBuckets = createSelector(selectOrders, (orders) =>
  bucketForGrouping(orders),
);

export const selectWeeklyGroups = (s: RootState) => s.orders.weeklyGroups;

/** Orders about to freeze — drives the rep's "edit now or never" banner (3.3). */
export const selectFreezingSoon = createSelector(selectVisibleOrders, (orders) =>
  orders.filter(
    (o) =>
      freezeUrgency(o) === 'imminent' &&
      o.status !== 'grouped' &&
      o.status !== 'rejected',
  ),
);

export const selectUnreadCount = createSelector(
  selectNotificationFeed,
  (feed) => feed.filter((n) => !n.readAt).length,
);

/** Critical alerts still waiting on an explicit acknowledgement (3.3). */
export const selectPendingAcks = createSelector(selectNotificationFeed, (feed) =>
  feed.filter((n) => n.requiresAck && !n.ackedAt),
);

export const selectOrderById = (id: string | null) =>
  createSelector(selectOrders, (orders) => orders.find((o) => o.id === id));

// -------------------------------------------------------------------- hr ---

export const selectEmployees = (s: RootState) => s.hr.employees;
export const selectAttendance = (s: RootState) => s.hr.attendance;
export const selectLeaveRequests = (s: RootState) => s.hr.leaveRequests;

/** On the books today. Anyone relieved, or not yet joined, is out. */
export const selectActiveEmployees = createSelector(selectEmployees, (employees) =>
  activeEmployees(employees, toIsoDate(new Date())),
);

export const selectHeadcountByDepartment = createSelector(
  selectActiveEmployees,
  (employees) => headcountByDepartment(employees),
);

export const selectTodayAttendance = createSelector(
  selectEmployees,
  selectAttendance,
  (employees, records) => summariseAttendance(employees, records, toIsoDate(new Date())),
);

/** Leave still waiting on HR — the queue and the nav badge read the same list. */
export const selectPendingLeave = createSelector(selectLeaveRequests, (requests) =>
  pendingLeave(requests),
);

export const selectEmployeeById = createSelector(
  selectEmployees,
  (employees) => new Map(employees.map((e) => [e.id, e])),
);
