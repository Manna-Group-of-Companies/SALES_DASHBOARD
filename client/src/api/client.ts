/**
 * The single API client for the Sales module.
 *
 * Everything that talks to ERPNext lives here, in one file, the same way
 * `services/api.dart` does in the field-sales app — one `Api` object, one place
 * to look when an endpoint or a field name changes.
 *
 * Layout:
 *   1. Auth plumbing      — credentials, axios instance, CSRF, error unwrapping
 *   2. Frappe REST        — typed wrappers over /api/resource
 *   3. Api.auth           — sign in / out
 *   4. Api.catalog        — products, customers, credit check
 *   5. Api.notify         — the notification feed
 *   6. Api.stock          — minimum stock, reservations, replenishment
 *   7. Api.orders         — the order lifecycle
 *   8. Api.importer       — Excel import
 *   9. Api.hr             — employees, attendance, leave
 *
 * Every method works against either the real site or the in-memory fixture
 * backend, switched by `USE_MOCK`. The mock branch is not a stub: it is a
 * working implementation of the same behaviour, so the UI can be driven
 * end-to-end before the ERPNext doctypes exist.
 */

import axios, { AxiosError, type AxiosInstance, type AxiosRequestConfig } from 'axios';

import type {
  AppNotification,
  AttendanceRecord,
  AttendanceStatus,
  Customer,
  Department,
  Employee,
  EmploymentType,
  FulfilmentSource,
  LeaveRequest,
  LeaveStatus,
  LeaveType,
  MinStockItem,
  NotificationKind,
  NotificationSeverity,
  Order,
  OrderItem,
  OrderStatus,
  Product,
  ProductCategory,
  ProductionOrder,
  Role,
  StockReservation,
  TimelineEntry,
  User,
  WeeklyGroup,
} from '@/domain/types';
import { DEPARTMENTS, LEAVE_TYPE_LABEL } from '@/domain/types';
import { isWeeklyOff, shiftDays, workingDaysBetween } from '@/domain/hrRules';
import {
  canApprove,
  canEditItems,
  effectiveDeliveryDate,
  formatDate,
  isPostApprovalEdit,
  isRateLocked,
  weekEndOf,
  weekStartOf,
} from '@/domain/orderRules';
import { orderTotal } from '@/domain/productRules';
import { allItemsReady, firstStage, isTerminalStage, stageLabel } from '@/domain/processStages';
import { availableQty, isBelowThreshold } from '@/domain/aging';

import { USE_MOCK } from './config';
import {
  ATTENDANCE_FIELD,
  CUSTOMER_FIELD,
  DOCTYPE,
  EMPLOYEE_FIELD,
  ITEM_FIELD,
  LEAVE_FIELD,
  METHOD,
} from './endpoints';
import { clone, delay, getDb, mutate, nextOrderNo, nowIso, uid } from './mock/db';
import { MOCK_CREDENTIALS } from './mock/fixtures';

// ===========================================================================
// 1. AUTH PLUMBING
// ===========================================================================

export interface Credentials {
  apiKey?: string;
  apiSecret?: string;
  csrfToken?: string;
}

const CREDENTIALS_KEY = 'manna.sales.auth';
const SESSION_KEY = 'manna.sales.session';

let credentials: Credentials = loadCredentials();

function loadCredentials(): Credentials {
  try {
    const raw = localStorage.getItem(CREDENTIALS_KEY);
    return raw ? (JSON.parse(raw) as Credentials) : {};
  } catch {
    return {};
  }
}

export function setCredentials(next: Credentials): void {
  credentials = { ...credentials, ...next };
  try {
    localStorage.setItem(CREDENTIALS_KEY, JSON.stringify(credentials));
  } catch {
    /* private mode — in-memory only */
  }
}

export function clearCredentials(): void {
  credentials = {};
  try {
    localStorage.removeItem(CREDENTIALS_KEY);
  } catch {
    /* ignore */
  }
}

export const http: AxiosInstance = axios.create({
  baseURL: '/',
  // Frappe's `sid` cookie is how non-token logins stay authenticated.
  withCredentials: true,
  headers: { Accept: 'application/json' },
});

http.interceptors.request.use((config) => {
  const { apiKey, apiSecret, csrfToken } = credentials;
  if (apiKey && apiSecret) {
    config.headers.set('Authorization', `token ${apiKey}:${apiSecret}`);
  }
  if (csrfToken && (config.method ?? 'get').toLowerCase() !== 'get') {
    config.headers.set('X-Frappe-CSRF-Token', csrfToken);
  }
  return config;
});

/** A network/server failure with a message worth putting in front of a user. */
export class ApiError extends Error {
  readonly status: number;
  readonly detail?: unknown;

  constructor(message: string, status: number, detail?: unknown) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.detail = detail;
  }
}

http.interceptors.response.use(
  (r) => r,
  (error: AxiosError) => Promise.reject(toApiError(error)),
);

/**
 * Frappe reports failures in several shapes — `exception`, `_server_messages`
 * (a JSON string of JSON strings), or a plain `message`. Dig out the first
 * readable sentence rather than showing the user a stack trace.
 */
export function toApiError(error: unknown): ApiError {
  if (error instanceof ApiError) return error;

  if (axios.isAxiosError(error)) {
    const status = error.response?.status ?? 0;
    const data = error.response?.data as Record<string, unknown> | undefined;

    if (!error.response) {
      return new ApiError('Cannot reach the server. Check your connection.', 0, error.message);
    }

    const serverMessages = data?._server_messages;
    if (typeof serverMessages === 'string') {
      try {
        const parsed = JSON.parse(serverMessages) as string[];
        const first = parsed[0];
        const inner = typeof first === 'string' ? JSON.parse(first) : first;
        const msg = (inner as { message?: string })?.message;
        if (msg) return new ApiError(stripHtml(msg), status, data);
      } catch {
        /* fall through to the other shapes */
      }
    }

    const exc = data?.exception;
    if (typeof exc === 'string' && exc.trim()) {
      // "frappe.exceptions.ValidationError: Rate is locked" -> the tail.
      const tail = exc.split(':').slice(1).join(':').trim();
      return new ApiError(stripHtml(tail || exc), status, data);
    }

    const message = data?.message;
    if (typeof message === 'string' && message.trim()) {
      return new ApiError(stripHtml(message), status, data);
    }

    if (status === 401 || status === 403) {
      return new ApiError('Your session has expired. Please sign in again.', status, data);
    }
    return new ApiError(`Request failed (${status}).`, status, data);
  }

  if (error instanceof Error) return new ApiError(error.message, 0);
  return new ApiError('Something went wrong.', 0, error);
}

function stripHtml(s: string): string {
  return s.replace(/<[^>]*>/g, '').trim();
}

/** Scrape the CSRF token Frappe embeds in its desk boot payload. */
export async function fetchCsrfToken(): Promise<void> {
  try {
    const { data } = await http.get<string>('/', { responseType: 'text' });
    const match = /csrf_token"\s*:\s*"([^"]+)"/.exec(String(data));
    if (match?.[1]) setCredentials({ csrfToken: match[1] });
  } catch {
    /* token auth does not need CSRF; ignore */
  }
}

export async function request<T>(config: AxiosRequestConfig): Promise<T> {
  const { data } = await http.request<T>(config);
  return data;
}

// ===========================================================================
// 2. FRAPPE REST
// ===========================================================================
//
// Frappe wants `fields` and `filters` as JSON-encoded *strings* in the query,
// not as normal params — encoding them by hand at every call site is where bugs
// come from, so it happens once, here.

export type FilterOperator =
  | '=' | '!=' | '>' | '<' | '>=' | '<='
  | 'like' | 'not like' | 'in' | 'not in' | 'between' | 'is' | 'Timespan';

/** `['status', '=', 'approved']` */
export type Filter = [field: string, op: FilterOperator, value: unknown];

export interface ListOptions {
  fields?: string[];
  filters?: Filter[];
  orderBy?: string;
  /** 0 fetches every row. Frappe's own default is 20. */
  limit?: number;
  start?: number;
}

function resourceUrl(doctype: string, name?: string): string {
  const base = `/api/resource/${encodeURIComponent(doctype)}`;
  return name ? `${base}/${encodeURIComponent(name)}` : base;
}

export async function listDocs<T>(doctype: string, options: ListOptions = {}): Promise<T[]> {
  const params: Record<string, string | number> = {};
  if (options.fields?.length) params.fields = JSON.stringify(options.fields);
  if (options.filters?.length) params.filters = JSON.stringify(options.filters);
  if (options.orderBy) params.order_by = options.orderBy;
  if (options.limit != null) params.limit_page_length = options.limit;
  if (options.start != null) params.limit_start = options.start;

  const { data } = await http.get<{ data: T[] }>(resourceUrl(doctype), { params });
  return data.data ?? [];
}

export async function getDoc<T>(doctype: string, name: string): Promise<T> {
  const { data } = await http.get<{ data: T }>(resourceUrl(doctype, name));
  return data.data;
}

export async function createDoc<T>(doctype: string, body: Record<string, unknown>): Promise<T> {
  const { data } = await http.post<{ data: T }>(resourceUrl(doctype), body);
  return data.data;
}

export async function updateDoc<T>(
  doctype: string,
  name: string,
  body: Record<string, unknown>,
): Promise<T> {
  const { data } = await http.put<{ data: T }>(resourceUrl(doctype, name), body);
  return data.data;
}

export async function deleteDoc(doctype: string, name: string): Promise<void> {
  await http.delete(resourceUrl(doctype, name));
}

export async function countDocs(doctype: string, filters: Filter[] = []): Promise<number> {
  const { data } = await http.get<{ message: number }>('/api/method/frappe.client.get_count', {
    params: { doctype, filters: JSON.stringify(filters) },
  });
  return data.message ?? 0;
}

/** Call a whitelisted server method. */
export async function callMethod<T>(
  method: string,
  args: Record<string, unknown> = {},
): Promise<T> {
  const { data } = await http.post<{ message: T }>(method, args);
  return data.message;
}

// ===========================================================================
// 3. AUTH
// ===========================================================================

async function login(email: string, password: string): Promise<User> {
  if (USE_MOCK) {
    const key = email.trim().toLowerCase();
    const user = getDb().users.find((u) => u.email.toLowerCase() === key);

    // Checked against the fixture credential map so signing in behaves the same
    // way it will against ERPNext — same failure, same message, no shortcut.
    // The message stays deliberately vague about *which* half was wrong.
    if (!user || MOCK_CREDENTIALS[key] !== password) {
      throw new Error('Incorrect email or password.');
    }
    saveSession(user);
    return delay(user, 150);
  }

  await http.post(METHOD.login, new URLSearchParams({ usr: email, pwd: password }), {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  });
  await fetchCsrfToken();
  const user = await fetchCurrentUser();
  saveSession(user);
  return user;
}

async function logout(): Promise<void> {
  if (!USE_MOCK) await http.post(METHOD.logout).catch(() => undefined);
  clearCredentials();
  try {
    localStorage.removeItem(SESSION_KEY);
  } catch {
    /* ignore */
  }
}

/** Restore the signed-in user on a page refresh. */
function restoreSession(): User | null {
  try {
    const raw = localStorage.getItem(SESSION_KEY);
    return raw ? (JSON.parse(raw) as User) : null;
  } catch {
    return null;
  }
}

function saveSession(user: User): void {
  try {
    localStorage.setItem(SESSION_KEY, JSON.stringify(user));
  } catch {
    /* ignore */
  }
}

/**
 * Resolve the logged-in Frappe user into an app user.
 *
 * This deliberately mirrors `resolveMySalesPerson` + `resolveManagerContext` in
 * the field-sales app, because both apps run against the same site and must
 * agree on who someone is. Roles are NOT ERPNext role-list entries — they are
 * custom flags on `User` plus a `Sales Person` record linked by `custom_user`:
 *
 *   custom_is_production_manager = 1  → production_manager
 *   custom_is_stock_manager      = 1  → stock_manager   (new; see doctype doc)
 *   custom_is_hr                 = 1  → hr              (new; see doctype doc)
 *   custom_managed_team          set  → sales_manager
 *
 * A plain Sales Person with none of these flags is a field rep. They belong to
 * the field-sales app and get no role here — so rather than falling back to
 * some default, this refuses the sign-in outright. Silently admitting them
 * would be the one mistake with real consequences: a rep on the production
 * board, or in the approval queue.
 */
async function fetchCurrentUser(): Promise<User> {
  const { data } = await http.get<{ message: string }>(METHOD.loggedUser);
  const email = data.message;

  const { data: doc } = await http.get<{
    data: {
      name: string;
      full_name?: string;
      custom_managed_team?: string;
      custom_is_production_manager?: number;
      custom_is_stock_manager?: number;
      custom_is_hr?: number;
      custom_production_company?: string;
    };
  }>(`/api/resource/User/${encodeURIComponent(email)}`);

  const u = doc.data;

  // The rep identity, if this login has one. `is_group=0` excludes the
  // roll-up nodes in the Sales Person tree.
  const salesPersons = await listDocs<{ name: string; custom_company?: string }>(
    DOCTYPE.salesPerson,
    {
      fields: ['name', 'sales_person_name', 'custom_company'],
      filters: [
        ['is_group', '=', 0],
        ['custom_user', '=', email],
      ],
      limit: 1,
    },
  ).catch(() => []);

  const salesPerson = salesPersons[0]?.name;
  const managedTeam = (u.custom_managed_team ?? '').trim();

  let role: Role | null = null;
  if (u.custom_is_hr === 1) role = 'hr';
  else if (u.custom_is_stock_manager === 1) role = 'stock_manager';
  else if (u.custom_is_production_manager === 1) role = 'production_manager';
  else if (managedTeam) role = 'sales_manager';

  if (!role) {
    throw new Error(
      salesPerson
        ? 'Sales Reps work in the field-sales app. This login has no access to the Sales & Production module.'
        : 'This login has no role in the Sales & Production module. Contact the Sales Manager.',
    );
  }

  return {
    id: u.name,
    name: u.full_name || email,
    email,
    role,
    salesPerson,
    productionUnit: u.custom_production_company || salesPersons[0]?.custom_company,
  };
}

// ===========================================================================
// 4. CATALOG
// ===========================================================================

async function listProducts(): Promise<Product[]> {
  if (USE_MOCK) return delay(getDb().products.filter((p) => p.active));

  try {
    // Preferred path: the site has the tread-rubber custom fields, so category
    // and the weight figures come straight off the Item.
    const rows = await listDocs<Record<string, unknown>>(DOCTYPE.item, {
      fields: [
        'name', 'item_name', 'stock_uom', 'standard_rate', 'gst_hsn_code', 'disabled',
        ITEM_FIELD.category,
        ITEM_FIELD.avgWeightPerRoll,
        ITEM_FIELD.beltsPerRoll,
        ITEM_FIELD.exactWeightPerRoll,
        ITEM_FIELD.tinSize,
        ITEM_FIELD.size,
      ],
      filters: [
        ['disabled', '=', 0],
        [ITEM_FIELD.category, 'in', ['PCTR', 'CTR', 'BG', 'VS']],
      ],
      limit: 0,
    });
    return rows.map(toProduct);
  } catch (e) {
    // The custom fields have not been created yet, so Frappe rejects the whole
    // query. Fall back to the same Item query the field-sales app uses and
    // infer the category from the item's own naming, so reps see the real
    // catalogue instead of an empty screen. Weight figures will be missing
    // until the fields exist — those rows cannot be priced and say so.
    const status = toApiError(e).status;
    if (status !== 417 && status !== 500) throw e;

    const rows = await listDocs<Record<string, unknown>>(DOCTYPE.item, {
      fields: ['name', 'item_name', 'stock_uom', 'standard_rate', 'item_group', 'disabled'],
      filters: [
        ['disabled', '=', 0],
        ['is_sales_item', '=', 1],
      ],
      limit: 0,
    });

    return rows
      .map((row) => {
        const category = inferCategory(
          `${row.name ?? ''} ${row.item_name ?? ''} ${row.item_group ?? ''}`,
        );
        return category ? toProduct({ ...row, [ITEM_FIELD.category]: category }) : null;
      })
      .filter((p): p is Product => p !== null);
  }
}

/**
 * Best-effort category from an item's code, name or group, for sites that have
 * not had `custom_product_category` created yet. Order matters: "precured"
 * must be tested before the bare "tread" that both tread types share.
 */
function inferCategory(text: string): ProductCategory | null {
  const t = text.toLowerCase();
  if (/\bvulcan/.test(t) || /\bvs[-\s]/.test(t) || /solution/.test(t)) return 'VS';
  if (/bonding|\bgum\b|\bbg[-\s]/.test(t)) return 'BG';
  if (/precured|\bpctr\b|\bptr\b/.test(t)) return 'PCTR';
  if (/conventional|\bctr\b/.test(t)) return 'CTR';
  return null;
}

function toProduct(row: Record<string, unknown>): Product {
  const n = (k: string): number | undefined => {
    const v = row[k];
    return typeof v === 'number' && Number.isFinite(v) ? v : undefined;
  };
  const tin = n(ITEM_FIELD.tinSize);
  return {
    code: String(row.name),
    name: String(row.item_name ?? row.name),
    category: String(row[ITEM_FIELD.category] ?? 'PCTR') as ProductCategory,
    size: row[ITEM_FIELD.size] ? String(row[ITEM_FIELD.size]) : undefined,
    avgWeightPerRoll: n(ITEM_FIELD.avgWeightPerRoll),
    beltsPerRoll: n(ITEM_FIELD.beltsPerRoll),
    exactWeightPerRoll: n(ITEM_FIELD.exactWeightPerRoll),
    tinSize: tin === 10 || tin === 30 ? tin : undefined,
    defaultRate: n('standard_rate'),
    hsnCode: row.gst_hsn_code ? String(row.gst_hsn_code) : undefined,
    active: !row.disabled,
  };
}

/** Customers for a rep; managers pass no `salesPerson` and get everyone. */
async function listCustomers(salesPerson?: string): Promise<Customer[]> {
  if (USE_MOCK) {
    const all = getDb().customers;
    return delay(salesPerson ? all.filter((c) => c.assignedReps.includes(salesPerson)) : all);
  }

  // Field list mirrors the field-sales app's `getCustomers`, plus the proforma
  // details. `custom_destination` is the only one that may not exist yet, so it
  // is requested optimistically and falls back to `territory` in the mapper.
  const fields = [
    'name',
    'customer_name',
    'territory',
    'customer_group',
    'primary_address',
    'email_id',
    CUSTOMER_FIELD.gstin,
    CUSTOMER_FIELD.destination,
    CUSTOMER_FIELD.outstanding,
    CUSTOMER_FIELD.creditLimit,
    CUSTOMER_FIELD.assignedReps,
    CUSTOMER_FIELD.phone,
  ];

  // `custom_assigned_reps` is pipe-delimited, matching the field-sales app.
  const filters: Filter[] = salesPerson
    ? [[CUSTOMER_FIELD.assignedReps, 'like', `%|${salesPerson}|%`]]
    : [];

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.customer, {
    fields,
    filters,
    orderBy: 'customer_name asc',
    limit: 0,
  }).catch(async (e: unknown) => {
    // A missing custom field makes Frappe reject the whole query. Retry with
    // only the fields the live site is known to have, so an incomplete ERPNext
    // setup degrades to fewer columns instead of an empty screen.
    if (toApiError(e).status !== 417 && toApiError(e).status !== 500) throw e;
    return listDocs<Record<string, unknown>>(DOCTYPE.customer, {
      fields: ['name', 'customer_name', 'territory', CUSTOMER_FIELD.outstanding, CUSTOMER_FIELD.creditLimit, CUSTOMER_FIELD.assignedReps],
      filters,
      orderBy: 'customer_name asc',
      limit: 0,
    });
  });

  return rows.map(toCustomer);
}

function toCustomer(row: Record<string, unknown>): Customer {
  const reps = String(row[CUSTOMER_FIELD.assignedReps] ?? '')
    .split('|')
    .map((s) => s.trim())
    .filter(Boolean);
  const territory = String(row.territory ?? '').trim();
  return {
    id: String(row.name),
    name: String(row.customer_name ?? row.name),
    // Production sees this instead of the customer, so it must never be blank.
    destination:
      String(row[CUSTOMER_FIELD.destination] ?? '').trim() || territory || '—',
    address: String(row.primary_address ?? ''),
    gstin: String(row[CUSTOMER_FIELD.gstin] ?? ''),
    state: territory,
    phone: row[CUSTOMER_FIELD.phone] ? String(row[CUSTOMER_FIELD.phone]) : undefined,
    email: row.email_id ? String(row.email_id) : undefined,
    outstandingBalance: Number(row[CUSTOMER_FIELD.outstanding] ?? 0),
    creditLimit: Number(row[CUSTOMER_FIELD.creditLimit] ?? 0),
    assignedReps: reps,
  };
}

async function getCustomer(id: string): Promise<Customer | undefined> {
  const all = await listCustomers();
  return all.find((c) => c.id === id);
}

/** Credit headroom, used before the manager approves an order (2.1). */
export interface CreditCheck {
  outstanding: number;
  limit: number;
  headroom: number;
  orderValue: number;
  /** True when this order would push the customer past their limit. */
  breaches: boolean;
  utilisation: number;
}

export function checkCredit(customer: Customer, orderValue: number): CreditCheck {
  const headroom = customer.creditLimit - customer.outstandingBalance;
  return {
    outstanding: customer.outstandingBalance,
    limit: customer.creditLimit,
    headroom,
    orderValue,
    breaches: orderValue > headroom,
    utilisation:
      customer.creditLimit > 0 ? customer.outstandingBalance / customer.creditLimit : 0,
  };
}

// ===========================================================================
// 5. NOTIFICATIONS
// ===========================================================================
//
// One append-only stream, filtered per role on read. Critical alerts carry
// `requiresAck`: a post-approval item change (3.3) is not merely shown to the
// Production Manager, it sits at the top of their screen until they explicitly
// acknowledge it. That is the only way "no order change is ever missed on the
// floor" holds when the floor is busy.

export interface NewNotification {
  kind: NotificationKind;
  severity?: NotificationSeverity;
  title: string;
  body: string;
  audience: Role[];
  audienceUserId?: string;
  orderId?: string;
  itemCode?: string;
  requiresAck?: boolean;
}

const DEFAULT_SEVERITY: Record<NotificationKind, NotificationSeverity> = {
  order_submitted: 'info',
  order_approved: 'info',
  order_rejected: 'warning',
  order_edited_post_approval: 'critical',
  delivery_date_changed: 'warning',
  stage_advanced: 'info',
  order_dispatched: 'info',
  orders_grouped: 'info',
  min_stock_low: 'warning',
  min_stock_replenished: 'info',
  edit_freeze_imminent: 'warning',
  leave_applied: 'info',
  leave_decided: 'info',
  attendance_unmarked: 'warning',
};

/**
 * Raise a notification. Called from inside the other Api methods rather than
 * from components, so an event can never be published without the state change
 * that caused it.
 */
function emit(input: NewNotification): AppNotification {
  const notification: AppNotification = {
    id: uid('NTF'),
    kind: input.kind,
    severity: input.severity ?? DEFAULT_SEVERITY[input.kind],
    title: input.title,
    body: input.body,
    audience: input.audience,
    audienceUserId: input.audienceUserId,
    orderId: input.orderId,
    itemCode: input.itemCode,
    createdAt: nowIso(),
    requiresAck: input.requiresAck,
  };

  if (USE_MOCK) {
    mutate((d) => d.notifications.unshift(notification));
    return notification;
  }

  // Fire-and-forget on the live backend: a failed notification must never take
  // down the write that produced it.
  void createDoc(DOCTYPE.notification, notification as unknown as Record<string, unknown>).catch(
    () => undefined,
  );
  return notification;
}

/** Everything addressed to this user, newest first. */
async function listNotifications(user: User): Promise<AppNotification[]> {
  if (USE_MOCK) {
    const rows = getDb()
      .notifications.filter(
        (n) =>
          n.audience.includes(user.role) &&
          (!n.audienceUserId || n.audienceUserId === user.id),
      )
      .slice(0, 200);
    return delay(rows, 80);
  }

  const rows = await listDocs<AppNotification>(DOCTYPE.notification, {
    filters: [['audience', 'like', `%${user.role}%`]],
    orderBy: 'creation desc',
    limit: 200,
  });
  return rows.filter((n) => !n.audienceUserId || n.audienceUserId === user.id);
}

async function markNotificationRead(id: string): Promise<void> {
  if (USE_MOCK) {
    mutate((d) => {
      const n = d.notifications.find((x) => x.id === id);
      if (n && !n.readAt) n.readAt = nowIso();
    });
    return;
  }
  await updateDoc(DOCTYPE.notification, id, { readAt: nowIso() });
}

async function markAllNotificationsRead(user: User): Promise<void> {
  if (USE_MOCK) {
    mutate((d) => {
      const at = nowIso();
      d.notifications.forEach((n) => {
        const mine =
          n.audience.includes(user.role) &&
          (!n.audienceUserId || n.audienceUserId === user.id);
        if (mine && !n.readAt) n.readAt = at;
      });
    });
    return;
  }
  const rows = await listNotifications(user);
  await Promise.all(
    rows
      .filter((n) => !n.readAt)
      .map((n) => updateDoc(DOCTYPE.notification, n.id, { readAt: nowIso() })),
  );
}

/**
 * Acknowledge a must-ack alert. Distinct from "read": reading is passive,
 * acknowledging is the Production Manager saying "I have seen this change and
 * the floor knows about it".
 */
async function acknowledgeNotification(id: string): Promise<AppNotification | undefined> {
  if (USE_MOCK) {
    return mutate((d) => {
      const n = d.notifications.find((x) => x.id === id);
      if (n) {
        n.ackedAt = nowIso();
        n.readAt = n.readAt ?? n.ackedAt;
      }
      return clone(n);
    });
  }
  const at = nowIso();
  return updateDoc<AppNotification>(DOCTYPE.notification, id, { ackedAt: at, readAt: at });
}

export function unreadCount(rows: AppNotification[]): number {
  return rows.filter((n) => !n.readAt).length;
}

export function pendingAcks(rows: AppNotification[]): AppNotification[] {
  return rows.filter((n) => n.requiresAck && !n.ackedAt);
}

// ===========================================================================
// 6. MINIMUM STOCK
// ===========================================================================
//
// Overselling is prevented with a *soft reservation*: the moment a rep keys a
// quantity the hold is written to the shared ledger, and every other rep's
// screen picks it up on the next poll. Holds belonging to a draft nobody
// submitted expire on their own, so an abandoned tab cannot strand stock.
//
// This leaves a poll-interval-wide race, which is the trade-off chosen over
// server-side locking. `reserveStock` is written so that swapping its body for
// a call to `METHOD.reserveStock` closes that window without touching a caller.

/** A hold on an unsubmitted draft dies after this long. */
export const SOFT_HOLD_TTL_MS = 30 * 60 * 1000; // 30 minutes

export class InsufficientStockError extends Error {
  constructor(
    readonly itemCode: string,
    readonly requested: number,
    readonly available: number,
  ) {
    super(
      `Only ${available} available for ${itemCode} — another rep has booked the rest. You asked for ${requested}.`,
    );
    this.name = 'InsufficientStockError';
  }
}

async function listMinStock(): Promise<MinStockItem[]> {
  if (USE_MOCK) {
    sweepExpiredHolds();
    return delay(withReserved(getDb().minStock), 60);
  }
  // These doctypes are new for this module. Until they are created on the site
  // the ledger is simply empty — which the UI already renders correctly as
  // "No minimum stock" on every row — rather than breaking the order screen.
  const [items, reservations] = await Promise.all([
    listDocs<MinStockItem>(DOCTYPE.minStock, { limit: 0 }).catch(ifMissing([])),
    listDocs<StockReservation>(DOCTYPE.stockReservation, { limit: 0 }).catch(ifMissing([])),
  ]);
  return items.map((i) => ({
    ...i,
    reserved: reservations
      .filter((r) => r.itemCode === i.itemCode)
      .reduce((s, r) => s + r.qty, 0),
  }));
}

/**
 * Swallow "this doctype does not exist yet" and return a default. Any other
 * failure — a real outage, a permission problem — still propagates, because
 * silently showing an empty list for those would hide a genuine fault.
 */
function ifMissing<T>(fallback: T) {
  return (e: unknown): T => {
    const status = toApiError(e).status;
    if (status === 404 || status === 417) return fallback;
    throw e;
  };
}

/** Recompute `reserved` from the live reservation rows. */
function withReserved(items: MinStockItem[]): MinStockItem[] {
  const { reservations } = getDb();
  return items.map((i) => ({
    ...i,
    reserved: reservations
      .filter((r) => r.itemCode === i.itemCode)
      .reduce((s, r) => s + r.qty, 0),
  }));
}

async function listReservations(): Promise<StockReservation[]> {
  if (USE_MOCK) {
    sweepExpiredHolds();
    return delay(getDb().reservations, 40);
  }
  return listDocs<StockReservation>(DOCTYPE.stockReservation, { limit: 0 }).catch(ifMissing([]));
}

function sweepExpiredHolds(): void {
  const cutoff = Date.now() - SOFT_HOLD_TTL_MS;
  const db = getDb();
  const stale = db.reservations.some(
    (r) => r.orderId == null && new Date(r.heldAt).getTime() < cutoff,
  );
  if (!stale) return;
  mutate((d) => {
    d.reservations = d.reservations.filter(
      (r) => r.orderId != null || new Date(r.heldAt).getTime() >= cutoff,
    );
  });
}

export interface ReserveInput {
  itemCode: string;
  qty: number;
  user: User;
  /** Null while the order is still an unsaved draft. */
  orderId?: string | null;
  /** Replace this rep's existing hold on the item rather than stacking on it. */
  replaceExisting?: boolean;
}

/**
 * Place (or update) a hold. Rejects when the quantity is not available *after*
 * everyone else's holds, which is what stops two reps selling the same rolls.
 */
async function reserveStock(input: ReserveInput): Promise<StockReservation | null> {
  const { itemCode, qty, user, orderId = null, replaceExisting = true } = input;

  if (USE_MOCK) {
    return mutate((d) => {
      const item = d.minStock.find((i) => i.itemCode === itemCode);
      // Not a minimum-stock item: nothing to reserve, and that is not an error.
      if (!item) return null;

      const mine = d.reservations.filter(
        (r) => r.repId === user.id && r.itemCode === itemCode && r.orderId === orderId,
      );
      const heldByOthers = d.reservations
        .filter((r) => !mine.includes(r) && r.itemCode === itemCode)
        .reduce((s, r) => s + r.qty, 0);

      const free = item.onHand - heldByOthers;
      if (qty > free) throw new InsufficientStockError(itemCode, qty, Math.max(0, free));

      if (replaceExisting) d.reservations = d.reservations.filter((r) => !mine.includes(r));
      if (qty <= 0) return null;

      const row: StockReservation = {
        id: uid('RSV'),
        itemCode,
        qty,
        orderId,
        repId: user.id,
        repName: user.name,
        heldAt: nowIso(),
      };
      d.reservations.push(row);
      return clone(row);
    });
  }

  // Live: a whitelisted server method does the check and the write in one
  // transaction, closing the race the poll leaves open.
  return createDoc<StockReservation>(DOCTYPE.stockReservation, {
    itemCode,
    qty,
    orderId,
    repId: user.id,
    repName: user.name,
    heldAt: nowIso(),
  });
}

/** Drop every hold a rep has against a draft — used when they abandon it. */
async function releaseDraftHolds(user: User, orderId: string | null = null): Promise<void> {
  if (USE_MOCK) {
    mutate((d) => {
      d.reservations = d.reservations.filter(
        (r) => !(r.repId === user.id && r.orderId === orderId),
      );
    });
    return;
  }
  const rows = await listDocs<StockReservation>(DOCTYPE.stockReservation, {
    filters: [['repId', '=', user.id]],
  });
  await Promise.all(
    rows
      .filter((r) => r.orderId === orderId)
      .map((r) => updateDoc(DOCTYPE.stockReservation, r.id, { qty: 0 })),
  );
}

/** Attach a draft's holds to the order once it is actually saved. */
function bindHoldsToOrder(user: User, orderId: string): void {
  if (!USE_MOCK) return;
  mutate((d) => {
    d.reservations.forEach((r) => {
      if (r.repId === user.id && r.orderId === null) r.orderId = orderId;
    });
  });
}

/**
 * Consume stock for real. Called when the Sales Manager approves an order being
 * served from minimum stock (2.3, 3.5): the hold becomes a withdrawal, drawn
 * oldest-batch-first so aged stock clears before fresh (1.6).
 */
function consumeStock(itemCode: string, qty: number, orderId: string): void {
  if (!USE_MOCK) return;

  mutate((d) => {
    const item = d.minStock.find((i) => i.itemCode === itemCode);
    if (!item) return;

    let left = qty;
    const oldestFirst = [...item.batches]
      .filter((b) => b.remaining > 0)
      .sort((a, b) => a.stockedOn.localeCompare(b.stockedOn));
    for (const batch of oldestFirst) {
      if (left <= 0) break;
      const take = Math.min(left, batch.remaining);
      batch.remaining = round3(batch.remaining - take);
      left = round3(left - take);
    }
    item.onHand = round3(Math.max(0, item.onHand - qty));
    // The hold has been realised, so it is no longer a separate claim.
    d.reservations = d.reservations.filter(
      (r) => !(r.itemCode === itemCode && r.orderId === orderId),
    );
  });

  raiseLowStockAlertIfNeeded(itemCode);
}

/** Alert the Production Manager the moment an item drops below threshold (3.5). */
function raiseLowStockAlertIfNeeded(itemCode: string): void {
  const item = getDb().minStock.find((i) => i.itemCode === itemCode);
  if (!item || !isBelowThreshold(item) || item.replenishmentRaised) return;

  emit({
    kind: 'min_stock_low',
    severity: 'warning',
    title: `${item.itemName} is below minimum stock`,
    body: `On hand ${item.onHand} ${item.uom}, threshold ${item.threshold} ${item.uom}. Raise a priority production order to replenish.`,
    audience: ['production_manager', 'stock_manager'],
    itemCode,
  });
}

/** Production Manager raises a priority run for a depleted item (3.5). */
async function raiseReplenishment(
  item: MinStockItem,
  qty: number,
  user: User,
): Promise<ProductionOrder> {
  const order: ProductionOrder = {
    id: uid('PROD'),
    itemCode: item.itemCode,
    itemName: item.itemName,
    qty,
    raisedAt: nowIso(),
    raisedBy: user.name,
    status: 'open',
    reason: 'replenishment',
  };

  if (USE_MOCK) {
    mutate((d) => {
      d.productionOrders.unshift(order);
      const target = d.minStock.find((i) => i.itemCode === item.itemCode);
      if (target) target.replenishmentRaised = true;
    });
  } else {
    await createDoc(DOCTYPE.productionOrder, order as unknown as Record<string, unknown>);
  }

  emit({
    kind: 'min_stock_low',
    severity: 'info',
    title: `Replenishment raised for ${item.itemName}`,
    body: `${qty} ${item.uom} queued as a priority run. Update the ledger once the run is complete.`,
    audience: ['stock_manager', 'production_manager'],
    itemCode: item.itemCode,
  });

  return order;
}

async function listProductionOrders(): Promise<ProductionOrder[]> {
  if (USE_MOCK) return delay(getDb().productionOrders, 60);
  return listDocs<ProductionOrder>(DOCTYPE.productionOrder, {
    orderBy: 'raisedAt desc',
    limit: 0,
  }).catch(ifMissing([]));
}

/**
 * Stock Manager books in a completed run (3.5). The quantity lands as a *new
 * dated batch* rather than being added to an existing one, which is what keeps
 * the "8 old / 2 new" split in 1.6 meaningful.
 */
async function recordReplenishment(
  itemCode: string,
  qty: number,
  user: User,
  productionOrderId?: string,
): Promise<MinStockItem | undefined> {
  const today = nowIso().slice(0, 10);

  const updated = USE_MOCK
    ? mutate((d) => {
        const item = d.minStock.find((i) => i.itemCode === itemCode);
        if (!item) return undefined;
        item.batches.push({ id: uid('B'), stockedOn: today, remaining: qty, original: qty });
        item.onHand = round3(item.onHand + qty);
        item.lastRestockedOn = today;
        item.replenishmentRaised = false;

        if (productionOrderId) {
          const po = d.productionOrders.find((p) => p.id === productionOrderId);
          if (po) {
            po.status = 'completed';
            po.completedAt = nowIso();
          }
        }
        return clone(item);
      })
    : await updateDoc<MinStockItem>(DOCTYPE.minStock, itemCode, {
        onHand: qty,
        lastRestockedOn: today,
      });

  if (updated) {
    // Everyone selling this item needs the new number, not just the floor.
    emit({
      kind: 'min_stock_replenished',
      severity: 'info',
      title: `${updated.itemName} restocked`,
      body: `${user.name} booked in ${qty} ${updated.uom}. Now ${updated.onHand} ${updated.uom} on hand.`,
      audience: ['sales_manager', 'production_manager'],
      itemCode,
    });
  }
  return updated;
}

/** Items currently under their threshold — the Production Manager's watchlist. */
export function belowThreshold(items: MinStockItem[]): MinStockItem[] {
  return items.filter(isBelowThreshold);
}

/** Free-to-sell quantity for an item code, or null when it is not tracked. */
export function availableFor(items: MinStockItem[], itemCode: string): number | null {
  const item = items.find((i) => i.itemCode === itemCode);
  return item ? availableQty(item) : null;
}

// ===========================================================================
// 7. ORDERS
// ===========================================================================
//
// Every state change routes through here so three things always happen together
// and can never drift apart:
//   1. the order document is updated,
//   2. a timeline entry is appended (the audit trail every role reads), and
//   3. the right people are notified.
//
// The two invariants from `domain/orderRules` are re-checked here rather than
// trusted from the UI — a screen that forgets to disable a button still cannot
// move a locked rate or edit a frozen order.

export interface OrderQuery {
  repId?: string;
  status?: OrderStatus[];
  customerId?: string;
  /** Hide orders already folded into a weekly group (3.4). */
  excludeGrouped?: boolean;
}

async function listOrders(query: OrderQuery = {}): Promise<Order[]> {
  if (USE_MOCK) {
    let rows = getDb().orders;
    if (query.repId) rows = rows.filter((o) => o.repId === query.repId);
    if (query.customerId) rows = rows.filter((o) => o.customerId === query.customerId);
    if (query.status?.length) rows = rows.filter((o) => query.status!.includes(o.status));
    if (query.excludeGrouped) rows = rows.filter((o) => !o.weeklyGroupId);
    rows = [...rows].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
    return delay(rows);
  }

  const filters: Filter[] = [];
  if (query.repId) filters.push(['custom_sales_person', '=', query.repId]);
  if (query.status?.length) filters.push(['custom_sales_status', 'in', query.status]);
  if (query.customerId) filters.push(['customer', '=', query.customerId]);
  return listDocs<Order>(DOCTYPE.salesOrder, {
    filters,
    orderBy: 'creation desc',
    limit: 0,
  });
}

async function getOrder(id: string): Promise<Order | undefined> {
  if (USE_MOCK) return delay(getDb().orders.find((o) => o.id === id), 80);
  const rows = await listDocs<Order>(DOCTYPE.salesOrder, { filters: [['name', '=', id]] });
  return rows[0];
}

/** What the Production Manager is allowed to load (3.1). */
async function listForProduction(): Promise<Order[]> {
  return listOrders({ status: ['approved', 'in_production'], excludeGrouped: true });
}

async function listAwaitingApproval(): Promise<Order[]> {
  return listOrders({ status: ['pending_approval'] });
}

export interface CreateOrderInput {
  customerId: string;
  customerName: string;
  destination: string;
  deliveryDate: string;
  items: Array<Omit<OrderItem, 'id' | 'rateLocked'>>;
  generateProforma: boolean;
  notes?: string;
  user: User;
}

/**
 * Raise a new order.
 *
 * `createdAt` is stamped here, once, and is never written again by anything in
 * this module — it is the reference point the edit-freeze deadline and the whole
 * audit trail hang off (1.7, 3.2).
 */
async function createOrder(input: CreateOrderInput): Promise<Order> {
  const orderNo = USE_MOCK ? nextOrderNo() : '';
  const createdAt = nowIso();

  const order: Order = {
    id: orderNo || uid('SO'),
    orderNo: orderNo || 'pending',
    customerId: input.customerId,
    customerName: input.customerName,
    destination: input.destination,
    repId: input.user.id,
    repName: input.user.name,
    status: 'pending_approval',
    items: input.items.map((it) => ({ ...it, id: uid('IT'), rateLocked: false })),
    deliveryDate: input.deliveryDate,
    createdAt,
    proformaGenerated: input.generateProforma,
    proformaNo: input.generateProforma ? `PF-${(orderNo || '').replace(/^SO-/, '')}` : undefined,
    notes: input.notes,
    timeline: [
      timelineEntry(
        input.user,
        'Order created',
        `${input.items.length} item(s) · delivery ${formatDate(input.deliveryDate)}`,
      ),
      timelineEntry(
        input.user,
        'Sent for approval',
        input.generateProforma ? 'Proforma generated' : 'Raised without a proforma',
      ),
    ],
  };

  if (USE_MOCK) {
    mutate((d) => d.orders.unshift(order));
    // Draft holds now belong to a real order, so they stop expiring (1.2).
    bindHoldsToOrder(input.user, order.id);
  } else {
    await createDoc(DOCTYPE.salesOrder, order as unknown as Record<string, unknown>);
  }

  emit({
    kind: 'order_submitted',
    title: `New order ${order.orderNo} needs approval`,
    body: `${input.user.name} raised ${formatMoney(orderTotal(order.items))} for ${input.customerName}. Delivery ${formatDate(input.deliveryDate)}.`,
    audience: ['sales_manager'],
    orderId: order.id,
  });

  return clone(order);
}

/**
 * Replace an order's lines.
 *
 * Refuses once the order is frozen, and silently preserves every locked rate:
 * even if the caller passes a different `finalRate`, the stored one wins (2.2).
 * A change made after approval raises a must-acknowledge alert to the floor
 * (3.3).
 */
async function updateOrderItems(
  orderId: string,
  items: OrderItem[],
  user: User,
  note?: string,
): Promise<Order> {
  const existing = await requireOrder(orderId);

  const permission = canEditItems(existing, user);
  if (!permission.allowed) throw new Error(permission.message);

  const previousById = new Map(existing.items.map((i) => [i.id, i]));
  const merged = items.map((incoming) => {
    const prev = previousById.get(incoming.id);
    if (prev && isRateLocked(prev, existing)) {
      // The rate is settled; accept every other change to the line.
      return {
        ...incoming,
        quotedRate: prev.quotedRate,
        finalRate: prev.finalRate,
        rateLocked: true,
      };
    }
    return incoming;
  });

  const postApproval = isPostApprovalEdit(existing);
  const summary = describeItemDiff(existing.items, merged);

  const updated = await persistOrder(orderId, (o) => {
    o.items = merged;
    o.timeline.push(
      timelineEntry(
        user,
        postApproval ? 'Items changed after approval' : 'Items updated',
        note ?? summary,
        postApproval,
      ),
    );
  });

  if (postApproval) {
    emit({
      kind: 'order_edited_post_approval',
      severity: 'critical',
      title: `⚠ ${updated.orderNo} changed after approval`,
      body: `${user.name} changed this order while it is on the floor. ${summary} Acknowledge so the line knows.`,
      audience: ['production_manager'],
      orderId,
      requiresAck: true,
    });
  }

  return updated;
}

export interface ApproveInput {
  orderId: string;
  user: User;
  /** Final rate per item id. Anything omitted keeps the rep's quote (2.2). */
  finalRates: Record<string, number>;
  /** Per-item fulfilment decision (2.3). */
  sources: Record<string, FulfilmentSource>;
}

/**
 * Sales Manager approval — the point of no return for rates.
 *
 * Every line comes out with `rateLocked: true`. Lines routed to minimum stock
 * draw their quantity down immediately (3.5).
 */
async function approveOrder(input: ApproveInput): Promise<Order> {
  const existing = await requireOrder(input.orderId);
  const permission = canApprove(existing, input.user);
  if (!permission.allowed) throw new Error(permission.message);

  const at = nowIso();
  const updated = await persistOrder(input.orderId, (o) => {
    o.items = o.items.map((it) => ({
      ...it,
      finalRate: input.finalRates[it.id] ?? it.finalRate ?? it.quotedRate,
      rateLocked: true,
      source: input.sources[it.id] ?? it.source ?? 'new_production',
      stage: it.stage ?? firstStage(it.category),
    }));
    o.status = 'approved';
    o.approvedAt = at;
    o.approvedBy = input.user.name;
    o.timeline.push(
      timelineEntry(
        input.user,
        'Approved',
        `Rates finalised and locked · ${o.items.length} line(s) released to production`,
      ),
    );
  });

  // Draw down anything the manager sourced from minimum stock.
  updated.items
    .filter((it) => it.source === 'min_stock')
    .forEach((it) => consumeStock(it.itemCode, it.quantity, updated.id));

  // No rep-facing copy: the Sales Manager who approved it is the only audience
  // this app has, and telling the rep is the field-sales app's job.
  emit({
    kind: 'order_approved',
    title: `New job released: ${updated.orderNo}`,
    body: `${updated.destination} · delivery ${formatDate(effectiveDeliveryDate(updated))} · ${updated.items.length} line(s).`,
    audience: ['production_manager'],
    orderId: updated.id,
  });

  return updated;
}

async function rejectOrder(orderId: string, reason: string, user: User): Promise<Order> {
  const existing = await requireOrder(orderId);
  const permission = canApprove(existing, user);
  if (!permission.allowed) throw new Error(permission.message);

  const updated = await persistOrder(orderId, (o) => {
    o.status = 'rejected';
    o.rejectionReason = reason;
    o.timeline.push(timelineEntry(user, 'Rejected', reason));
  });

  // As with approval, the rejection reason goes back to the rep through the
  // field-sales app — there is nobody here left to tell.
  return updated;
}

/** Move one line along its process cycle (3.2). */
async function setItemStage(
  orderId: string,
  itemId: string,
  stage: string,
  user: User,
): Promise<Order> {
  const updated = await persistOrder(orderId, (o) => {
    const item = o.items.find((i) => i.id === itemId);
    if (!item) throw new Error('That line is no longer on this order.');
    item.stage = stage;
    item.stageUpdatedAt = nowIso();
    if (o.status === 'approved') o.status = 'in_production';
    o.timeline.push(
      timelineEntry(user, `${item.itemName} → ${stageLabel(item.category, stage)}`),
    );
  });

  const moved = updated.items.find((i) => i.id === itemId);
  emit({
    kind: 'stage_advanced',
    title: `${updated.orderNo} moved on`,
    body: moved
      ? `A line reached ${stageLabel(moved.category, stage)}.`
      : 'A line moved to the next stage.',
    audience: ['sales_manager'],
    orderId,
  });

  return updated;
}

/**
 * Production reschedules delivery (3.2). The rep is told, because the date they
 * promised the customer has just moved under them.
 */
async function changeDeliveryDate(
  orderId: string,
  newDate: string,
  reason: string,
  user: User,
): Promise<Order> {
  const existing = await requireOrder(orderId);
  const from = effectiveDeliveryDate(existing);
  const direction = newDate > from ? 'postponed' : 'preponed';

  const updated = await persistOrder(orderId, (o) => {
    o.revisedDeliveryDate = newDate;
    o.deliveryDateHistory = [
      ...(o.deliveryDateHistory ?? []),
      { from, to: newDate, changedAt: nowIso(), changedBy: user.name, reason },
    ];
    o.timeline.push(
      timelineEntry(
        user,
        `Delivery ${direction}`,
        `${formatDate(from)} → ${formatDate(newDate)} · ${reason}`,
      ),
    );
  });

  emit({
    kind: 'delivery_date_changed',
    severity: 'warning',
    title: `${updated.orderNo} delivery ${direction}`,
    body: `${formatDate(from)} → ${formatDate(newDate)}. ${reason}`,
    audience: ['sales_manager'],
    orderId,
  });

  return updated;
}

/** Acknowledge a post-approval change on the order's own timeline (3.3). */
async function acknowledgeChange(
  orderId: string,
  timelineId: string,
  user: User,
): Promise<Order> {
  return persistOrder(orderId, (o) => {
    const row = o.timeline.find((t) => t.id === timelineId);
    if (row) {
      row.ackedAt = nowIso();
      row.ackedBy = user.name;
    }
  });
}

async function dispatchOrder(orderId: string, user: User): Promise<Order> {
  const existing = await requireOrder(orderId);
  if (!allItemsReady(existing.items)) {
    const pending = existing.items.filter((i) => !isTerminalStage(i.category, i.stage));
    throw new Error(
      `${pending.length} line(s) have not reached Ready for Dispatch yet: ${pending
        .map((i) => i.itemName)
        .join(', ')}.`,
    );
  }

  const updated = await persistOrder(orderId, (o) => {
    o.status = 'dispatched';
    o.dispatchedAt = nowIso();
    o.timeline.push(timelineEntry(user, 'Dispatched', `${o.items.length} line(s) left the plant`));
  });

  emit({
    kind: 'order_dispatched',
    title: `${updated.orderNo} dispatched`,
    body: `Sent to ${updated.destination}.`,
    audience: ['sales_manager'],
    orderId,
  });
  return updated;
}

// --- weekly grouping (3.4) -------------------------------------------------

export interface WeekBucket {
  customerId: string;
  customerName: string;
  weekStart: string;
  weekEnd: string;
  orders: Order[];
  totalValue: number;
}

/**
 * Dispatched-but-ungrouped orders, bucketed by customer and week — exactly the
 * compilation the Production Manager is asked to make (3.4).
 */
export function bucketForGrouping(orders: Order[]): WeekBucket[] {
  const buckets = new Map<string, WeekBucket>();

  orders
    .filter((o) => o.status === 'dispatched' && !o.weeklyGroupId)
    .forEach((o) => {
      const anchor = o.dispatchedAt?.slice(0, 10) ?? effectiveDeliveryDate(o);
      const weekStart = weekStartOf(anchor);
      const key = `${o.customerId}::${weekStart}`;
      const bucket = buckets.get(key) ?? {
        customerId: o.customerId,
        customerName: o.customerName,
        weekStart,
        weekEnd: weekEndOf(anchor),
        orders: [],
        totalValue: 0,
      };
      bucket.orders.push(o);
      bucket.totalValue += orderTotal(o.items);
      buckets.set(key, bucket);
    });

  return [...buckets.values()].sort((a, b) => b.weekStart.localeCompare(a.weekStart));
}

async function compileWeeklyGroup(bucket: WeekBucket, user: User): Promise<WeeklyGroup> {
  const group: WeeklyGroup = {
    id: uid('WG'),
    customerId: bucket.customerId,
    customerName: bucket.customerName,
    weekStart: bucket.weekStart,
    weekEnd: bucket.weekEnd,
    orderIds: bucket.orders.map((o) => o.id),
    compiledAt: nowIso(),
    compiledBy: user.name,
    totalValue: bucket.totalValue,
  };

  if (USE_MOCK) {
    mutate((d) => {
      d.weeklyGroups.unshift(group);
      d.orders.forEach((o) => {
        if (group.orderIds.includes(o.id)) {
          o.weeklyGroupId = group.id;
          o.status = 'grouped';
          o.timeline.push(
            timelineEntry(user, 'Compiled into weekly group', `Week of ${formatDate(group.weekStart)}`),
          );
        }
      });
    });
  } else {
    await createDoc(DOCTYPE.weeklyGroup, group as unknown as Record<string, unknown>);
    await Promise.all(
      group.orderIds.map((id) =>
        updateDoc(DOCTYPE.salesOrder, id, {
          custom_weekly_group: group.id,
          custom_sales_status: 'grouped',
        }),
      ),
    );
  }

  emit({
    kind: 'orders_grouped',
    title: `${bucket.orders.length} orders compiled for ${bucket.customerName}`,
    body: `Week of ${formatDate(group.weekStart)} · ${formatMoney(group.totalValue)}.`,
    audience: ['sales_manager'],
    orderId: group.orderIds[0],
  });

  return group;
}

async function listWeeklyGroups(): Promise<WeeklyGroup[]> {
  if (USE_MOCK) return delay(getDb().weeklyGroups, 60);
  return listDocs<WeeklyGroup>(DOCTYPE.weeklyGroup, {
    orderBy: 'compiledAt desc',
    limit: 0,
  }).catch(ifMissing([]));
}

// --- order helpers ---------------------------------------------------------

async function requireOrder(id: string): Promise<Order> {
  const order = await getOrder(id);
  if (!order) throw new Error('That order no longer exists.');
  return order;
}

/** Apply a mutation to one order and return the fresh copy. */
async function persistOrder(orderId: string, fn: (o: Order) => void): Promise<Order> {
  if (USE_MOCK) {
    return mutate((d) => {
      const order = d.orders.find((o) => o.id === orderId);
      if (!order) throw new Error('That order no longer exists.');
      fn(order);
      return clone(order);
    });
  }
  const draft = clone(await requireOrder(orderId));
  fn(draft);
  return updateDoc<Order>(DOCTYPE.salesOrder, orderId, draft as unknown as Record<string, unknown>);
}

function timelineEntry(
  user: User,
  action: string,
  detail?: string,
  requiresAck = false,
): TimelineEntry {
  return {
    id: uid('TL'),
    at: nowIso(),
    actorId: user.id,
    actorName: user.name,
    actorRole: user.role,
    action,
    detail,
    requiresAck: requiresAck || undefined,
  };
}

/** A one-line, human summary of what changed — goes straight into the alert. */
function describeItemDiff(before: OrderItem[], after: OrderItem[]): string {
  const beforeById = new Map(before.map((i) => [i.id, i]));
  const afterById = new Map(after.map((i) => [i.id, i]));

  const added = after.filter((i) => !beforeById.has(i.id));
  const removed = before.filter((i) => !afterById.has(i.id));
  const changed = after.filter((i) => {
    const prev = beforeById.get(i.id);
    return prev && prev.quantity !== i.quantity;
  });

  const parts: string[] = [];
  if (added.length) parts.push(`added ${added.map((i) => i.itemName).join(', ')}`);
  if (removed.length) parts.push(`removed ${removed.map((i) => i.itemName).join(', ')}`);
  changed.forEach((i) => {
    const prev = beforeById.get(i.id)!;
    parts.push(`${i.itemName} ${prev.quantity} → ${i.quantity} ${i.uom}`);
  });
  return parts.length ? `${capitalise(parts.join('; '))}.` : 'Line details revised.';
}

// ===========================================================================
// 8. EXCEL IMPORT
// ===========================================================================
//
// Parsing is deliberately forgiving about column *names* — sheets come from
// whoever maintains them, so headers are matched case- and space-insensitively
// against a list of aliases — and deliberately strict about *values*: a PCTR row
// with no average roll weight cannot price an order, so it is rejected with its
// row number rather than imported half-broken.
//
// `xlsx` is loaded on demand. It is by far the largest dependency here and
// nobody needs it until they open the import screen, so it stays out of the
// main bundle.

export type ImportKind = 'products' | 'customers';

export interface RowIssue {
  /** 1-based row number as it appears in Excel, header included. */
  row: number;
  column: string;
  message: string;
}

export interface ParseResult<T> {
  kind: ImportKind;
  /** Rows that passed validation and are safe to commit. */
  valid: T[];
  issues: RowIssue[];
  /** Headers as they appeared in the sheet, for the mapping preview. */
  headers: string[];
  totalRows: number;
}

export interface CommitResult {
  created: number;
  updated: number;
}

const PRODUCT_ALIASES: Record<string, string[]> = {
  code: ['item code', 'code', 'item_code', 'sku', 'product code'],
  name: ['item name', 'name', 'description', 'product', 'product name'],
  category: ['category', 'type', 'product category', 'group'],
  size: ['size', 'dimension', 'dimensions'],
  avgWeightPerRoll: ['avg weight per roll', 'average weight', 'avg roll weight', 'avg weight', 'average weight per roll'],
  beltsPerRoll: ['belts per roll', 'belts/roll', 'no of belts', 'belts'],
  exactWeightPerRoll: ['exact weight per roll', 'roll weight', 'weight per roll', 'exact weight'],
  tinSize: ['tin size', 'volume', 'litres', 'liters', 'size (l)'],
  defaultRate: ['rate', 'standard rate', 'default rate', 'price'],
  hsnCode: ['hsn', 'hsn code', 'hsn_code'],
};

const CUSTOMER_ALIASES: Record<string, string[]> = {
  id: ['customer id', 'code', 'customer code', 'id'],
  name: ['customer name', 'name', 'customer'],
  destination: ['destination', 'delivery location', 'location', 'place'],
  address: ['address', 'billing address', 'full address'],
  gstin: ['gstin', 'gst', 'gst no', 'gst number', 'gstin/uin'],
  state: ['state', 'state name'],
  phone: ['phone', 'mobile', 'contact', 'phone no'],
  email: ['email', 'email id', 'e-mail'],
  creditLimit: ['credit limit', 'limit'],
  assignedReps: ['reps', 'sales person', 'assigned reps', 'rep'],
};

const CATEGORY_SYNONYMS: Record<string, ProductCategory> = {
  pctr: 'PCTR',
  'precured tread rubber': 'PCTR',
  precured: 'PCTR',
  ctr: 'CTR',
  'conventional tread rubber': 'CTR',
  conventional: 'CTR',
  bg: 'BG',
  'bonding gum': 'BG',
  gum: 'BG',
  vs: 'VS',
  'vulcanizing solution': 'VS',
  'vulcanising solution': 'VS',
  solution: 'VS',
};

function normaliseHeader(header: string): string {
  return String(header).trim().toLowerCase().replace(/[\s_]+/g, ' ');
}

/** Build header→field lookup from the alias tables above. */
function buildHeaderMap(headers: string[], aliases: Record<string, string[]>): Map<string, string> {
  const map = new Map<string, string>();
  headers.forEach((h) => {
    const n = normaliseHeader(h);
    for (const [field, options] of Object.entries(aliases)) {
      if (options.includes(n)) {
        map.set(h, field);
        return;
      }
    }
  });
  return map;
}

async function readSheet(
  file: ArrayBuffer,
): Promise<{ rows: Record<string, unknown>[]; headers: string[] }> {
  const XLSX = await import('xlsx');
  const wb = XLSX.read(file, { type: 'array' });
  const sheet = wb.Sheets[wb.SheetNames[0]];
  if (!sheet) return { rows: [], headers: [] };
  const rows = XLSX.utils.sheet_to_json<Record<string, unknown>>(sheet, { defval: '' });
  const headerRow = XLSX.utils.sheet_to_json<string[]>(sheet, { header: 1 })[0] ?? [];
  return { rows, headers: headerRow.map(String).filter(Boolean) };
}

async function parseProducts(file: ArrayBuffer): Promise<ParseResult<Product>> {
  const { rows, headers } = await readSheet(file);
  const map = buildHeaderMap(headers, PRODUCT_ALIASES);
  const valid: Product[] = [];
  const issues: RowIssue[] = [];

  rows.forEach((raw, i) => {
    const rowNo = i + 2; // header is row 1
    const get = (field: string): unknown => {
      for (const [header, mapped] of map) if (mapped === field) return raw[header];
      return undefined;
    };
    const push = (column: string, message: string) => issues.push({ row: rowNo, column, message });

    const code = String(get('code') ?? '').trim();
    const name = String(get('name') ?? '').trim();
    const category = CATEGORY_SYNONYMS[normaliseHeader(String(get('category') ?? ''))];

    if (!code) push('Item Code', 'Missing item code.');
    if (!name) push('Item Name', 'Missing item name.');
    if (!category) {
      push('Category', `Unrecognised category "${get('category') ?? ''}" — expected PCTR, CTR, BG or VS.`);
      return;
    }

    const product: Product = {
      code,
      name: name || code,
      category,
      size: str(get('size')),
      defaultRate: numOrUndef(get('defaultRate')),
      hsnCode: str(get('hsnCode')),
      active: true,
    };

    // Each family needs the numbers its pricing maths depends on.
    switch (category) {
      case 'PCTR': {
        product.avgWeightPerRoll = numOrUndef(get('avgWeightPerRoll'));
        product.beltsPerRoll = numOrUndef(get('beltsPerRoll'));
        if (!product.avgWeightPerRoll) push('Avg Weight Per Roll', 'PCTR needs an average roll weight in kg.');
        if (!product.beltsPerRoll) push('Belts Per Roll', 'PCTR needs the number of belts per roll.');
        break;
      }
      case 'CTR': {
        product.exactWeightPerRoll =
          numOrUndef(get('exactWeightPerRoll')) ?? numOrUndef(get('avgWeightPerRoll'));
        if (!product.exactWeightPerRoll) push('Weight Per Roll', 'CTR needs an exact roll weight in kg.');
        break;
      }
      case 'VS': {
        const tin = numOrUndef(get('tinSize'));
        if (tin !== 10 && tin !== 30) push('Tin Size', 'Vulcanizing Solution must be a 10L or 30L tin.');
        else product.tinSize = tin;
        break;
      }
      case 'BG':
        break;
    }

    if (!issues.some((x) => x.row === rowNo)) valid.push(product);
  });

  return { kind: 'products', valid, issues, headers, totalRows: rows.length };
}

async function parseCustomers(file: ArrayBuffer): Promise<ParseResult<Customer>> {
  const { rows, headers } = await readSheet(file);
  const map = buildHeaderMap(headers, CUSTOMER_ALIASES);
  const valid: Customer[] = [];
  const issues: RowIssue[] = [];

  rows.forEach((raw, i) => {
    const rowNo = i + 2;
    const get = (field: string): unknown => {
      for (const [header, mapped] of map) if (mapped === field) return raw[header];
      return undefined;
    };
    const push = (column: string, message: string) => issues.push({ row: rowNo, column, message });

    const name = String(get('name') ?? '').trim();
    const gstin = String(get('gstin') ?? '').trim().toUpperCase();
    const address = String(get('address') ?? '').trim();

    if (!name) push('Customer Name', 'Missing customer name.');
    // GST and address both print on the proforma, so a blank one is a real
    // problem rather than a cosmetic gap (1.3).
    if (!address) push('Address', 'Address is required — it prints on the proforma.');
    if (!gstin) push('GSTIN', 'GSTIN is required — it prints on the proforma.');
    else if (!/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z][Z][0-9A-Z]$/.test(gstin)) {
      push('GSTIN', `"${gstin}" is not a valid 15-character GSTIN.`);
    }

    if (issues.some((x) => x.row === rowNo)) return;

    valid.push({
      id: String(get('id') ?? '').trim() || name,
      name,
      destination: str(get('destination')) ?? address.split(',').slice(-2)[0]?.trim() ?? address,
      address,
      gstin,
      state: str(get('state')) ?? '',
      phone: str(get('phone')),
      email: str(get('email')),
      outstandingBalance: 0,
      creditLimit: numOrUndef(get('creditLimit')) ?? 0,
      assignedReps: String(get('assignedReps') ?? '')
        .split(/[,|]/)
        .map((s) => s.trim())
        .filter(Boolean),
    });
  });

  return { kind: 'customers', valid, issues, headers, totalRows: rows.length };
}

async function commitProducts(products: Product[]): Promise<CommitResult> {
  if (USE_MOCK) {
    return mutate((d) => {
      let created = 0;
      let updated = 0;
      products.forEach((p) => {
        const i = d.products.findIndex((x) => x.code === p.code);
        if (i >= 0) {
          d.products[i] = { ...d.products[i], ...p };
          updated += 1;
        } else {
          d.products.push(p);
          created += 1;
        }
      });
      return { created, updated };
    });
  }

  let created = 0;
  for (const p of products) {
    const body: Record<string, unknown> = {
      item_code: p.code,
      item_name: p.name,
      stock_uom: p.category === 'VS' ? 'Litre' : 'Kg',
      standard_rate: p.defaultRate ?? 0,
      gst_hsn_code: p.hsnCode,
      [ITEM_FIELD.category]: p.category,
      [ITEM_FIELD.avgWeightPerRoll]: p.avgWeightPerRoll,
      [ITEM_FIELD.beltsPerRoll]: p.beltsPerRoll,
      [ITEM_FIELD.exactWeightPerRoll]: p.exactWeightPerRoll,
      [ITEM_FIELD.tinSize]: p.tinSize,
      [ITEM_FIELD.size]: p.size,
    };
    // Upsert: try an update, fall back to create when the item is new.
    try {
      await updateDoc(DOCTYPE.item, p.code, body);
    } catch {
      await createDoc(DOCTYPE.item, body);
      created += 1;
    }
  }
  return { created, updated: products.length - created };
}

async function commitCustomers(customers: Customer[]): Promise<CommitResult> {
  if (USE_MOCK) {
    return mutate((d) => {
      let created = 0;
      let updated = 0;
      customers.forEach((c) => {
        const i = d.customers.findIndex((x) => x.id === c.id || x.name === c.name);
        if (i >= 0) {
          // Keep the live outstanding balance; the sheet does not own it.
          d.customers[i] = {
            ...d.customers[i],
            ...c,
            outstandingBalance: d.customers[i].outstandingBalance,
          };
          updated += 1;
        } else {
          d.customers.push(c);
          created += 1;
        }
      });
      return { created, updated };
    });
  }

  let created = 0;
  for (const c of customers) {
    const body: Record<string, unknown> = {
      customer_name: c.name,
      primary_address: c.address,
      mobile_no: c.phone,
      email_id: c.email,
      [CUSTOMER_FIELD.gstin]: c.gstin,
      [CUSTOMER_FIELD.destination]: c.destination,
      [CUSTOMER_FIELD.creditLimit]: c.creditLimit,
      [CUSTOMER_FIELD.assignedReps]: c.assignedReps.length ? `|${c.assignedReps.join('|')}|` : '',
    };
    try {
      await updateDoc(DOCTYPE.customer, c.id, body);
    } catch {
      await createDoc(DOCTYPE.customer, body);
      created += 1;
    }
  }
  return { created, updated: customers.length - created };
}

/** A blank sheet with the expected headers, so the office can fill it in. */
async function downloadTemplate(kind: ImportKind): Promise<void> {
  const XLSX = await import('xlsx');
  const headers =
    kind === 'products'
      ? ['Item Code', 'Item Name', 'Category', 'Size', 'Avg Weight Per Roll', 'Belts Per Roll', 'Exact Weight Per Roll', 'Tin Size', 'Rate', 'HSN Code']
      : ['Customer ID', 'Customer Name', 'Destination', 'Address', 'GSTIN', 'State', 'Phone', 'Email', 'Credit Limit', 'Reps'];

  const example =
    kind === 'products'
      ? [
          ['PCTR-140-08', 'Precured Tread 140mm x 8mm', 'PCTR', '140 x 8', 28.5, 6, '', '', 262, '40061000'],
          ['CTR-10-450', 'Conventional Tread 10mm x 450mm', 'CTR', '10 x 450', '', '', 40, '', 240, '40061000'],
          ['BG-STD', 'Bonding Gum — Standard', 'BG', '', '', '', '', '', 185, '40059100'],
          ['VS-10L', 'Vulcanizing Solution 10L', 'VS', '', '', '', '', 10, 1450, '40059900'],
        ]
      : [['CUST-0001', 'Kerala Tyre Retreaders', 'Aluva, Ernakulam', 'Door 14/221, NH Bypass, Aluva 683101', '32AABCK1234M1Z5', 'Kerala', '9847011223', '', 500000, 'Subhash']];

  const ws = XLSX.utils.aoa_to_sheet([headers, ...example]);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, kind === 'products' ? 'Products' : 'Customers');
  XLSX.writeFile(wb, `manna-${kind}-template.xlsx`);
}

// ===========================================================================
// SHARED UTILITIES
// ===========================================================================

function str(v: unknown): string | undefined {
  const s = String(v ?? '').trim();
  return s === '' ? undefined : s;
}

function numOrUndef(v: unknown): number | undefined {
  if (v === '' || v == null) return undefined;
  const n = Number(v);
  return Number.isFinite(n) && n !== 0 ? n : undefined;
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

function capitalise(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function formatMoney(n: number): string {
  return `₹${n.toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;
}

// ===========================================================================
// 9. HR
// ===========================================================================

/**
 * People, attendance and leave.
 *
 * These three map onto stock ERPNext HR doctypes rather than custom ones, so
 * the real branch is mostly field renaming: `Employee`, `Attendance` and
 * `Leave Application` already exist on any site with the HR app installed.
 * Where ERPNext spells a status `On Leave` and we spell it `on_leave`, the
 * translation happens here and nowhere else.
 */

async function listEmployees(): Promise<Employee[]> {
  if (USE_MOCK) return delay(getDb().employees, 80);

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.employee, {
    fields: [
      'name',
      ...Object.values(EMPLOYEE_FIELD),
    ],
    orderBy: `${EMPLOYEE_FIELD.employeeName} asc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([]));

  return rows.map(toEmployee);
}

/** Attendance rows in an inclusive ISO date range. */
async function listAttendance(fromIso: string, toIso: string): Promise<AttendanceRecord[]> {
  if (USE_MOCK) {
    const rows = getDb().attendance.filter((r) => r.date >= fromIso && r.date <= toIso);
    return delay(rows, 80);
  }

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.attendance, {
    fields: ['name', ...Object.values(ATTENDANCE_FIELD)],
    filters: [
      [ATTENDANCE_FIELD.date, '>=', fromIso],
      [ATTENDANCE_FIELD.date, '<=', toIso],
    ],
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([]));

  return rows.map(toAttendance);
}

/**
 * Mark one employee for one day.
 *
 * Attendance is one document per employee per day, so marking twice must
 * *correct* the existing row rather than add a second one — otherwise a
 * mistyped absence stays on the record forever next to its correction.
 */
async function markAttendance(input: {
  employeeId: string;
  date: string;
  status: AttendanceStatus;
  checkIn?: string;
  checkOut?: string;
  note?: string;
  markedBy: User;
}): Promise<AttendanceRecord> {
  const row: AttendanceRecord = {
    id: `ATT-${input.date}-${input.employeeId}`,
    employeeId: input.employeeId,
    date: input.date,
    status: input.status,
    checkIn: input.checkIn,
    checkOut: input.checkOut,
    note: input.note,
    markedBy: input.markedBy.name,
  };

  if (USE_MOCK) {
    return mutate((d) => {
      const at = d.attendance.findIndex(
        (r) => r.employeeId === input.employeeId && r.date === input.date,
      );
      if (at >= 0) d.attendance[at] = row;
      else d.attendance.push(row);
      return clone(row);
    });
  }

  const existing = await listDocs<{ name: string }>(DOCTYPE.attendance, {
    fields: ['name'],
    filters: [
      [ATTENDANCE_FIELD.employee, '=', input.employeeId],
      [ATTENDANCE_FIELD.date, '=', input.date],
    ],
    limit: 1,
  }).catch(ifMissing<{ name: string }[]>([]));

  const body = {
    [ATTENDANCE_FIELD.employee]: input.employeeId,
    [ATTENDANCE_FIELD.date]: input.date,
    [ATTENDANCE_FIELD.status]: ATTENDANCE_STATUS_OUT[input.status],
    [ATTENDANCE_FIELD.checkIn]: input.checkIn ?? null,
    [ATTENDANCE_FIELD.checkOut]: input.checkOut ?? null,
    [ATTENDANCE_FIELD.note]: input.note ?? null,
  };

  const saved = existing[0]
    ? await updateDoc<Record<string, unknown>>(DOCTYPE.attendance, existing[0].name, body)
    : await createDoc<Record<string, unknown>>(DOCTYPE.attendance, body);

  return toAttendance(saved);
}

async function listLeaveRequests(): Promise<LeaveRequest[]> {
  if (USE_MOCK) return delay(getDb().leaveRequests, 80);

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.leaveApplication, {
    fields: ['name', 'creation', 'department', ...Object.values(LEAVE_FIELD)],
    orderBy: 'creation desc',
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([]));

  return rows.map(toLeaveRequest);
}

/**
 * Approve or reject a request.
 *
 * Approving spends the balance and writes the leave straight onto the
 * attendance sheet for every working day it covers, because an approved leave
 * that still shows as "not marked" on the roster is the thing that gets an
 * employee wrongly recorded absent.
 */
async function decideLeave(input: {
  request: LeaveRequest;
  approve: boolean;
  decidedBy: User;
  note?: string;
}): Promise<LeaveRequest> {
  const { request, approve, decidedBy, note } = input;

  const decided: LeaveRequest = {
    ...request,
    status: approve ? 'approved' : 'rejected',
    decidedAt: nowIso(),
    decidedBy: decidedBy.name,
    decisionNote: note?.trim() || undefined,
  };

  if (USE_MOCK) {
    mutate((d) => {
      const at = d.leaveRequests.findIndex((r) => r.id === request.id);
      if (at >= 0) d.leaveRequests[at] = decided;
      if (!approve) return;

      const employee = d.employees.find((e) => e.id === request.employeeId);
      if (employee && request.type !== 'unpaid') {
        employee.leaveBalance = round3(Math.max(0, employee.leaveBalance - request.days));
      }

      for (
        let date = request.fromDate;
        date <= request.toDate;
        date = shiftDays(date, 1)
      ) {
        if (isWeeklyOff(date)) continue;
        const row: AttendanceRecord = {
          id: `ATT-${date}-${request.employeeId}`,
          employeeId: request.employeeId,
          date,
          status: 'on_leave',
          markedBy: decidedBy.name,
          note: `${LEAVE_TYPE_LABEL[request.type]} — ${request.id}`,
        };
        const existing = d.attendance.findIndex(
          (r) => r.employeeId === request.employeeId && r.date === date,
        );
        if (existing >= 0) d.attendance[existing] = row;
        else d.attendance.push(row);
      }
    });
  } else {
    await updateDoc(DOCTYPE.leaveApplication, request.id, {
      [LEAVE_FIELD.status]: approve ? 'Approved' : 'Rejected',
      [LEAVE_FIELD.decisionNote]: decided.decisionNote ?? null,
    });
  }

  emit({
    kind: 'leave_decided',
    severity: approve ? 'info' : 'warning',
    title: `Leave ${approve ? 'approved' : 'rejected'} — ${request.employeeName}`,
    body: `${LEAVE_TYPE_LABEL[request.type]}, ${formatDate(request.fromDate)} to ${formatDate(request.toDate)} (${request.days} day${request.days === 1 ? '' : 's'}).`,
    audience: ['hr'],
  });

  return decided;
}

// --- ERPNext ⇄ app translation -------------------------------------------

const ATTENDANCE_STATUS_IN: Record<string, AttendanceStatus> = {
  Present: 'present',
  Absent: 'absent',
  'On Leave': 'on_leave',
  'Half Day': 'half_day',
  Holiday: 'holiday',
};

const ATTENDANCE_STATUS_OUT: Record<AttendanceStatus, string> = {
  present: 'Present',
  absent: 'Absent',
  on_leave: 'On Leave',
  half_day: 'Half Day',
  holiday: 'Holiday',
};

const LEAVE_STATUS_IN: Record<string, LeaveStatus> = {
  Open: 'pending',
  Approved: 'approved',
  Rejected: 'rejected',
  Cancelled: 'cancelled',
};

function toEmployee(row: Record<string, unknown>): Employee {
  const relieved = str(row[EMPLOYEE_FIELD.relievedOn]);
  return {
    id: String(row.name),
    name: str(row[EMPLOYEE_FIELD.employeeName]) ?? String(row.name),
    designation: str(row[EMPLOYEE_FIELD.designation]) ?? '—',
    department: toDepartment(str(row[EMPLOYEE_FIELD.department])),
    employmentType: toEmploymentType(str(row[EMPLOYEE_FIELD.employmentType])),
    joinedOn: (str(row[EMPLOYEE_FIELD.joinedOn]) ?? nowIso()).slice(0, 10),
    // ERPNext keeps a relieving date on some active records; `status` is what
    // actually decides whether someone is still on the books.
    leftOn: str(row[EMPLOYEE_FIELD.status]) === 'Active' ? undefined : relieved?.slice(0, 10),
    phone: str(row[EMPLOYEE_FIELD.phone]),
    email: str(row[EMPLOYEE_FIELD.email]),
    location: str(row[EMPLOYEE_FIELD.branch]),
    reportsTo: str(row[EMPLOYEE_FIELD.reportsTo]),
    userId: str(row[EMPLOYEE_FIELD.user]),
    leaveBalance: Number(row[EMPLOYEE_FIELD.leaveBalance] ?? 0) || 0,
  };
}

function toAttendance(row: Record<string, unknown>): AttendanceRecord {
  return {
    id: String(row.name),
    employeeId: String(row[ATTENDANCE_FIELD.employee] ?? ''),
    date: (str(row[ATTENDANCE_FIELD.date]) ?? '').slice(0, 10),
    status: ATTENDANCE_STATUS_IN[str(row[ATTENDANCE_FIELD.status]) ?? ''] ?? 'present',
    checkIn: str(row[ATTENDANCE_FIELD.checkIn])?.slice(11, 16),
    checkOut: str(row[ATTENDANCE_FIELD.checkOut])?.slice(11, 16),
    note: str(row[ATTENDANCE_FIELD.note]),
  };
}

function toLeaveRequest(row: Record<string, unknown>): LeaveRequest {
  const from = (str(row[LEAVE_FIELD.fromDate]) ?? '').slice(0, 10);
  const to = (str(row[LEAVE_FIELD.toDate]) ?? from).slice(0, 10);
  return {
    id: String(row.name),
    employeeId: String(row[LEAVE_FIELD.employee] ?? ''),
    employeeName: str(row[LEAVE_FIELD.employeeName]) ?? '—',
    department: toDepartment(str(row.department)),
    type: toLeaveType(str(row[LEAVE_FIELD.type])),
    fromDate: from,
    toDate: to,
    days: Number(row[LEAVE_FIELD.days] ?? 0) || workingDaysBetween(from, to),
    reason: str(row[LEAVE_FIELD.reason]) ?? '',
    status: LEAVE_STATUS_IN[str(row[LEAVE_FIELD.status]) ?? ''] ?? 'pending',
    appliedAt: str(row.creation) ?? nowIso(),
    decisionNote: str(row[LEAVE_FIELD.decisionNote]),
  };
}

/** ERPNext departments are free text (`Production - MT`); ours are a closed set. */
function toDepartment(raw: string | undefined): Department {
  const head = (raw ?? '').split(' - ')[0]?.trim().toLowerCase();
  return DEPARTMENTS.find((d) => d.toLowerCase() === head) ?? 'Administration';
}

function toEmploymentType(raw: string | undefined): EmploymentType {
  const v = (raw ?? '').toLowerCase();
  if (v.includes('contract')) return 'contract';
  if (v.includes('apprentice') || v.includes('intern') || v.includes('trainee')) return 'apprentice';
  return 'permanent';
}

function toLeaveType(raw: string | undefined): LeaveType {
  const v = (raw ?? '').toLowerCase();
  if (v.includes('sick')) return 'sick';
  if (v.includes('earned') || v.includes('privilege')) return 'earned';
  if (v.includes('without pay') || v.includes('unpaid') || v.includes('loss of pay')) return 'unpaid';
  return 'casual';
}

// ===========================================================================
// THE API SURFACE
// ===========================================================================

/**
 * Everything the app can ask the backend for, grouped by area.
 *
 * Mirrors the `Api` class in the Flutter field-sales app, so the same mental
 * model works across both codebases.
 */
export const Api = {
  auth: {
    login,
    logout,
    restoreSession,
  },

  catalog: {
    listProducts,
    listCustomers,
    getCustomer,
    checkCredit,
  },

  notify: {
    emit,
    list: listNotifications,
    markRead: markNotificationRead,
    markAllRead: markAllNotificationsRead,
    acknowledge: acknowledgeNotification,
    unreadCount,
    pendingAcks,
  },

  stock: {
    listMinStock,
    listReservations,
    reserve: reserveStock,
    releaseDraftHolds,
    bindHoldsToOrder,
    consume: consumeStock,
    raiseReplenishment,
    listProductionOrders,
    recordReplenishment,
    belowThreshold,
    availableFor,
  },

  orders: {
    list: listOrders,
    get: getOrder,
    listForProduction,
    listAwaitingApproval,
    create: createOrder,
    updateItems: updateOrderItems,
    approve: approveOrder,
    reject: rejectOrder,
    setItemStage,
    changeDeliveryDate,
    acknowledgeChange,
    dispatch: dispatchOrder,
    bucketForGrouping,
    compileWeeklyGroup,
    listWeeklyGroups,
  },

  importer: {
    parseProducts,
    parseCustomers,
    commitProducts,
    commitCustomers,
    downloadTemplate,
  },

  hr: {
    listEmployees,
    listAttendance,
    markAttendance,
    listLeaveRequests,
    decideLeave,
  },
} as const;

export default Api;
