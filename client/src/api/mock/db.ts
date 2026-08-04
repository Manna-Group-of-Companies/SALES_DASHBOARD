/**
 * In-memory backend used while `VITE_USE_MOCK=true`.
 *
 * State is mirrored into `localStorage` under one key, which buys two things
 * beyond surviving a refresh: opening the app in a second tab as a different
 * rep shows the *same* stock ledger, and the `storage` event lets one tab's
 * booking appear in the other. That is enough to demo the "two reps must not
 * oversell the same minimum stock" behaviour (1.2) with no server at all.
 */

import type {
  AppNotification,
  AttendanceRecord,
  Customer,
  Employee,
  LeaveRequest,
  MinStockItem,
  Order,
  Product,
  ProductionOrder,
  StockReservation,
  WeeklyGroup,
} from '@/domain/types';
import { MOCK_LATENCY_MS } from '../config';
import {
  ATTENDANCE,
  CUSTOMERS,
  EMPLOYEES,
  LEAVE_REQUESTS,
  MIN_STOCK,
  ORDERS,
  PRODUCTION_ORDERS,
  PRODUCTS,
  USERS,
} from './fixtures';

const STORAGE_KEY = 'manna.sales.mockdb.v1';

export interface MockDb {
  users: typeof USERS;
  products: Product[];
  customers: Customer[];
  minStock: MinStockItem[];
  reservations: StockReservation[];
  orders: Order[];
  weeklyGroups: WeeklyGroup[];
  productionOrders: ProductionOrder[];
  notifications: AppNotification[];
  employees: Employee[];
  attendance: AttendanceRecord[];
  leaveRequests: LeaveRequest[];
  sequence: number;
}

function seed(): MockDb {
  return {
    users: USERS,
    products: structuredClone(PRODUCTS),
    customers: structuredClone(CUSTOMERS),
    minStock: structuredClone(MIN_STOCK),
    reservations: [],
    orders: structuredClone(ORDERS),
    weeklyGroups: [],
    productionOrders: structuredClone(PRODUCTION_ORDERS),
    notifications: [],
    employees: structuredClone(EMPLOYEES),
    attendance: structuredClone(ATTENDANCE),
    leaveRequests: structuredClone(LEAVE_REQUESTS),
    sequence: 32,
  };
}

let db: MockDb = load();

function load(): MockDb {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return seed();
    const parsed = JSON.parse(raw) as Partial<MockDb>;
    // Users and products come from code, not storage, so editing fixtures
    // during development is picked up without clearing the browser.
    return { ...seed(), ...parsed, users: USERS };
  } catch {
    return seed();
  }
}

function persist(): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(db));
  } catch {
    /* quota or private mode — stay in memory */
  }
}

/**
 * Reset the fixture backend to its seed state. No longer wired to a button —
 * call it from the browser console, or clear the `manna.sales.mockdb.v1`
 * localStorage key, when a test run has left the data in a mess.
 */
export function resetDb(): void {
  db = seed();
  persist();
  notifyChanged();
}

export function getDb(): MockDb {
  return db;
}

/** Mutate the DB and persist in one step. */
export function mutate<T>(fn: (d: MockDb) => T): T {
  const result = fn(db);
  persist();
  notifyChanged();
  return result;
}

// ------------------------------------------------------ change broadcast ---

type Listener = () => void;
const listeners = new Set<Listener>();

/** Subscribe to any DB change, in this tab or another one. */
export function onDbChange(fn: Listener): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function notifyChanged(): void {
  listeners.forEach((l) => l());
}

if (typeof window !== 'undefined') {
  window.addEventListener('storage', (e) => {
    if (e.key !== STORAGE_KEY || !e.newValue) return;
    try {
      db = { ...seed(), ...(JSON.parse(e.newValue) as Partial<MockDb>), users: USERS };
      notifyChanged();
    } catch {
      /* ignore a torn write */
    }
  });
}

// ----------------------------------------------------------------- utils ---

/** Deep copy on the way out so callers cannot mutate the store by accident. */
export function clone<T>(value: T): T {
  return structuredClone(value);
}

/** Fake network latency, so loading and disabled states are exercised in dev. */
export function delay<T>(value: T, ms: number = MOCK_LATENCY_MS): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(clone(value)), ms));
}

export function nextOrderNo(): string {
  return mutate((d) => {
    d.sequence += 1;
    return `SO-${new Date().getFullYear()}-${String(d.sequence).padStart(4, '0')}`;
  });
}

let idCounter = 0;
export function uid(prefix: string): string {
  idCounter += 1;
  return `${prefix}-${Date.now().toString(36)}-${idCounter}`;
}

export function nowIso(): string {
  return new Date().toISOString();
}
