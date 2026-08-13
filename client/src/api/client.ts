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
  AttendanceLog,
  AttendanceRecord,
  AttendanceRegularization,
  FieldLeaveRequest,
  OrderDetail,
  OrderLine,
  LocationCheck,
  SalesCustomer,
  SalesLead,
  SalesRoute,
  SalesPerson,
  SalesVisit,
  TeamOrder,
  Trip,
  TripExpense,
  TripLeg,
  TripRates,
  AttendanceStatus,
  Customer,
  Department,
  Employee,
  EmploymentType,
  FulfilmentSource,
  LeaveRequest,
  LeaveStatus,
  LeaveType,
  CombinedOrder,
  ItemOption,
  LeadOrder,
  MinStockItem,
  MinStockLine,
  ProductionOrderRow,
  StockReservationRow,
  TripTrack,
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
import { normaliseWeights, orderTotal } from '@/domain/productRules';
import { parseTagged, RATE_FALLBACK } from '@/domain/trips';
import { allItemsReady, firstStage, isTerminalStage, stageLabel } from '@/domain/processStages';
import { availableQty, isBelowThreshold } from '@/domain/aging';
import { noteServerDate, serverNow } from '@/domain/serverClock';
import { rollUp } from '@/domain/production';
import { heldBy, holdPlan, trueReserved } from '@/domain/minimumStock';
import {
  discountFields,
  discountPercentOf,
  rateBeforeDiscount,
  discountRefusal,
  lineAfterDiscount,
  lineBeforeDiscount,
} from '@/domain/discount';
import {
  PRODUCTION_STATUS,
  PO_STATUS,
  LEAD_ORDER_STATUS,
  isSet as isLinkSet,
  orderSignedOff,
  rateEditable,
} from '@/domain/orderStatus';

import { USE_MOCK } from './config';
import {
  ATTENDANCE_FIELD,
  CUSTOMER_FIELD,
  DOCTYPE,
  EMPLOYEE_FIELD,
  ITEM_FIELD,
  ITEM_CATEGORIES,
  ITEM_CATEGORY_TO_LINE,
  LINE_CATEGORY_TO_ITEM,
  MIN_STOCK_FIELD,
  MIN_STOCK_BATCH_FIELD,
  FULFILMENT_MODE,
  RESERVATION_SOURCE,
  STOCK_RESERVATION_FIELD,
  LEAD_ORDER_FIELD,
  LEAD_ORDER_ITEM_FIELD,
  COMBINED_ORDER_FIELD,
  PROFORMA_STATUS,
  ATTENDANCE_LOG_FIELD,
  LEAVE_FIELD,
  LEAD_FIELD,
  SALES_CUSTOMER_FIELD,
  SALES_ROUTE_FIELD,
  SALES_ORDER_FIELD,
  SALES_ORDER_ITEM_FIELD,
  SALES_VISIT_FIELD,
  TRIP_EXPENSE_FIELD,
  TRIP_FIELD,
  TRIP_LEG_FIELD,
  TRIP_RATE_FIELD,
  LEAVE_REQUEST_FIELD,
  METHOD,
  REGULARIZATION_FIELD,
  SALES_PERSON_FIELD,
  OPTIONAL_EMPLOYEE_FIELD,
  USER_FIELD,
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

/*
 * Every response carries the server's clock in its `Date` header, so the
 * offset is learned from ordinary traffic rather than a dedicated request.
 * Read it on failures too: a 403 is as good a clock reading as a 200, and the
 * deadlines it feeds must not go stale just because a call went wrong.
 */
http.interceptors.response.use(
  (r) => {
    noteServerDate(r.headers?.date as string | undefined);
    return r;
  },
  (error: AxiosError) => {
    noteServerDate(error.response?.headers?.date as string | undefined);
    return Promise.reject(toApiError(error));
  },
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

    // 401 and 403 are different problems and sending the user to the login
    // screen for a 403 wastes their time: signing in again cannot grant a
    // permission their ERPNext account does not have.
    if (status === 401) {
      return new ApiError('Your session has expired. Please sign in again.', status, data);
    }
    if (status === 403) {
      return new ApiError(
        'Your ERPNext account does not have permission to read this. Ask an administrator to ' +
          'grant your user read access to it in Role Permissions Manager.',
        status,
        data,
      );
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

  try {
    const { data } = await http.get<{ data: T[] }>(resourceUrl(doctype), { params });
    return data.data ?? [];
  } catch (e) {
    /*
     * Frappe fails the *whole* query with a 417 if a single requested field
     * does not exist on the doctype. One absent custom field therefore reads
     * exactly like an empty table, which is how a populated Employee list can
     * render as "no data".
     *
     * So ask again for everything the user is allowed to read and let the
     * mappers pick out what is present — a field the site has not got simply
     * arrives undefined, which every `to*` mapper already tolerates. Only the
     * explicit-field form can hit this, so there is nothing to retry when the
     * caller did not name any.
     */
    const status = toApiError(e).status;
    if (status !== 417 || !options.fields?.length) throw e;

    const retry = { ...params, fields: JSON.stringify(['*']) };
    const { data } = await http.get<{ data: T[] }>(resourceUrl(doctype), { params: retry });
    if (import.meta.env.DEV) {
      console.warn(
        `[manna] ${doctype}: a requested field does not exist on this site, so the query was ` +
          `re-issued with fields=["*"]. Requested: ${options.fields.join(', ')}`,
      );
    }
    return data.data ?? [];
  }
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
/**
 * Is a Frappe flag switched on?
 *
 * A Check field arrives as `1`, but the same idea modelled as Data or Select
 * arrives as `"1"`, `"Yes"` or `"true"` — and a strict `=== 1` silently refuses
 * a user whose flag is plainly set. Anything falsy, `0`, `"0"` or `"No"` stays
 * off; nothing else is treated as permission.
 */
function isSet(value: unknown): boolean {
  if (value === 1 || value === true) return true;
  if (typeof value === 'string') {
    return ['1', 'yes', 'true', 'y'].includes(value.trim().toLowerCase());
  }
  return false;
}

/** Dev-only diagnostic: which `custom_*` fields this User actually carries. */
function describeRoleFlags(u: Record<string, unknown>): string {
  const flags = Object.keys(u)
    .filter((k) => k.startsWith('custom_'))
    .map((k) => `${k}=${JSON.stringify(u[k])}`);
  return flags.length
    ? `\n\n[dev] custom fields on this User: ${flags.join(', ')}`
    : '\n\n[dev] this User record carries no custom_* fields at all.';
}

async function fetchCurrentUser(): Promise<User> {
  const { data } = await http.get<{ message: string }>(METHOD.loggedUser);
  const email = data.message;

  const { data: doc } = await http.get<{
    data: Record<string, unknown> & {
      name: string;
      full_name?: string;
      custom_managed_team?: string;
      custom_production_company?: string;
    };
  }>(`/api/resource/User/${encodeURIComponent(email)}`);

  const u = doc.data;

  // The rep identity, if this login has one. `is_group=0` excludes the
  // roll-up nodes in the Sales Person tree.
  const salesPersons = await listDocs<{
    name: string;
    custom_company?: string;
    custom_team_manager?: string;
  }>(
    DOCTYPE.salesPerson,
    {
      fields: ['name', 'sales_person_name', 'custom_company', 'custom_team_manager'],
      filters: [
        ['is_group', '=', 0],
        ['custom_user', '=', email],
      ],
      limit: 1,
    },
  ).catch(() => []);

  const salesPerson = salesPersons[0]?.name;
  const managedTeam = String(u[USER_FIELD.managedTeam] ?? '').trim();

  /*
   * A sales manager is recognised from their own Sales Person record.
   *
   * `User.custom_managed_team` is documented but does not exist here. Team
   * membership lives on `Sales Person.custom_team_manager`, which holds a
   * SHORT token — `Pareeth` — while the manager's record is named
   * `Pareeth Kb`. So the test is whether their own name begins with their own
   * token; a rep's never does. Matching the token against the full name finds
   * no reports and locks the manager out, which is exactly what happened.
   */
  const myToken = (salesPersons[0]?.custom_team_manager ?? '').trim().toLowerCase();
  const managesTeam =
    Boolean(myToken) && (salesPerson ?? '').trim().toLowerCase().startsWith(myToken);

  let role: Role | null = null;
  // The GM outranks the rest: they are who the other roles escalate to, and
  // they carry exemptions nobody else does.
  if (isSet(u[USER_FIELD.isGeneralManager])) role = 'general_manager';
  else if (isSet(u[USER_FIELD.isHr])) role = 'hr';
  else if (isSet(u[USER_FIELD.isStockManager])) role = 'stock_manager';
  else if (isSet(u[USER_FIELD.isProductionManager])) role = 'production_manager';
  else if (managedTeam || managesTeam) role = 'sales_manager';

  if (!role) {
    // Nothing is guessed here on purpose: admitting an unrecognised login into
    // some default role is the one mistake with real consequences — a rep on
    // the production board, or in the approval queue.
    //
    // But a refusal that cannot be diagnosed is its own problem, so in dev the
    // message names the `custom_*` fields the User record actually carries.
    // That is schema, not data, and it never ships to production.
    throw new Error(
      (salesPerson
        ? 'Sales Reps work in the field-sales app. This login has no access to the Sales & Production module.'
        : 'This login has no role in the Sales & Production module. Contact the Sales Manager.') +
        (import.meta.env.DEV ? describeRoleFlags(u) : ''),
    );
  }

  return {
    id: u.name,
    name: u.full_name || email,
    email,
    role,
    salesPerson,
    productionUnit:
      (u[USER_FIELD.productionCompany] as string | undefined) || salesPersons[0]?.custom_company,
    /*
     * Kept even when `role` came out as something else. Renjith is flagged a
     * production manager and also manages the UAE sales team; the flag wins the
     * role, so without this he would have no route to his own reps.
     */
    managedTeam: managedTeam || (managesTeam ? myToken : undefined),
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
        ITEM_FIELD.weightPerBelt,
        ITEM_FIELD.beltsPerRoll,
        ITEM_FIELD.weightPerRoll,
        ITEM_FIELD.packLitres,
      ],
      filters: [
        ['disabled', '=', 0],
        // The Item master spells these `Precured`/`HOT`/…, not `PCTR`/`CTR`/….
        // Filtering by the order-line codes matched nothing and returned an
        // empty catalogue that read as a permissions failure.
        [ITEM_FIELD.category, 'in', ITEM_CATEGORIES as unknown as string[]],
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
  // Vulcanising solution ships in 10 L and 30 L tins; `custom_pack_litres` is
  // where the site records which. There is no `custom_tin_size` field.
  const tin = n(ITEM_FIELD.packLitres);
  // The one place the `custom_avg_weight_per_roll` misnomer is unpicked: it is
  // a per-belt figure, and whichever of the three weights the master omits is
  // derived from the other two.
  const weights = normaliseWeights({
    weightPerBelt: n(ITEM_FIELD.weightPerBelt),
    beltsPerRoll: n(ITEM_FIELD.beltsPerRoll),
    weightPerRoll: n(ITEM_FIELD.weightPerRoll),
  });
  const raw = String(row[ITEM_FIELD.category] ?? '');
  return {
    code: String(row.name),
    name: String(row.item_name ?? row.name),
    // Translated from the Item vocabulary; a value already in the order-line
    // vocabulary (the inferred fallback path) passes through unchanged.
    category: (ITEM_CATEGORY_TO_LINE[raw as keyof typeof ITEM_CATEGORY_TO_LINE] ??
      raw ??
      'PCTR') as ProductCategory,
    ...weights,
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
    // Needed by the route gate: an order cannot be started without one.
    SALES_CUSTOMER_FIELD.route,
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
      fields: ['name', 'customer_name', 'territory', CUSTOMER_FIELD.outstanding, CUSTOMER_FIELD.creditLimit, CUSTOMER_FIELD.assignedReps, SALES_CUSTOMER_FIELD.route],
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
    /*
     * Deliberately NOT falling back to `destination` or `territory`. An order
     * cannot be started without a route, and substituting a plausible-looking
     * value would let 258 routeless customers be ordered for and then found
     * undeliverable.
     */
    route: str(row[SALES_CUSTOMER_FIELD.route]),
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
    listDocs<MinStockItem>(DOCTYPE.minStock, { limit: 0 }).catch(ifMissing([], DOCTYPE.minStock)),
    listDocs<StockReservation>(DOCTYPE.stockReservation, { limit: 0 }).catch(ifMissing([], DOCTYPE.stockReservation)),
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
function ifMissing<T>(fallback: T, what = 'a doctype') {
  return (e: unknown): T => {
    const err = toApiError(e);
    if (err.status === 404 || err.status === 417) {
      // Silent in production — an unbuilt doctype is an expected state there.
      // Loud in dev, because "empty list" and "this does not exist" look
      // identical on screen and that has already cost an afternoon.
      if (import.meta.env.DEV) {
        console.warn(
          `[manna] ${what} is missing on this site (HTTP ${err.status}) — rendering as empty. ` +
            `${err.message}`,
        );
      }
      return fallback;
    }
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
  return listDocs<StockReservation>(DOCTYPE.stockReservation, { limit: 0 }).catch(ifMissing([], DOCTYPE.stockReservation));
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
  }).catch(ifMissing([], DOCTYPE.productionOrder));
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
  }).catch(ifMissing([], DOCTYPE.weeklyGroup));
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
  // The sheets carry the same misnomer as ERPNext: an "avg weight per roll"
  // column holds the weight of one *belt*. See `Product.weightPerBelt`.
  weightPerBelt: ['avg weight per roll', 'average weight', 'avg roll weight', 'avg weight', 'average weight per roll', 'weight per belt', 'belt weight'],
  beltsPerRoll: ['belts per roll', 'belts/roll', 'no of belts', 'belts'],
  weightPerRoll: ['weight per roll', 'roll weight', 'exact weight per roll', 'exact weight', 'total roll weight'],
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
        const w = normaliseWeights({
          weightPerBelt: numOrUndef(get('weightPerBelt')),
          beltsPerRoll: numOrUndef(get('beltsPerRoll')),
          weightPerRoll: numOrUndef(get('weightPerRoll')),
        });
        Object.assign(product, w);
        if (!w.beltsPerRoll) push('Belts Per Roll', 'PCTR needs the number of belts per roll.');
        if (!w.weightPerBelt) {
          push(
            'Avg Weight Per Roll',
            'PCTR needs the per-belt weight in kg — the "Avg Weight Per Roll" column holds the weight of one belt, not one roll.',
          );
        }
        break;
      }
      case 'CTR': {
        // A conventional roll yields no belts, so the misnamed column cannot
        // mean anything but the roll itself here.
        product.weightPerRoll =
          numOrUndef(get('weightPerRoll')) ?? numOrUndef(get('weightPerBelt'));
        if (!product.weightPerRoll) push('Weight Per Roll', 'CTR needs an exact roll weight in kg.');
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
      route: str(get('route')),
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
      // Back into the Item master's own vocabulary. `custom_product_category`
      // is a Select there and rejects `PCTR`/`CTR`/`BG`/`VS` outright.
      [ITEM_FIELD.category]: LINE_CATEGORY_TO_ITEM[p.category],
      // Written back under ERPNext's names, misnomer and all: the site keeps
      // the per-belt figure in `custom_avg_weight_per_roll`, and writing a roll
      // weight there would corrupt the master for every other reader.
      [ITEM_FIELD.weightPerBelt]: p.weightPerBelt,
      [ITEM_FIELD.beltsPerRoll]: p.beltsPerRoll,
      [ITEM_FIELD.weightPerRoll]: p.weightPerRoll,
      [ITEM_FIELD.packLitres]: p.tinSize,
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

// ===========================================================================
// FIELD ATTENDANCE — the real HR doctypes on this site
// ===========================================================================
//
// `Sales Person` + `Attendance Log` + `Leave Request` + `Attendance
// Regularization`. See `domain/attendance.ts` for why these and not the
// Frappe HR ones, which are not installed.
//
// Read-only for now. Approvals live in the PWA rather than here because a
// decision has to be attributable to the signed-in user, and this module is
// the only place that knows who that is.

async function listSalesPeople(): Promise<SalesPerson[]> {
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.salesPerson, {
    fields: ['name', ...Object.values(SALES_PERSON_FIELD)],
    orderBy: `${SALES_PERSON_FIELD.personName} asc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.salesPerson));

  return rows.map((r) => ({
    id: String(r.name),
    name: str(r[SALES_PERSON_FIELD.personName]) ?? String(r.name),
    teamManager: str(r[SALES_PERSON_FIELD.teamManager]) ?? '',
    unit: str(r[SALES_PERSON_FIELD.unit]) ?? '',
    userId: str(r[SALES_PERSON_FIELD.user]),
    enabled: Number(r[SALES_PERSON_FIELD.enabled]) === 1,
    isGroup: Number(r[SALES_PERSON_FIELD.isGroup]) === 1,
  }));
}

/** Punch records from `fromIso` onward. The calendar needs months, not days. */
async function listAttendanceLogs(fromIso: string): Promise<AttendanceLog[]> {
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.attendanceLog, {
    fields: ['name', ...Object.values(ATTENDANCE_LOG_FIELD)],
    filters: [[ATTENDANCE_LOG_FIELD.date, '>=', fromIso]],
    orderBy: `${ATTENDANCE_LOG_FIELD.date} desc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.attendanceLog));

  return rows.map((r) => ({
    id: String(r.name),
    person: str(r[ATTENDANCE_LOG_FIELD.person]) ?? '',
    date: (str(r[ATTENDANCE_LOG_FIELD.date]) ?? '').slice(0, 10),
    punchIn: str(r[ATTENDANCE_LOG_FIELD.punchIn]),
    punchOut: str(r[ATTENDANCE_LOG_FIELD.punchOut]),
    status: (str(r[ATTENDANCE_LOG_FIELD.status]) as AttendanceLog['status']) ?? 'Punched In',
    workingHours: Number(r[ATTENDANCE_LOG_FIELD.workingHours]) || 0,
    remarks: str(r[ATTENDANCE_LOG_FIELD.remarks]),
  }));
}

async function listLeaveRequestsLive(): Promise<FieldLeaveRequest[]> {
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.leaveRequest, {
    fields: ['name', ...Object.values(LEAVE_REQUEST_FIELD)],
    orderBy: `${LEAVE_REQUEST_FIELD.date} desc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.leaveRequest));

  return rows.map(toFieldLeaveRequest);
}

function toFieldLeaveRequest(r: Record<string, unknown>): FieldLeaveRequest {
  return ({
    id: String(r.name),
    person: str(r[LEAVE_REQUEST_FIELD.person]) ?? '',
    date: (str(r[LEAVE_REQUEST_FIELD.date]) ?? '').slice(0, 10),
    days: Number(r[LEAVE_REQUEST_FIELD.days]) || 1,
    halfDay: Number(r[LEAVE_REQUEST_FIELD.halfDay]) === 1,
    halfDayPeriod: str(r[LEAVE_REQUEST_FIELD.halfDayPeriod]) as FieldLeaveRequest['halfDayPeriod'],
    reason: str(r[LEAVE_REQUEST_FIELD.reason]),
    status: (str(r[LEAVE_REQUEST_FIELD.status]) as FieldLeaveRequest['status']) ?? 'Pending Approval',
    approverType:
      (str(r[LEAVE_REQUEST_FIELD.approverType]) as FieldLeaveRequest['approverType']) ?? 'Sales Manager',
    teamManager: str(r[LEAVE_REQUEST_FIELD.teamManager]),
    requesterIsManager: Number(r[LEAVE_REQUEST_FIELD.requesterIsManager]) === 1,
    decidedBy: str(r[LEAVE_REQUEST_FIELD.decidedBy]),
    managerApproved: Number(r[LEAVE_REQUEST_FIELD.managerApproved]) === 1,
    managerApprovedBy: str(r[LEAVE_REQUEST_FIELD.managerApprovedBy]),
    hrApproved: Number(r[LEAVE_REQUEST_FIELD.hrApproved]) === 1,
    hrApprovedBy: str(r[LEAVE_REQUEST_FIELD.hrApprovedBy]),
  });
}

/**
 * Record one party's decision on a leave request.
 *
 * The two approvals are independent, so this only ever writes the caller's own
 * flag. `status` is promoted to `Approved` solely when BOTH are set — the read
 * is done first so the other party's flag is the current one, not whatever the
 * screen last saw.
 *
 * A rejection is final from either side and does not wait for the other.
 */
async function decideLeaveRequest(input: {
  id: string;
  as: 'hr' | 'manager';
  approve: boolean;
  by: string;
}): Promise<FieldLeaveRequest> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.leaveRequest, input.id);

  if (!input.approve) {
    const rejected = await updateDoc<Record<string, unknown>>(DOCTYPE.leaveRequest, input.id, {
      [LEAVE_REQUEST_FIELD.status]: 'Rejected',
      [LEAVE_REQUEST_FIELD.decidedBy]: input.by,
    });
    return toFieldLeaveRequest(rejected);
  }

  /*
   * The other party's approval may have been made outside this dashboard, in
   * which case only `status`/`approver_type` record it — see
   * `managerHasApproved` in `domain/approvals`. Reading the raw flag alone
   * would drop an approval that already exists and re-open a granted leave.
   */
  const legacyApproved = str(doc[LEAVE_REQUEST_FIELD.status]) === 'Approved';
  const approverType = str(doc[LEAVE_REQUEST_FIELD.approverType]);
  const managerApproved =
    input.as === 'manager'
      ? true
      : Number(doc[LEAVE_REQUEST_FIELD.managerApproved]) === 1 ||
        (legacyApproved && approverType === 'Sales Manager');
  const hrApproved =
    input.as === 'hr'
      ? true
      : Number(doc[LEAVE_REQUEST_FIELD.hrApproved]) === 1 ||
        (legacyApproved && approverType === 'HR');

  // A manager's own leave needs HR alone — there is no second signature to
  // wait for, and requiring one would leave it permanently ungranted.
  const requesterIsManager = Number(doc[LEAVE_REQUEST_FIELD.requesterIsManager]) === 1;
  const complete = requesterIsManager ? hrApproved : managerApproved && hrApproved;

  const patch: Record<string, unknown> = {
    [LEAVE_REQUEST_FIELD.managerApproved]: managerApproved ? 1 : 0,
    [LEAVE_REQUEST_FIELD.hrApproved]: hrApproved ? 1 : 0,
    [LEAVE_REQUEST_FIELD.status]: complete ? 'Approved' : 'Pending Approval',
  };
  if (input.as === 'manager') patch[LEAVE_REQUEST_FIELD.managerApprovedBy] = input.by;
  if (input.as === 'hr') patch[LEAVE_REQUEST_FIELD.hrApprovedBy] = input.by;
  if (complete) patch[LEAVE_REQUEST_FIELD.decidedBy] = input.by;

  const saved = await updateDoc<Record<string, unknown>>(DOCTYPE.leaveRequest, input.id, patch);
  return toFieldLeaveRequest(saved);
}

/**
 * Take back this party's decision on a leave request.
 *
 * Clears only the caller's own flag — the other party's approval is theirs to
 * withdraw, not ours — and drops the request back to pending, since it is by
 * definition no longer fully approved. A revoked rejection returns to pending
 * too, so it can be decided again rather than staying dead.
 */
async function revokeLeaveDecision(input: {
  id: string;
  as: 'hr' | 'manager';
}): Promise<FieldLeaveRequest> {
  const patch: Record<string, unknown> = {
    [LEAVE_REQUEST_FIELD.status]: 'Pending Approval',
    [LEAVE_REQUEST_FIELD.decidedBy]: '',
  };
  if (input.as === 'manager') {
    patch[LEAVE_REQUEST_FIELD.managerApproved] = 0;
    patch[LEAVE_REQUEST_FIELD.managerApprovedBy] = '';
  } else {
    patch[LEAVE_REQUEST_FIELD.hrApproved] = 0;
    patch[LEAVE_REQUEST_FIELD.hrApprovedBy] = '';
  }
  const saved = await updateDoc<Record<string, unknown>>(DOCTYPE.leaveRequest, input.id, patch);
  return toFieldLeaveRequest(saved);
}

/**
 * Take back a regularization decision.
 *
 * `completion_status` is deliberately left alone: if the attendance log was
 * already rewritten, un-approving does not un-rewrite it, and silently
 * clearing the flag would hide that the log and the request now disagree.
 */
async function revokeRegularization(input: {
  id: string;
  by: string;
  remarks?: string;
}): Promise<AttendanceRegularization> {
  const saved = await updateDoc<Record<string, unknown>>(
    DOCTYPE.attendanceRegularization,
    input.id,
    {
      [REGULARIZATION_FIELD.status]: 'Pending Approval',
      [REGULARIZATION_FIELD.decidedBy]: '',
      [REGULARIZATION_FIELD.decisionRemarks]:
        input.remarks ?? `Decision revoked by ${input.by}`,
    },
  );
  return toRegularization(saved);
}

/** Whole hours between two Frappe timestamps, to 2dp. Never negative. */
function hoursBetween(from?: string, to?: string): number {
  if (!from || !to) return 0;
  const a = new Date(from.replace(' ', 'T')).getTime();
  const b = new Date(to.replace(' ', 'T')).getTime();
  if (Number.isNaN(a) || Number.isNaN(b) || b <= a) return 0;
  return Math.round(((b - a) / 3_600_000) * 100) / 100;
}

/** "2026-08-05" + "09:30" -> "2026-08-05 09:30:00". */
export function stampFor(dateIso: string, hhmm: string): string {
  return `${dateIso} ${hhmm.length === 5 ? `${hhmm}:00` : hhmm}`;
}

export interface AttendanceEdit {
  person: string;
  date: string;
  /** Full timestamps. Omit both to leave the day with no punches. */
  punchIn?: string;
  punchOut?: string;
  remarks?: string;
}

/**
 * Write one person's attendance for one day, creating the record if needed.
 *
 * `working_hours` is always recomputed here rather than trusted from the
 * caller: it is what payroll multiplies, and letting a screen supply it would
 * make two places responsible for the same number. A day with a punch-in and
 * no punch-out stays `Punched In` with zero hours — an open shift is a real
 * state, not a zero-length one.
 */
async function upsertAttendanceLog(edit: AttendanceEdit): Promise<AttendanceLog> {
  const existing = await listDocs<{ name: string }>(DOCTYPE.attendanceLog, {
    fields: ['name'],
    filters: [
      [ATTENDANCE_LOG_FIELD.person, '=', edit.person],
      [ATTENDANCE_LOG_FIELD.date, '=', edit.date],
    ],
    limit: 1,
  }).catch(() => []);

  const closed = Boolean(edit.punchIn && edit.punchOut);
  const body: Record<string, unknown> = {
    [ATTENDANCE_LOG_FIELD.person]: edit.person,
    [ATTENDANCE_LOG_FIELD.date]: edit.date,
    [ATTENDANCE_LOG_FIELD.punchIn]: edit.punchIn ?? null,
    [ATTENDANCE_LOG_FIELD.punchOut]: edit.punchOut ?? null,
    [ATTENDANCE_LOG_FIELD.status]: closed ? 'Punched Out' : 'Punched In',
    [ATTENDANCE_LOG_FIELD.workingHours]: hoursBetween(edit.punchIn, edit.punchOut),
  };
  if (edit.remarks != null) body[ATTENDANCE_LOG_FIELD.remarks] = edit.remarks;

  const saved = existing.length
    ? await updateDoc<Record<string, unknown>>(DOCTYPE.attendanceLog, existing[0]!.name, body)
    : await createDoc<Record<string, unknown>>(DOCTYPE.attendanceLog, body);

  return toAttendanceLog(saved);
}

function toAttendanceLog(r: Record<string, unknown>): AttendanceLog {
  return {
    id: String(r.name),
    person: str(r[ATTENDANCE_LOG_FIELD.person]) ?? '',
    date: (str(r[ATTENDANCE_LOG_FIELD.date]) ?? '').slice(0, 10),
    punchIn: str(r[ATTENDANCE_LOG_FIELD.punchIn]),
    punchOut: str(r[ATTENDANCE_LOG_FIELD.punchOut]),
    status: (str(r[ATTENDANCE_LOG_FIELD.status]) as AttendanceLog['status']) ?? 'Punched In',
    workingHours: Number(r[ATTENDANCE_LOG_FIELD.workingHours]) || 0,
    remarks: str(r[ATTENDANCE_LOG_FIELD.remarks]),
  };
}

/**
 * Write an approved regularization into the attendance log.
 *
 * This is the step that used to be done by hand, and the reason twelve
 * approved corrections are sitting with the hours never moved. The remark
 * follows the wording already in the data so a rewritten day is recognisable
 * either from here or from Desk.
 *
 * `completion_status` is set only after the log write succeeds. If it fails,
 * the regularization stays `Approved` / `Not Completed` — which is exactly the
 * state the dashboard already surfaces, so a failure is visible rather than
 * silently swallowed.
 */
async function applyRegularization(input: {
  id: string;
  person: string;
  date: string;
  punchIn?: string;
  punchOut?: string;
}): Promise<{ created: boolean }> {
  const existing = await listDocs<{ name: string }>(DOCTYPE.attendanceLog, {
    fields: ['name'],
    filters: [
      [ATTENDANCE_LOG_FIELD.person, '=', input.person],
      [ATTENDANCE_LOG_FIELD.date, '=', input.date],
    ],
    limit: 1,
  }).catch(() => []);

  const created = existing.length === 0;
  await upsertAttendanceLog({
    person: input.person,
    date: input.date,
    punchIn: input.punchIn,
    punchOut: input.punchOut,
    remarks: created
      ? `Created per ${input.id} (approved) - no punch was recorded on this date`
      : `Regularized as per ${input.id} (approved)`,
  });

  await updateDoc(DOCTYPE.attendanceRegularization, input.id, {
    [REGULARIZATION_FIELD.completionStatus]: 'Completed',
  });

  return { created };
}

/** Decide a regularization. Routing lives in `domain/approvals`. */
async function decideRegularization(input: {
  id: string;
  approve: boolean;
  by: string;
  remarks?: string;
  /** Skip the attendance write — for the rare correction-only decision. */
  applyToLog?: boolean;
}): Promise<AttendanceRegularization> {
  const saved = await updateDoc<Record<string, unknown>>(
    DOCTYPE.attendanceRegularization,
    input.id,
    {
      [REGULARIZATION_FIELD.status]: input.approve ? 'Approved' : 'Rejected',
      [REGULARIZATION_FIELD.decidedBy]: input.by,
      ...(input.remarks ? { [REGULARIZATION_FIELD.decisionRemarks]: input.remarks } : {}),
    },
  );
  const ar = toRegularization(saved);

  /*
   * Approving and applying are one event now. They were two, and that is why
   * twelve approved corrections sat with the hours never moved — a manual
   * second step is a step that gets forgotten.
   */
  if (input.approve && input.applyToLog !== false) {
    await applyRegularization({
      id: ar.id,
      person: ar.person,
      date: ar.date,
      punchIn: ar.requestedPunchIn,
      punchOut: ar.requestedPunchOut,
    });
    return { ...ar, completionStatus: 'Completed' };
  }
  return ar;
}

async function listRegularizations(): Promise<AttendanceRegularization[]> {
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.attendanceRegularization, {
    fields: ['name', ...Object.values(REGULARIZATION_FIELD)],
    orderBy: 'creation desc',
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.attendanceRegularization));

  return rows.map(toRegularization);
}

function toRegularization(r: Record<string, unknown>): AttendanceRegularization {
  return ({
    id: String(r.name),
    person: str(r[REGULARIZATION_FIELD.person]) ?? '',
    date: (str(r[REGULARIZATION_FIELD.date]) ?? '').slice(0, 10),
    requestedPunchIn: str(r[REGULARIZATION_FIELD.requestedPunchIn]),
    requestedPunchOut: str(r[REGULARIZATION_FIELD.requestedPunchOut]),
    reason: str(r[REGULARIZATION_FIELD.reason]),
    status:
      (str(r[REGULARIZATION_FIELD.status]) as AttendanceRegularization['status']) ??
      'Pending Approval',
    approverType:
      (str(r[REGULARIZATION_FIELD.approverType]) as AttendanceRegularization['approverType']) ??
      'Sales Manager',
    teamManager: str(r[REGULARIZATION_FIELD.teamManager]),
    requesterIsManager: Number(r[REGULARIZATION_FIELD.requesterIsManager]) === 1,
    decidedBy: str(r[REGULARIZATION_FIELD.decidedBy]),
    decisionRemarks: str(r[REGULARIZATION_FIELD.decisionRemarks]),
    // An empty completion field means nobody has applied it, which is the
    // same operational state as an explicit "Not Completed".
    completionStatus:
      str(r[REGULARIZATION_FIELD.completionStatus]) === 'Completed' ? 'Completed' : 'Not Completed',
  });
}

// ===========================================================================
// CUSTOMERS AND TEAM ORDERS
// ===========================================================================

/**
 * Every customer, or only those assigned to the given reps.
 *
 * `custom_assigned_reps` is a Link field holding a bare Sales Person name, so
 * the filter is an `in` on exact names. It was once pipe-wrapped free text
 * matched with LIKE; that changed, and a LIKE here silently returns nothing.
 */
async function listSalesCustomers(reps?: string[]): Promise<SalesCustomer[]> {
  const filters: Filter[] = [];
  if (reps && reps.length) filters.push([SALES_CUSTOMER_FIELD.assignedRep, 'in', reps]);

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.customer, {
    fields: ['name', ...Object.values(SALES_CUSTOMER_FIELD)],
    filters,
    orderBy: `${SALES_CUSTOMER_FIELD.customerName} asc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.customer));

  return rows.map((r) => ({
    id: String(r.name),
    name: str(r[SALES_CUSTOMER_FIELD.customerName]) ?? String(r.name),
    assignedRep: str(r[SALES_CUSTOMER_FIELD.assignedRep]),
    route: str(r[SALES_CUSTOMER_FIELD.route]),
    gstin: str(r[SALES_CUSTOMER_FIELD.gstin]),
    creditLimit: Number(r[SALES_CUSTOMER_FIELD.creditLimit]) || 0,
    outstanding: Number(r[SALES_CUSTOMER_FIELD.outstanding]) || 0,
    locationStatus: str(r[SALES_CUSTOMER_FIELD.locationStatus]) as SalesCustomer['locationStatus'],
    latitude: Number(r[SALES_CUSTOMER_FIELD.latitude]) || 0,
    longitude: Number(r[SALES_CUSTOMER_FIELD.longitude]) || 0,
    capturedBy: str(r[SALES_CUSTOMER_FIELD.capturedBy]),
    bannerPhoto: str(r[SALES_CUSTOMER_FIELD.bannerPhoto]),
  }));
}

/** Leads, optionally narrowed to a set of reps. */
async function listLeads(reps?: string[]): Promise<SalesLead[]> {
  const filters: Filter[] = [];
  if (reps && reps.length) filters.push([LEAD_FIELD.rep, 'in', reps]);

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.lead, {
    fields: ['name', ...Object.values(LEAD_FIELD)],
    filters,
    orderBy: 'modified desc',
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.lead));

  return rows.map((r) => ({
    id: String(r.name),
    name: str(r[LEAD_FIELD.leadName]) ?? str(r[LEAD_FIELD.companyName]) ?? String(r.name),
    companyName: str(r[LEAD_FIELD.companyName]),
    rep: str(r[LEAD_FIELD.rep]),
    route: str(r[LEAD_FIELD.route]),
    gstin: str(r[LEAD_FIELD.gstin]),
    address: str(r[LEAD_FIELD.address]),
    city: str(r[LEAD_FIELD.city]),
    mobile: str(r[LEAD_FIELD.mobile]),
    shopType: str(r[LEAD_FIELD.shopType]),
    status: str(r[LEAD_FIELD.status]),
    customer: str(r[LEAD_FIELD.customer]),
    locationStatus: str(r[LEAD_FIELD.locationStatus]) as SalesLead['locationStatus'],
    capturedBy: str(r[LEAD_FIELD.capturedBy]),
    latitude: Number(r[LEAD_FIELD.latitude]) || 0,
    longitude: Number(r[LEAD_FIELD.longitude]) || 0,
    bannerPhoto: str(r[LEAD_FIELD.bannerPhoto]),
  }));
}

/**
 * Routes belonging to one rep.
 *
 * Routes are named `<Rep> - <Place>` and owned by a rep, so a customer of
 * Prashanth's can only sensibly be put on one of Prashanth's runs. Offering
 * the whole list of 98 would invite exactly the wrong choice.
 */
async function listRoutesFor(rep?: string): Promise<SalesRoute[]> {
  const filters: Filter[] = [[SALES_ROUTE_FIELD.isActive, '=', 1]];
  if (rep) filters.push([SALES_ROUTE_FIELD.rep, '=', rep]);

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.salesRoute, {
    fields: ['name', ...Object.values(SALES_ROUTE_FIELD)],
    filters,
    orderBy: `${SALES_ROUTE_FIELD.routeName} asc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.salesRoute));

  return rows.map((r) => ({
    id: String(r.name),
    name: str(r[SALES_ROUTE_FIELD.routeName]) ?? String(r.name),
    rep: str(r[SALES_ROUTE_FIELD.rep]),
    isActive: Number(r[SALES_ROUTE_FIELD.isActive]) === 1,
  }));
}

/** Put a customer or a lead on a route. */
async function assignRoute(input: {
  kind: 'customer' | 'lead';
  id: string;
  route: string;
}): Promise<void> {
  const doctype = input.kind === 'customer' ? DOCTYPE.customer : DOCTYPE.lead;
  const field = input.kind === 'customer' ? SALES_CUSTOMER_FIELD.route : LEAD_FIELD.route;
  await updateDoc(doctype, input.id, { [field]: input.route });
}

/**
 * Decide a captured location.
 *
 * Approving copies the captured coordinates into the **verified** fields —
 * those are what the 100 m punch-in check runs against, so a location that is
 * approved but not copied verifies nobody. Rejecting returns it to
 * `Not Captured` so the rep is asked to capture it again, rather than leaving
 * a rejected reading that looks like a location.
 */
async function decideLocation(input: {
  kind: 'customer' | 'lead' | 'site';
  id: string;
  approve: boolean;
  latitude: number;
  longitude: number;
}): Promise<void> {
  /*
   * All three carry the same `custom_location_*` field names — the Site
   * doctype was built to match Customer and Lead — so the only thing that
   * varies is which doctype to write to.
   */
  const doctype =
    input.kind === 'customer'
      ? DOCTYPE.customer
      : input.kind === 'lead'
        ? DOCTYPE.lead
        : DOCTYPE.customerSite;
  const f = input.kind === 'customer' ? SALES_CUSTOMER_FIELD : LEAD_FIELD;

  const body: Record<string, unknown> = input.approve
    ? {
        [f.locationStatus]: 'Verified',
        [f.verifiedLatitude]: input.latitude,
        [f.verifiedLongitude]: input.longitude,
      }
    : { [f.locationStatus]: 'Not Captured' };

  await updateDoc(doctype, input.id, body);
}

/** Everything waiting on a location decision, customers and leads together. */
async function listLocationQueue(reps?: string[]): Promise<LocationCheck[]> {
  const [customers, leads, sites] = await Promise.all([
    listSalesCustomers(reps),
    listLeads(reps),
    /*
     * `Customer Site` has no rows yet and only one custom field is declared on
     * it, so its remaining field names are unverified. Read with `*` rather
     * than a named list: an unknown field answers 417 and would take the whole
     * queue down with it, losing the customers and leads too.
     */
    listDocs<Record<string, unknown>>(DOCTYPE.customerSite, { fields: ['*'], limit: 0 }).catch(
      () => [] as Record<string, unknown>[],
    ),
  ]);

  const out: LocationCheck[] = [];
  for (const c of customers) {
    if (c.locationStatus !== 'Pending Verification') continue;
    out.push({
      kind: 'customer',
      id: c.id,
      name: c.name,
      rep: c.assignedRep,
      route: c.route,
      capturedBy: c.capturedBy,
      latitude: c.latitude,
      longitude: c.longitude,
      bannerPhoto: c.bannerPhoto,
      gstin: c.gstin,
    });
  }
  for (const l of leads) {
    if (l.locationStatus !== 'Pending Verification') continue;
    out.push({
      kind: 'lead',
      id: l.id,
      name: l.name,
      /*
       * Only when it differs from the name. On the live master they are
       * usually identical — "Janatha Tyres" in both — and printing the same
       * words twice on a card teaches the reader to skip the line.
       */
      companyName: l.companyName && l.companyName !== l.name ? l.companyName : undefined,
      rep: l.rep,
      route: l.route,
      capturedBy: l.capturedBy,
      latitude: l.latitude,
      longitude: l.longitude,
      bannerPhoto: l.bannerPhoto,
      address: l.address,
      city: l.city,
      mobile: l.mobile,
      shopType: l.shopType,
      gstin: l.gstin,
      status: l.status,
    });
  }

  /*
   * Sites join the same queue rather than having their own screen.
   *
   * A site is somebody asserting new premises exist, which is the same
   * judgement as a shopfront: does this photograph show the place the record
   * claims? Two screens asking one question means the smaller queue is the one
   * nobody remembers to open.
   */
  for (const s of sites) {
    const status = str(s.custom_location_status) ?? str(s.location_status);
    if (status !== 'Pending Verification') continue;
    const owningRep = str(s.custom_sales_person) ?? str(s.sales_person);
    if (reps && reps.length && owningRep && !reps.includes(owningRep)) continue;
    // The owner is the customer if set, otherwise the lead. Heading a card with
    // a blank tells the manager nothing about what they are approving.
    const owner = str(s.customer) ?? str(s.lead);
    const siteName = str(s.site_name) ?? str(s.title) ?? String(s.name);
    out.push({
      kind: 'site',
      id: String(s.name),
      name: owner ? `${siteName} — ${owner}` : siteName,
      rep: owningRep,
      capturedBy: str(s.custom_location_captured_by) ?? owningRep,
      route: str(s.route) ?? str(s.custom_sales_route),
      latitude: Number(s.custom_latitude ?? s.latitude) || 0,
      longitude: Number(s.custom_longitude ?? s.longitude) || 0,
      bannerPhoto: str(s.custom_banner_photo) ?? str(s.banner_photo),
      address: str(s.custom_address) ?? str(s.address),
    });
  }

  /*
   * The shop photo is usually an ATTACHMENT, not a field.
   *
   * The field-sales app uploads it as a File against the Lead or Customer and
   * leaves `custom_banner_photo` empty — CRM-LEAD-2026-04116 is the proof: the
   * field is null and `lead_bannereedd65.jpg` is attached in the same second
   * the lead was created. The records that *do* carry the field are legacy
   * imports from salesfokuz, a different system.
   *
   * Read the field alone and every recent capture looks photo-less, which is
   * exactly the queue a manager most needs to see.
   *
   * The attachment wins where both exist: a re-captured shop gets a new
   * attachment while the stale legacy field stays put, and showing the old
   * photo for a re-shot place is the failure that actually misleads.
   */
  const ids = out.map((o) => o.id);
  if (ids.length) {
    const files = await listDocs<Record<string, unknown>>(DOCTYPE.file, {
      fields: ['name', 'file_url', 'attached_to_name', 'attached_to_doctype', 'creation'],
      filters: [['attached_to_name', 'in', ids]],
      orderBy: 'creation desc',
      limit: 0,
    }).catch(() => [] as Record<string, unknown>[]);

    // `creation desc` means the first one seen per record is the newest.
    const newest = new Map<string, string>();
    for (const f of files) {
      const owner = str(f.attached_to_name);
      const url = str(f.file_url);
      if (!owner || !url || newest.has(owner)) continue;
      newest.set(owner, url);
    }
    for (const o of out) {
      const attached = newest.get(o.id);
      if (attached) o.bannerPhoto = attached;
    }
  }

  return out;
}

/** Orders raised by a set of reps. No reps means every order. */
async function listTeamOrders(reps?: string[]): Promise<TeamOrder[]> {
  const filters: Filter[] = [];
  if (reps && reps.length) filters.push([SALES_ORDER_FIELD.rep, 'in', reps]);

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.salesOrder, {
    fields: ['name', ...Object.values(SALES_ORDER_FIELD)],
    filters,
    orderBy: `${SALES_ORDER_FIELD.placedOn} desc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.salesOrder));

  return rows.map(toTeamOrder);
}

function toTeamOrder(r: Record<string, unknown>): TeamOrder {
  return {
    id: String(r.name),
    customer: str(r[SALES_ORDER_FIELD.customer]) ?? '',
    customerName: str(r[SALES_ORDER_FIELD.customerName]) ?? str(r[SALES_ORDER_FIELD.customer]) ?? '',
    rep: str(r[SALES_ORDER_FIELD.rep]) ?? '',
    unit: str(r[SALES_ORDER_FIELD.unit]),
    placedOn: (str(r[SALES_ORDER_FIELD.placedOn]) ?? '').slice(0, 10),
    deliveryDate: (str(r[SALES_ORDER_FIELD.deliveryDate]) ?? '').slice(0, 10) || undefined,
    total: Number(r[SALES_ORDER_FIELD.total]) || 0,
    poStatus: str(r[SALES_ORDER_FIELD.poStatus]) ?? '',
    productionStatus: str(r[SALES_ORDER_FIELD.productionStatus]),
    combinedOrder: str(r[SALES_ORDER_FIELD.combinedOrder]),
    ratesApproved: Number(r[SALES_ORDER_FIELD.ratesApproved]) === 1,
  };
}

/** One order with its lines, for the approval screen. */
async function getSalesOrder(id: string): Promise<OrderDetail> {
  return toOrderDetail(await getDoc<Record<string, unknown>>(DOCTYPE.salesOrder, id));
}

/**
 * A Sales Order document, as the detail screen models it.
 *
 * Shared by every read and every write so a screen showing a just-saved order
 * cannot disagree with the same screen after a refresh.
 */
function toOrderDetail(doc: Record<string, unknown>): OrderDetail {
  const items = Array.isArray(doc.items) ? (doc.items as Record<string, unknown>[]) : [];
  return {
    ...toTeamOrder(doc),
    proformaStatus: str(doc.custom_proforma_status),
    changedAfterApproval: Number(doc.custom_changed_after_approval) === 1,
    placedAt: str(doc.custom_order_placed_at),
    lines: items.map(toOrderLine),
  };
}

function toOrderLine(r: Record<string, unknown>): OrderLine {
  const n = (k: string) => Number(r[k]) || 0;
  return {
    id: String(r.name),
    itemCode: str(r.item_code) ?? '',
    itemName: str(r.item_name) ?? str(r.item_code) ?? '',
    itemGroup: str(r.item_group),
    category: str(r[SALES_ORDER_ITEM_FIELD.category]),
    qty: n('qty'),
    uom: str(r.uom),
    rate: n('rate'),
    amount: n('amount'),
    ratePerKg: n(SALES_ORDER_ITEM_FIELD.ratePerKg),
    totalWeight: n(SALES_ORDER_ITEM_FIELD.totalWeight),
    rolls: n(SALES_ORDER_ITEM_FIELD.rolls),
    looseBelts: n(SALES_ORDER_ITEM_FIELD.looseBelts),
    packingNote: str(r[SALES_ORDER_ITEM_FIELD.packingNote]),
    rateApproved: Number(r[SALES_ORDER_ITEM_FIELD.rateApproved]) === 1,
    /*
     * Read through the shared helpers, which try the standard field, then the
     * lead-order spelling, then fall back to `rate`. An order raised before
     * discounts existed has no `price_list_rate` at all and must read as full
     * price rather than as free.
     */
    discountPercent: discountPercentOf(r),
    priceListRate: rateBeforeDiscount(r),
    amountBeforeDiscount: lineBeforeDiscount(r),
    amountAfterDiscount: lineAfterDiscount(r),
    fulfilmentMode: str(r[SALES_ORDER_ITEM_FIELD.fulfilmentMode]),
    productionStage: str(r[SALES_ORDER_ITEM_FIELD.productionStage]),
    stockStage: str(r[SALES_ORDER_ITEM_FIELD.stockStage]),
    agedBatch: str(r[SALES_ORDER_ITEM_FIELD.agedBatch]),
  };
}

export type OrderDecision = 'approve' | 'reject' | 'escalate';

/**
 * Decide an order.
 *
 * Approving writes THREE things, not one:
 *
 *   - `custom_po_status` to the approved string,
 *   - `custom_rate_approved = 1` on the order, and
 *   - `custom_rate_approved = 1` on **every line**.
 *
 * The per-line stamp is the only way the app can later tell a price that was
 * signed off from one the rep typed afterwards. Skipping it silently unlocks
 * every rate on the order.
 *
 * The lines are re-read here rather than taken from the screen: a rep may have
 * edited the order since it was opened, and re-sending a stale `items` array
 * would revert their change while approving it.
 */
async function decideSalesOrder(input: {
  id: string;
  decision: OrderDecision;
  /** Per-line rate edits, keyed by the child row name. */
  rateEdits?: Record<string, number>;
  /** Whose decision this is. Only the GM may move an already-approved price. */
  role?: string;
}): Promise<OrderDetail> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.salesOrder, input.id);
  const items = Array.isArray(doc.items) ? (doc.items as Record<string, unknown>[]) : [];

  const approving = input.decision === 'approve';
  const status =
    input.decision === 'approve'
      ? 'PO Approved - Ready for SAP'
      : input.decision === 'reject'
        ? 'Rejected'
        : 'Pending GM Approval';

  const nextItems = items.map((l) => {
    const edited = input.rateEdits?.[String(l.name)];
    const next: Record<string, unknown> = { ...l };

    /*
     * Both gates are re-checked against the line **as stored**, never against
     * what the page had loaded. There are no Server Scripts on this site, so
     * this is the only thing between a stale tab and a price that was signed
     * off being quietly moved.
     */
    const lockedNow = Number(l[SALES_ORDER_ITEM_FIELD.rateApproved]) === 1;
    const mayPrice = rateEditable(input.role, lockedNow);

    const qty = Number(l.qty) || 0;
    const weight = Number(l[SALES_ORDER_ITEM_FIELD.totalWeight]) || 0;

    // Per kg, before any discount. An edit replaces it; otherwise it stands.
    const perKg =
      mayPrice && edited != null && edited > 0
        ? edited
        : Number(l[SALES_ORDER_ITEM_FIELD.ratePerKg]) || 0;

    /*
     * ERPNext holds one qty and one rate, but tread rubber is counted in
     * rolls and priced by the kilogram. Keeping
     * `qty x rate == totalWeight x ratePerKg` is what makes the order total
     * agree with the proforma; writing ratePerKg alone would leave the two
     * describing different money.
     */
    const perUnitBefore =
      qty > 0 && weight > 0
        ? (perKg * weight) / qty
        : Number(l[SALES_ORDER_ITEM_FIELD.priceListRate]) || Number(l.rate) || 0;

    /*
     * The discount is NOT touched here. It is written line by line as the
     * manager sets it, the way the phone does — `setLineDiscount`. Approval
     * fixes what is already on the line; it does not apply anything new.
     *
     * The percentage stored on the line is re-applied to the (possibly new)
     * rate so the two never contradict each other. Reading it through
     * `discountPercentOf` picks up the lead-order spelling as well.
     */
    const percent = discountPercentOf(l);
    const money = discountFields({
      item: { ...l, price_list_rate: perUnitBefore, custom_price_list_rate: 0, rate: 0 },
      percent,
      isLead: false,
    });

    // Written on every line, not only the edited ones. A line whose discount
    // was never touched still needs `price_list_rate` filled in, or the
    // before/after comparison has nothing to compare against next time.
    if (perKg > 0) next[SALES_ORDER_ITEM_FIELD.ratePerKg] = perKg;
    Object.assign(next, money);

    // Only approval locks a rate. A rejection leaves the prices editable so
    // the rep can fix what was wrong with them.
    if (approving) next[SALES_ORDER_ITEM_FIELD.rateApproved] = 1;
    return next;
  });

  const saved = await updateDoc<Record<string, unknown>>(DOCTYPE.salesOrder, input.id, {
    [SALES_ORDER_FIELD.poStatus]: status,
    [SALES_ORDER_FIELD.ratesApproved]: approving ? 1 : 0,
    items: nextItems,
  });

  return toOrderDetail(saved);
}

/**
 * The minimum-stock pool.
 *
 * Read whole rather than per item: an order has a handful of lines but the
 * screen has to answer "could this have come off the shelf?" for every one of
 * them at once, and 164 rows is one small request against N round trips.
 */
async function listMinimumStock(): Promise<MinStockLine[]> {
  /*
   * Two doctypes, because the pool holds the **target** and the batch holds
   * the **stock**. `Manna Minimum Stock Item.qty` is the minimum to hold —
   * reading it as the shelf is the mistake that makes every availability
   * figure wrong. Proven live: `120 AJAX 69` is minimum 2 / shelf 4, and
   * `160 RTS 99` is minimum 10 / shelf 0.
   */
  const [rows, batches] = await Promise.all([
    listDocs<Record<string, unknown>>(DOCTYPE.minStock, {
      fields: ['name', ...Object.values(MIN_STOCK_FIELD), 'disabled'],
      filters: [['disabled', '=', 0]],
      limit: 0,
    }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.minStock)),
    listDocs<Record<string, unknown>>(DOCTYPE.stockBatch, {
      fields: ['name', ...Object.values(MIN_STOCK_BATCH_FIELD)],
      limit: 0,
    }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.stockBatch)),
  ]);

  const n = (r: Record<string, unknown>, k: string) => Number(r[k]) || 0;

  // An item can carry more than one batch, so the shelf is their sum and the
  // stock age comes from the oldest.
  const shelf = new Map<string, { rolls: number; belts: number; oldest?: string }>();
  for (const b of batches) {
    const code = str(b[MIN_STOCK_BATCH_FIELD.itemCode]) ?? '';
    if (!code) continue;
    const cur = shelf.get(code) ?? { rolls: 0, belts: 0 };
    const date = str(b[MIN_STOCK_BATCH_FIELD.batchDate]);
    shelf.set(code, {
      rolls: cur.rolls + n(b, MIN_STOCK_BATCH_FIELD.rolls),
      belts: cur.belts + n(b, MIN_STOCK_BATCH_FIELD.looseBelts),
      oldest: !cur.oldest || (date && date < cur.oldest) ? (date ?? cur.oldest) : cur.oldest,
    });
  }

  return rows.map((r) => {
    const itemCode = str(r[MIN_STOCK_FIELD.itemCode]) ?? String(r.name);
    const s = shelf.get(itemCode);
    return {
      itemCode,
      minimumRolls: n(r, MIN_STOCK_FIELD.minimumRolls),
      minimumBelts: n(r, MIN_STOCK_FIELD.minimumBelts),
      // No batch at all means nothing on the shelf, not "unknown". A pool with
      // no batch is exactly the empty one production needs to see.
      shelfRolls: s?.rolls ?? 0,
      shelfBelts: s?.belts ?? 0,
      reservedRolls: n(r, MIN_STOCK_FIELD.reservedRolls),
      reservedBelts: n(r, MIN_STOCK_FIELD.reservedLooseBelts),
      inProductionRolls: n(r, MIN_STOCK_FIELD.inProductionRolls),
      inProductionBelts: n(r, MIN_STOCK_FIELD.inProductionBelts),
      reservedInProductionRolls: n(r, MIN_STOCK_FIELD.reservedInProductionRolls),
      reservedInProductionBelts: n(r, MIN_STOCK_FIELD.reservedInProductionBelts),
      runStage: str(r[MIN_STOCK_FIELD.runStage]),
      runUpdatedOn: str(r[MIN_STOCK_FIELD.inProductionUpdatedOn]),
      runUpdatedBy: str(r[MIN_STOCK_FIELD.inProductionUpdatedBy]),
      lastSoldOn: str(r[MIN_STOCK_FIELD.lastSoldOn]),
      batchDate: s?.oldest,
    };
  });
}

/**
 * Claim stock out of a production run.
 *
 * The run is a **second pool with its own counter**, and the two are never
 * added together: an empty shelf with a full run still sells nothing off the
 * shelf. This claims against `custom_reserved_in_production_qty` only.
 *
 * **Compare-and-swap, because there are no Server Scripts.** Two reps claiming
 * the last rolls of a run at the same time would otherwise both read the same
 * free figure and both succeed, promising rubber twice. The protocol is:
 * re-read immediately before writing, refuse if the free quantity no longer
 * covers the claim, write, then read back and confirm the counter holds what
 * we put there. A lost update is detected rather than assumed away.
 *
 * There is **no roll-cutting on a run**: nothing has been made, so there is no
 * roll to open into belts.
 */
async function claimFromRun(input: {
  itemCode: string;
  rolls: number;
  belts: number;
  salesOrder: string;
  salesPerson?: string;
  /** Bounded retries when another claim lands between our read and write. */
  attempts?: number;
}): Promise<{ claimed: boolean; available: number; reason?: string }> {
  const want = { rolls: input.rolls || 0, belts: input.belts || 0 };
  if (want.rolls <= 0 && want.belts <= 0) {
    return { claimed: false, available: 0, reason: 'Nothing to claim.' };
  }

  const maxAttempts = input.attempts ?? 3;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const doc = await getDoc<Record<string, unknown>>(DOCTYPE.minStock, input.itemCode);
    const runRolls = Number(doc[MIN_STOCK_FIELD.inProductionRolls]) || 0;
    const runBelts = Number(doc[MIN_STOCK_FIELD.inProductionBelts]) || 0;
    const takenRolls = Number(doc[MIN_STOCK_FIELD.reservedInProductionRolls]) || 0;
    const takenBelts = Number(doc[MIN_STOCK_FIELD.reservedInProductionBelts]) || 0;

    const freeRolls = Math.max(0, runRolls - takenRolls);
    const freeBelts = Math.max(0, runBelts - takenBelts);

    if (want.rolls > freeRolls || want.belts > freeBelts) {
      return {
        claimed: false,
        available: freeRolls,
        reason:
          runRolls === 0
            ? 'There is no production run recorded for this item.'
            : `Only ${freeRolls} roll(s) of this run are unclaimed.`,
      };
    }

    await updateDoc(DOCTYPE.minStock, input.itemCode, {
      [MIN_STOCK_FIELD.reservedInProductionRolls]: takenRolls + want.rolls,
      [MIN_STOCK_FIELD.reservedInProductionBelts]: takenBelts + want.belts,
    });

    // Read back. If somebody else's claim interleaved, the counter will not
    // hold our figure and we start again rather than assume we won.
    const after = await getDoc<Record<string, unknown>>(DOCTYPE.minStock, input.itemCode);
    const nowTaken = Number(after[MIN_STOCK_FIELD.reservedInProductionRolls]) || 0;
    if (nowTaken !== takenRolls + want.rolls) continue;

    // Only once the counter is ours do we record the claim itself. A
    // reservation without the counter behind it is the phantom booking that
    // has already bitten this site once.
    await createDoc(DOCTYPE.stockReservation, {
      [STOCK_RESERVATION_FIELD.itemCode]: input.itemCode,
      [STOCK_RESERVATION_FIELD.rolls]: want.rolls,
      [STOCK_RESERVATION_FIELD.looseBelts]: want.belts,
      [STOCK_RESERVATION_FIELD.salesOrder]: input.salesOrder,
      [STOCK_RESERVATION_FIELD.salesPerson]: input.salesPerson,
      [STOCK_RESERVATION_FIELD.status]: 'Active',
      [STOCK_RESERVATION_FIELD.source]: RESERVATION_SOURCE.productionRun,
      [STOCK_RESERVATION_FIELD.reservedOn]: serverNow()
        .toISOString()
        .slice(0, 19)
        .replace('T', ' '),
    });

    return { claimed: true, available: freeRolls - want.rolls };
  }

  return {
    claimed: false,
    available: 0,
    reason: 'Another claim landed on this run while yours was saving. Try again.',
  };
}

/**
 * Move a run's stage, and write it down onto every line claimed against it.
 *
 * **One batch is being made, not one job per order.** The stage lives on the
 * run; pushing it down onto each claimed `custom_production_stage` is what
 * keeps every other screen — the production order detail, the roll-up, the
 * completion tick — working unchanged rather than needing to know runs exist.
 */
async function setRunStage(input: { itemCode: string; stage: string }): Promise<number> {
  await updateDoc(DOCTYPE.minStock, input.itemCode, {
    [MIN_STOCK_FIELD.runStage]: input.stage,
  });

  const reservations = await listStockReservations();
  const claimed = reservations.filter(
    (r) =>
      r.status === 'Active' &&
      r.itemCode === input.itemCode &&
      r.source === RESERVATION_SOURCE.productionRun &&
      r.salesOrder,
  );

  const orders = [...new Set(claimed.map((r) => r.salesOrder as string))];
  let touched = 0;
  for (const orderId of orders) {
    try {
      const doc = await getDoc<Record<string, unknown>>(DOCTYPE.salesOrder, orderId);
      const items = Array.isArray(doc.items) ? (doc.items as Record<string, unknown>[]) : [];
      const nextItems = items.map((l) =>
        str(l.item_code) === input.itemCode
          ? { ...l, [SALES_ORDER_ITEM_FIELD.productionStage]: input.stage }
          : l,
      );
      const status = rollUp(
        nextItems.map((l) => {
          const held = heldBy(reservations, str(l.item_code) ?? '', orderId);
          const rolls = Number(l[SALES_ORDER_ITEM_FIELD.rolls]) || 0;
          const belts = Number(l[SALES_ORDER_ITEM_FIELD.looseBelts]) || 0;
          return {
            category: str(l[SALES_ORDER_ITEM_FIELD.category]),
            fulfilmentMode: str(l[SALES_ORDER_ITEM_FIELD.fulfilmentMode]),
            productionStage: str(l[SALES_ORDER_ITEM_FIELD.productionStage]),
            stockStage: str(l[SALES_ORDER_ITEM_FIELD.stockStage]),
            reservedRolls: held.rolls,
            reservedBelts: held.belts,
            toMakeRolls: Math.max(0, rolls - held.rolls),
            toMakeBelts: Math.max(0, belts - held.belts),
            splitKnown: true,
          };
        }),
      );
      await updateDoc(DOCTYPE.salesOrder, orderId, {
        items: nextItems,
        [SALES_ORDER_FIELD.productionStatus]: status,
      });
      touched += 1;
    } catch {
      // One unreachable order must not strand the rest of the run.
    }
  }
  return touched;
}

/**
 * Receive a run: the goods have landed.
 *
 * Claims against the run become claims against the shelf, the run counters and
 * its stage are cleared, and the reservations are re-labelled `Shelf`.
 *
 * **It does not create the batch.** Receiving physical stock is a Desk job, and
 * inventing a batch here would put rubber on the shelf that nobody counted. So
 * this raises the shelf's *reserved* figure and leaves the batch quantity to
 * whoever actually books the goods in — which is why the pool will read
 * over-reserved until they do. That is visible and correct; the alternative is
 * invisible and wrong.
 */
async function receiveRun(itemCode: string): Promise<{ movedRolls: number; relabelled: number }> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.minStock, itemCode);
  const claimedRolls = Number(doc[MIN_STOCK_FIELD.reservedInProductionRolls]) || 0;
  const claimedBelts = Number(doc[MIN_STOCK_FIELD.reservedInProductionBelts]) || 0;
  const shelfReservedRolls = Number(doc[MIN_STOCK_FIELD.reservedRolls]) || 0;
  const shelfReservedBelts = Number(doc[MIN_STOCK_FIELD.reservedLooseBelts]) || 0;

  // One write: the claims move across, the run is cleared, the stage goes.
  await updateDoc(DOCTYPE.minStock, itemCode, {
    [MIN_STOCK_FIELD.reservedRolls]: shelfReservedRolls + claimedRolls,
    [MIN_STOCK_FIELD.reservedLooseBelts]: shelfReservedBelts + claimedBelts,
    [MIN_STOCK_FIELD.inProductionRolls]: 0,
    [MIN_STOCK_FIELD.inProductionBelts]: 0,
    [MIN_STOCK_FIELD.reservedInProductionRolls]: 0,
    [MIN_STOCK_FIELD.reservedInProductionBelts]: 0,
    [MIN_STOCK_FIELD.runStage]: '',
  });

  const reservations = await listStockReservations();
  let relabelled = 0;
  for (const r of reservations) {
    if (r.status !== 'Active') continue;
    if (r.itemCode !== itemCode) continue;
    if (r.source !== RESERVATION_SOURCE.productionRun) continue;
    try {
      await updateDoc(DOCTYPE.stockReservation, r.id, {
        [STOCK_RESERVATION_FIELD.source]: RESERVATION_SOURCE.shelf,
      });
      relabelled += 1;
    } catch {
      // Leave it labelled as a run claim rather than losing the claim itself.
    }
  }

  return { movedRolls: claimedRolls, relabelled };
}

/**
 * Record a production run against a pool.
 *
 * The run is raised in SAP, which neither app can see; this only records it so
 * everyone else knows stock is coming. It is **intent, not stock** — nothing
 * downstream counts it towards availability. Setting 0 clears it.
 */
async function recordProductionRun(input: {
  itemCode: string;
  rolls: number;
  belts: number;
  by: string;
}): Promise<void> {
  await updateDoc(DOCTYPE.minStock, input.itemCode, {
    [MIN_STOCK_FIELD.inProductionRolls]: input.rolls,
    [MIN_STOCK_FIELD.inProductionBelts]: input.belts,
    // Server clock, so the stamp agrees with every other deadline in the app.
    [MIN_STOCK_FIELD.inProductionUpdatedOn]: serverNow().toISOString().slice(0, 19).replace('T', ' '),
    [MIN_STOCK_FIELD.inProductionUpdatedBy]: input.by,
    ...(input.rolls === 0 && input.belts === 0 ? { [MIN_STOCK_FIELD.runStage]: '' } : {}),
  });
}

/**
 * The sellable catalogue, for the order editor's item picker.
 *
 * Filtered on the **Item** category vocabulary (`Precured`, `HOT`, …), not the
 * order line's (`PCTR`, `CTR`, …). Those are different Select lists on the same
 * field name and nothing on the site reconciles them — filtering by the order
 * codes matches zero rows and hands back an empty catalogue that looks like a
 * permissions problem.
 */
async function listItemOptions(): Promise<ItemOption[]> {
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.item, {
    fields: [
      'name',
      'item_name',
      'item_group',
      'stock_uom',
      ITEM_FIELD.category,
      ITEM_FIELD.weightPerBelt,
      ITEM_FIELD.beltsPerRoll,
      ITEM_FIELD.weightPerRoll,
      ITEM_FIELD.packLitres,
      ITEM_FIELD.sapCode,
      ITEM_FIELD.weightStatus,
    ],
    filters: [
      ['disabled', '=', 0],
      ['is_sales_item', '=', 1],
    ],
    limit: 0,
  });

  const out: ItemOption[] = [];
  for (const r of rows) {
    const n = (k: string): number | undefined => {
      const v = Number(r[k]);
      return Number.isFinite(v) && v > 0 ? v : undefined;
    };
    const itemCategory = str(r[ITEM_FIELD.category]);
    const mapped =
      ITEM_CATEGORY_TO_LINE[itemCategory as keyof typeof ITEM_CATEGORY_TO_LINE] ??
      inferCategory(`${r.name ?? ''} ${r.item_name ?? ''} ${r.item_group ?? ''}`);
    // An item nobody can classify cannot be priced by any of the four rule
    // sets, so it is left out rather than defaulted into one of them.
    if (!mapped) continue;

    const weights = normaliseWeights({
      weightPerBelt: n(ITEM_FIELD.weightPerBelt),
      beltsPerRoll: n(ITEM_FIELD.beltsPerRoll),
      weightPerRoll: n(ITEM_FIELD.weightPerRoll),
    });

    out.push({
      code: String(r.name),
      name: String(r.item_name ?? r.name),
      category: mapped as ProductCategory,
      itemCategory,
      itemGroup: str(r.item_group),
      uom: str(r.stock_uom) ?? 'Kg',
      ...weights,
      packLitres: n(ITEM_FIELD.packLitres),
      sapCode: str(r[ITEM_FIELD.sapCode]),
      weightStatus: str(r[ITEM_FIELD.weightStatus]),
    });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * Set one line's fulfilment mode.
 *
 * Written through the parent because Frappe refuses a direct write to a child
 * table — `Sales Order Item` answers 403 to its own endpoint. The order is
 * re-read first so a rep's concurrent edit is not reverted by sending back a
 * stale `items` array.
 */
async function setFulfilmentMode(input: {
  orderId: string;
  lineId: string;
  mode: string;
}): Promise<OrderDetail> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.salesOrder, input.orderId);
  const items = Array.isArray(doc.items) ? (doc.items as Record<string, unknown>[]) : [];

  const nextItems = items.map((l) =>
    String(l.name) === input.lineId
      ? { ...l, [SALES_ORDER_ITEM_FIELD.fulfilmentMode]: input.mode }
      : l,
  );

  const saved = await updateDoc<Record<string, unknown>>(DOCTYPE.salesOrder, input.orderId, {
    items: nextItems,
  });
  return toOrderDetail(saved);
}

/** One edited or added line, as the order editor hands it over. */
export interface OrderLineWrite {
  /** The existing child row's name, or undefined for a line being added. */
  id?: string;
  itemCode: string;
  qty: number;
  rate: number;
  amount: number;
  ratePerKg: number;
  totalWeight: number;
  rolls: number;
  looseBelts: number;
  category: string;
  packingNote: string;
  uom: string;
  fulfilmentMode?: string;
}

/**
 * Replace an order's lines with an edited set.
 *
 * The whole `items` array is sent because that is the only way Frappe accepts
 * a child table: rows present are kept or updated, rows omitted are **deleted**.
 * That makes a removal trivial and a mistake expensive, so the caller passes
 * the complete intended set, never a delta.
 *
 * Existing rows keep their `name` so their history and any per-line approval
 * survive; a new row is sent without one and Frappe names it.
 */
/**
 * Put a discount on one line, or take it off.
 *
 * A port of `Api.setLineDiscount` in `app/lib/services/api.dart`, down to the
 * order of the checks and the wording of the refusals. The manager sets a
 * discount and it is written **there and then**, not held until the approval —
 * on the phone the figure is applied as soon as it is entered, and a dashboard
 * that queued it would leave a manager who set a discount and walked away
 * believing they had given one.
 *
 * The order is re-read first. Not for freshness: for the two things that can
 * only be answered against the stored document — whether it has been signed
 * off since the page loaded, and whether the line is still on it.
 */
async function setLineDiscount(input: {
  orderId: string;
  lineId: string;
  percent: number;
  isLead?: boolean;
}): Promise<OrderDetail> {
  const isLead = input.isLead ?? false;
  const refusal = discountRefusal(input.percent);
  if (refusal) throw new Error(refusal);

  const doctype = isLead ? DOCTYPE.leadOrder : DOCTYPE.salesOrder;
  const order = await getDoc<Record<string, unknown>>(doctype, input.orderId);

  if (
    orderSignedOff(
      {
        poStatus: str(order[SALES_ORDER_FIELD.poStatus]),
        status: str(order.status),
        ratesApproved: Number(order[SALES_ORDER_FIELD.ratesApproved]) === 1,
      },
      isLead,
    )
  ) {
    throw new Error('This order is approved — its discounts and rates are final.');
  }

  const rows = Array.isArray(order.items) ? (order.items as Record<string, unknown>[]) : [];
  let found = false;
  const items = rows.map((row) => {
    if (String(row.name) !== input.lineId) return row;
    found = true;
    return { ...row, ...discountFields({ item: row, percent: input.percent, isLead }) };
  });

  /*
   * A row that is no longer there means the order moved under the manager — a
   * rep editing it at the same moment. Writing the array back anyway would
   * save a discount onto nothing while reporting success.
   */
  if (!found) {
    throw new Error('That line is no longer on the order. Reopen it and try again.');
  }

  const saved = await updateDoc<Record<string, unknown>>(doctype, input.orderId, { items });
  return toOrderDetail(saved);
}

/**
 * Bring this order's hold on one item up (or down) to what the line now asks.
 *
 * **Why this exists.** A reservation is written by whoever books the line, and
 * until 13 Aug 2026 that was only ever the rep's phone. Editing the quantity
 * here rewrote the Sales Order and nothing else, so raising `155 MSR 87` from
 * one roll to two left the hold at one — while three rolls sat free on the
 * shelf. The order then read as needing a roll manufactured, and any other rep
 * could have taken the stock in the meantime. Stock that is on the shelf must
 * come off the shelf; production is for what the shelf has not got.
 *
 * **The shelf is the batch, never the pool's `qty`.** `qty` is the minimum to
 * hold. Reading it as stock is the mistake that makes every figure here wrong.
 *
 * **Free is measured against the reservation rows, not the stored counter.**
 * The counter is a hand-maintained cache with no Server Script behind it and
 * it has already been proven wrong on this site — `120 AJAX 69` claimed three
 * rolls booked with nothing behind them after a Sales Order was deleted in the
 * Desk. Summing the rows both frees stock that genuinely is free and repairs
 * the counter on the way past.
 *
 * **Order of writes.** Taking stock raises the counter first and writes the row
 * second, so a crash in between over-books rather than hands the same roll to
 * two orders. Releasing does the reverse. The counter is read back after every
 * write: if another claim interleaved it will not hold our figure, and we start
 * again instead of assuming we won.
 */
async function holdFromShelf(input: {
  itemCode: string;
  orderId: string;
  wantRolls: number;
  wantBelts: number;
  salesPerson?: string;
  attempts?: number;
}): Promise<{ rolls: number; belts: number; short: number } | null> {
  const maxAttempts = input.attempts ?? 3;

  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const pool = await getDoc<Record<string, unknown>>(DOCTYPE.minStock, input.itemCode).catch(
      () => null,
    );
    // Not a stocked item. Nothing to hold, and nothing has gone wrong: the
    // line is made to order by definition.
    if (!pool) return null;

    const batches = await listDocs<Record<string, unknown>>(DOCTYPE.stockBatch, {
      fields: ['name', ...Object.values(MIN_STOCK_BATCH_FIELD)],
      filters: [[MIN_STOCK_BATCH_FIELD.itemCode, '=', input.itemCode]],
      limit: 0,
    }).catch(() => [] as Record<string, unknown>[]);

    let shelfRolls = 0;
    let shelfBelts = 0;
    for (const b of batches) {
      shelfRolls += Number(b[MIN_STOCK_BATCH_FIELD.rolls]) || 0;
      shelfBelts += Number(b[MIN_STOCK_BATCH_FIELD.looseBelts]) || 0;
    }

    const all = await listStockReservations();
    const mine = all.filter(
      (r) =>
        r.status === 'Active' &&
        r.itemCode === input.itemCode &&
        r.source !== RESERVATION_SOURCE.productionRun &&
        (r.salesOrder === input.orderId || r.leadOrder === input.orderId),
    );
    const heldRolls = mine.reduce((n, r) => n + r.rolls, 0);
    const heldBelts = mine.reduce((n, r) => n + r.looseBelts, 0);
    const plan = holdPlan({
      ordered: { rolls: input.wantRolls, belts: input.wantBelts },
      held: { rolls: heldRolls, belts: heldBelts },
      shelf: { rolls: shelfRolls, belts: shelfBelts },
      reservedTotal: trueReserved(all, input.itemCode),
    });

    const targetRolls = plan.target.rolls;
    const targetBelts = plan.target.belts;
    const short = plan.short.rolls;

    if (!plan.changed) return { rolls: heldRolls, belts: heldBelts, short };

    const nextCounterRolls = plan.counter.rolls;
    const nextCounterBelts = plan.counter.belts;
    const taking = plan.delta.rolls > 0 || plan.delta.belts > 0;

    const writeRows = async () => {
      // One row per order and item. Extra rows from earlier edits are zeroed
      // and released so the sum can never read higher than the hold.
      const [keep, ...spare] = mine;
      if (targetRolls === 0 && targetBelts === 0) {
        for (const r of mine) {
          await updateDoc(DOCTYPE.stockReservation, r.id, {
            [STOCK_RESERVATION_FIELD.rolls]: 0,
            [STOCK_RESERVATION_FIELD.looseBelts]: 0,
            [STOCK_RESERVATION_FIELD.status]: 'Released',
          });
        }
        return;
      }
      for (const r of spare) {
        await updateDoc(DOCTYPE.stockReservation, r.id, {
          [STOCK_RESERVATION_FIELD.rolls]: 0,
          [STOCK_RESERVATION_FIELD.looseBelts]: 0,
          [STOCK_RESERVATION_FIELD.status]: 'Released',
        });
      }
      if (keep) {
        await updateDoc(DOCTYPE.stockReservation, keep.id, {
          [STOCK_RESERVATION_FIELD.rolls]: targetRolls,
          [STOCK_RESERVATION_FIELD.looseBelts]: targetBelts,
          [STOCK_RESERVATION_FIELD.status]: 'Active',
        });
      } else {
        await createDoc(DOCTYPE.stockReservation, {
          [STOCK_RESERVATION_FIELD.itemCode]: input.itemCode,
          [STOCK_RESERVATION_FIELD.rolls]: targetRolls,
          [STOCK_RESERVATION_FIELD.looseBelts]: targetBelts,
          [STOCK_RESERVATION_FIELD.salesOrder]: input.orderId,
          [STOCK_RESERVATION_FIELD.salesPerson]: input.salesPerson,
          [STOCK_RESERVATION_FIELD.status]: 'Active',
          [STOCK_RESERVATION_FIELD.source]: RESERVATION_SOURCE.shelf,
          [STOCK_RESERVATION_FIELD.reservedOn]: serverNow()
            .toISOString()
            .slice(0, 19)
            .replace('T', ' '),
        });
      }
    };

    const writeCounter = () =>
      updateDoc(DOCTYPE.minStock, input.itemCode, {
        [MIN_STOCK_FIELD.reservedRolls]: nextCounterRolls,
        [MIN_STOCK_FIELD.reservedLooseBelts]: nextCounterBelts,
      });

    if (taking) {
      await writeCounter();
      const after = await getDoc<Record<string, unknown>>(DOCTYPE.minStock, input.itemCode);
      if ((Number(after[MIN_STOCK_FIELD.reservedRolls]) || 0) !== nextCounterRolls) continue;
      await writeRows();
    } else {
      await writeRows();
      await writeCounter();
    }

    return { rolls: targetRolls, belts: targetBelts, short };
  }

  return null;
}

async function saveOrderLines(input: {
  orderId: string;
  lines: OrderLineWrite[];
}): Promise<OrderDetail> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.salesOrder, input.orderId);
  const existing = Array.isArray(doc.items) ? (doc.items as Record<string, unknown>[]) : [];
  const byName = new Map(existing.map((l) => [String(l.name), l]));

  const items = input.lines.map((l) => {
    // Spread the stored row first so warehouse, HSN code, tax fields and the
    // rest survive an edit — rebuilding a line from scratch would drop them.
    const base = l.id ? (byName.get(l.id) ?? {}) : {};

    /*
     * A discount already granted survives a quantity or rate change. It was a
     * decision about this customer and this product; changing how many rolls
     * they are taking does not withdraw it. The percentage is re-applied to
     * the new figure so the money stays consistent — dropping it would
     * silently raise the price the customer was quoted.
     *
     * `l.rate`/`l.amount` arrive from the editor as the UNDISCOUNTED figures,
     * because that is what the packing rules compute.
     */
    const percent = discountPercentOf(base);
    const money = discountFields({
      // `l.rate` arrives from the editor as the UNDISCOUNTED per-unit figure,
      // because that is what the packing rules compute. Handing it in as the
      // price-list rate is what makes the percentage come off the rep's rate
      // rather than off an already-discounted one.
      item: { qty: l.qty, price_list_rate: l.rate },
      percent,
      isLead: false,
    });

    return {
      ...base,
      item_code: l.itemCode,
      qty: l.qty,
      ...money,
      uom: l.uom,
      conversion_factor: 1,
      delivery_date: str(doc.delivery_date),
      [SALES_ORDER_ITEM_FIELD.category]: l.category,
      [SALES_ORDER_ITEM_FIELD.rolls]: l.rolls,
      [SALES_ORDER_ITEM_FIELD.looseBelts]: l.looseBelts,
      [SALES_ORDER_ITEM_FIELD.totalWeight]: l.totalWeight,
      [SALES_ORDER_ITEM_FIELD.ratePerKg]: l.ratePerKg,
      [SALES_ORDER_ITEM_FIELD.packingNote]: l.packingNote,
      [SALES_ORDER_ITEM_FIELD.fulfilmentMode]: l.fulfilmentMode ?? '',
      // Cleared to match the order going back to Pending below. A line still
      // flagged approved under an unapproved order reads as a locked price to
      // every screen that checks the line rather than the status.
      [SALES_ORDER_ITEM_FIELD.rateApproved]: 0,
    };
  });

  const saved = await updateDoc<Record<string, unknown>>(DOCTYPE.salesOrder, input.orderId, {
    items,
    /*
     * Editing the lines changes the money, so the order goes back for a
     * decision and every line rate reopens. Leaving it approved would ship a
     * total nobody signed off — the exact failure `custom_changed_after_approval`
     * exists to catch.
     */
    [SALES_ORDER_FIELD.poStatus]: 'Pending Approval',
    [SALES_ORDER_FIELD.ratesApproved]: 0,
  });

  /*
   * Now make the stock match the order.
   *
   * The order document is written first and the holds second, deliberately.
   * A hold without a line behind it is stock nobody can sell and nobody can
   * see; a line without its hold is visible on this screen and fixed by
   * saving again. The failure that costs least is the recoverable one.
   *
   * Every line is topped up, not just the ones that changed — a line the rep
   * booked before the shelf was refilled has been sitting under-held, and
   * there is no reason to leave it that way once somebody opens the order.
   */
  const want = new Map<string, { rolls: number; belts: number }>();
  for (const l of input.lines) {
    const cur = want.get(l.itemCode) ?? { rolls: 0, belts: 0 };
    want.set(l.itemCode, { rolls: cur.rolls + l.rolls, belts: cur.belts + l.looseBelts });
  }
  // A line that has been taken off the order must give its stock back, so the
  // items that were on the document before are asked for zero.
  for (const l of existing) {
    const code = str(l.item_code);
    if (code && !want.has(code)) want.set(code, { rolls: 0, belts: 0 });
  }

  const rep = str(doc[SALES_ORDER_FIELD.rep]);
  for (const [itemCode, q] of want) {
    // One item failing to hold must not lose the rest. The order is already
    // saved; the stock position is shown on the line and can be retried.
    await holdFromShelf({
      itemCode,
      orderId: input.orderId,
      wantRolls: q.rolls,
      wantBelts: q.belts,
      salesPerson: rep,
    }).catch(() => null);
  }

  return toOrderDetail(saved);
}

// ======================================================= approvals inbox ===

/**
 * Everything the manager owes a decision on **except orders**.
 *
 * Orders are decided in the order-review screen and nowhere else: that
 * decision needs the lines, the stock position and the credit picture, which
 * an inbox row cannot carry. Two places to decide would be two places to miss
 * one — so these four are only here, and orders are only there.
 */
export type InboxKind = 'proforma' | 'site';

export interface InboxItem {
  kind: InboxKind;
  id: string;
  title: string;
  rep?: string;
  party?: string;
  amount?: number;
  photo?: string;
  latitude?: number;
  longitude?: number;
  route?: string;
  address?: string;
}

async function listApprovalInbox(reps?: string[]): Promise<InboxItem[]> {
  const teamFilter = (field: string): Filter[] =>
    reps && reps.length ? [[field, 'in', reps]] : [];

  const [proformas, sites] = await Promise.all([
    listDocs<Record<string, unknown>>(DOCTYPE.salesOrder, {
      fields: ['name', ...Object.values(SALES_ORDER_FIELD)],
      filters: [
        [SALES_ORDER_FIELD.proformaStatus, '=', PROFORMA_STATUS.pendingRelease],
        ...teamFilter(SALES_ORDER_FIELD.rep),
      ],
      limit: 0,
    }).catch(() => [] as Record<string, unknown>[]),

    // `Customer Site` has no rows yet and its field names are unverified, so
    // it is read with `*` rather than a named field list — an unknown field
    // would 417 and take the whole inbox down with it.
    listDocs<Record<string, unknown>>(DOCTYPE.customerSite, {
      fields: ['*'],
      limit: 0,
    }).catch(() => [] as Record<string, unknown>[]),
  ]);

  const out: InboxItem[] = [];

  for (const r of proformas) {
    out.push({
      kind: 'proforma',
      id: String(r.name),
      title: 'Proforma credit release',
      rep: str(r[SALES_ORDER_FIELD.rep]),
      party: str(r[SALES_ORDER_FIELD.customerName]) ?? str(r[SALES_ORDER_FIELD.customer]),
      amount: Number(r[SALES_ORDER_FIELD.total]) || 0,
    });
  }

  for (const r of sites) {
    const status = str(r.custom_location_status) ?? str(r.location_status);
    if (status !== 'Pending Verification') continue;
    const owningRep = str(r.custom_sales_person) ?? str(r.sales_person);
    if (reps && reps.length && owningRep && !reps.includes(owningRep)) continue;
    // The owner is the customer if set, otherwise the lead. Heading the card
    // with a blank tells the manager nothing about what they are approving.
    const owner = str(r.customer) ?? str(r.lead) ?? 'unknown owner';
    const siteName = str(r.site_name) ?? str(r.name1) ?? String(r.name);
    out.push({
      kind: 'site',
      id: String(r.name),
      title: `Site: ${siteName} (${owner})`,
      rep: owningRep,
      party: owner,
      photo: str(r.custom_banner_photo) ?? str(r.banner_photo),
      latitude: Number(r.custom_latitude ?? r.latitude) || undefined,
      longitude: Number(r.custom_longitude ?? r.longitude) || undefined,
    });
  }

  return out;
}

/**
 * Decide one inbox item — a proforma release, or a site.
 *
 * **Customer and lead locations are no longer here.** Capture is GPS-only and
 * self-verifying: the app writes the captured coordinates into the verified
 * fields at the moment of capture, so there is nothing left for a human to
 * judge. The queue only ever existed because a photograph needed someone to
 * confirm it matched the place, and a queue nobody can act on is worse than
 * none — the record sits at `Pending Verification` for ever and the verified
 * coordinates are never written at all.
 *
 * A **site** is different and keeps its approval: it is somebody asserting new
 * premises exist, not a pin on a shop already on the books.
 */
async function decideInboxItem(input: {
  kind: InboxKind;
  id: string;
  approve: boolean;
  latitude?: number;
  longitude?: number;
}): Promise<void> {
  if (input.kind === 'proforma') {
    await updateDoc(DOCTYPE.salesOrder, input.id, {
      [SALES_ORDER_FIELD.proformaStatus]: input.approve
        ? PROFORMA_STATUS.released
        : PROFORMA_STATUS.blocked,
    });
    return;
  }

  // Approving copies the captured coordinates into the verified fields. Those
  // are what the 100 m punch-in check measures against; verifying without
  // copying them verifies nobody.
  await updateDoc(DOCTYPE.customerSite, input.id, {
    custom_location_status: input.approve ? 'Verified' : 'Not Captured',
    ...(input.approve
      ? {
          custom_verified_latitude: input.latitude,
          custom_verified_longitude: input.longitude,
        }
      : {}),
  });
}

/**
 * Capture a location — GPS only, and it verifies itself.
 *
 * One write, and the captured coordinates go straight into the verified fields
 * because there is no longer anything to check them against. No photo, no
 * queue, no approval.
 */
async function captureLocation(input: {
  kind: 'customer' | 'lead';
  id: string;
  latitude: number;
  longitude: number;
  capturedBy?: string;
}): Promise<void> {
  const body = {
    custom_latitude: input.latitude,
    custom_longitude: input.longitude,
    custom_verified_latitude: input.latitude,
    custom_verified_longitude: input.longitude,
    custom_location_status: 'Verified',
    ...(input.capturedBy ? { custom_location_captured_by: input.capturedBy } : {}),
  };
  await updateDoc(
    input.kind === 'customer' ? DOCTYPE.customer : DOCTYPE.lead,
    input.id,
    body,
  );
}

/** Live claims on the pool. Only `Active` rows hold anything. */
async function listStockReservations(): Promise<StockReservationRow[]> {
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.stockReservation, {
    fields: ['name', ...Object.values(STOCK_RESERVATION_FIELD)],
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.stockReservation));

  return rows.map((r) => ({
    id: String(r.name),
    itemCode: str(r[STOCK_RESERVATION_FIELD.itemCode]) ?? '',
    rolls: Number(r[STOCK_RESERVATION_FIELD.rolls]) || 0,
    looseBelts: Number(r[STOCK_RESERVATION_FIELD.looseBelts]) || 0,
    salesOrder: str(r[STOCK_RESERVATION_FIELD.salesOrder]),
    leadOrder: str(r[STOCK_RESERVATION_FIELD.leadOrder]),
    salesPerson: str(r[STOCK_RESERVATION_FIELD.salesPerson]),
    batch: str(r[STOCK_RESERVATION_FIELD.batch]),
    reservedOn: str(r[STOCK_RESERVATION_FIELD.reservedOn]),
    status: str(r[STOCK_RESERVATION_FIELD.status]) ?? '',
    source: str(r[STOCK_RESERVATION_FIELD.source]),
  }));
}

// ---------------------------------------------------------- lead orders ---

/** Lead orders raised by a set of reps, within a date range. */
async function listLeadOrders(input: {
  reps?: string[];
  from?: string;
  to?: string;
}): Promise<LeadOrder[]> {
  const filters: Filter[] = [];
  if (input.reps?.length) filters.push([LEAD_ORDER_FIELD.rep, 'in', input.reps]);
  if (input.from && input.to) {
    filters.push([LEAD_ORDER_FIELD.orderDate, 'between', [input.from, input.to]]);
  }

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.leadOrder, {
    fields: ['name', ...Object.values(LEAD_ORDER_FIELD)],
    filters,
    orderBy: `${LEAD_ORDER_FIELD.orderDate} desc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.leadOrder));

  return rows.map((r) => toLeadOrder(r, []));
}

function toLeadOrder(r: Record<string, unknown>, items: Record<string, unknown>[]): LeadOrder {
  return {
    id: String(r.name),
    lead: str(r[LEAD_ORDER_FIELD.lead]) ?? '',
    leadName: str(r[LEAD_ORDER_FIELD.leadName]) ?? str(r[LEAD_ORDER_FIELD.lead]) ?? '',
    rep: str(r[LEAD_ORDER_FIELD.rep]),
    orderDate: (str(r[LEAD_ORDER_FIELD.orderDate]) ?? '').slice(0, 10),
    total: Number(r[LEAD_ORDER_FIELD.total]) || 0,
    status: str(r[LEAD_ORDER_FIELD.status]) ?? '',
    poNumber: str(r[LEAD_ORDER_FIELD.poNumber]),
    approvalRemarks: str(r[LEAD_ORDER_FIELD.approvalRemarks]),
    lines: items.map((l) => {
      const qty = Number(l[LEAD_ORDER_ITEM_FIELD.qty]) || 0;
      const rate = Number(l[LEAD_ORDER_ITEM_FIELD.rate]) || 0;
      return {
        id: String(l.name),
        itemCode: str(l[LEAD_ORDER_ITEM_FIELD.itemCode]) ?? '',
        itemName: str(l[LEAD_ORDER_ITEM_FIELD.itemName]) ?? str(l[LEAD_ORDER_ITEM_FIELD.itemCode]) ?? '',
        qty,
        rate,
        /*
         * Through the shared helpers, so a lead order is read by exactly the
         * rules a customer order is. `amount` is a read-only Currency on a
         * custom child table with nothing behind it, so rows written before
         * the app started sending it hold zero — `lineAfterDiscount` falls
         * back to qty x rate rather than showing a manager a nil order
         * against rates the rep entered correctly.
         */
        amount: lineAfterDiscount(l),
        discountPercent: discountPercentOf(l),
        priceListRate: rateBeforeDiscount(l),
        amountBeforeDiscount: lineBeforeDiscount(l),
      };
    }),
  };
}

async function getLeadOrder(id: string): Promise<LeadOrder> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.leadOrder, id);
  const items = Array.isArray(doc.items) ? (doc.items as Record<string, unknown>[]) : [];
  return toLeadOrder(doc, items);
}

/** The three fields a lead must have before it can become a customer. */
export interface LeadGaps {
  gstin: boolean;
  address: boolean;
  route: boolean;
}

export function missingCount(g: LeadGaps): number {
  return Number(g.gstin) + Number(g.address) + Number(g.route);
}

/**
 * What this lead is still missing, read **live**.
 *
 * Checked at the moment of approval and not against whatever the page was
 * loaded with: a rep may have filled the gaps minutes ago, and a manager
 * blocked by stale data will go and ask them for something they already did.
 */
async function checkLeadGaps(leadId: string): Promise<LeadGaps> {
  const lead = await getDoc<Record<string, unknown>>(DOCTYPE.lead, leadId);
  return {
    gstin: !isLinkSet(str(lead[LEAD_FIELD.gstin])),
    address: !isLinkSet(str(lead[LEAD_FIELD.address])),
    route: !isLinkSet(str(lead[LEAD_FIELD.route])),
  };
}

/**
 * Approve a lead order: convert the lead, raise the Sales Order, write back.
 *
 * The Sales Order is created **already approved**. The manager approving the
 * lead order is making exactly the decision they would make on a Sales Order,
 * and sending it back to their own queue would ask them to approve the same
 * order twice.
 *
 * A lead order carries no roll/belt breakdown and no bookings — `Lead Order
 * Item` holds only item, qty, rate and amount — so the Sales Order it raises
 * always reads as new production.
 *
 * **Not atomic, and cannot be.** With no server scripts these are three
 * separate writes. They are ordered so a failure leaves the least damage: the
 * customer exists before anything points at it, and the lead order is only
 * marked converted once the Sales Order is real. A partial run leaves an
 * unlinked Sales Order, which is visible and fixable; the reverse would leave
 * a lead order claiming an order that was never raised.
 */
async function approveLeadOrder(input: {
  leadOrderId: string;
}): Promise<{ customer: string; salesOrder: string; linkageStored: boolean }> {
  const lo = await getLeadOrder(input.leadOrderId);

  const gaps = await checkLeadGaps(lo.lead);
  if (gaps.gstin || gaps.address || gaps.route) {
    const missing = [
      gaps.gstin ? 'GST number' : null,
      gaps.address ? 'address' : null,
      gaps.route ? 'sales route' : null,
    ].filter(Boolean);
    throw new ApiError(
      `This lead becomes a customer on approval and is invoiced from there, so it still needs: ${missing.join(', ')}.`,
      412,
    );
  }

  const lead = await getDoc<Record<string, unknown>>(DOCTYPE.lead, lo.lead);
  const partyName = str(lead[LEAD_FIELD.leadName]) ?? lo.leadName;

  // 1. The customer.
  const customer = await createDoc<Record<string, unknown>>(DOCTYPE.customer, {
    customer_name: partyName,
    customer_type: 'Company',
    [SALES_CUSTOMER_FIELD.assignedRep]: lo.rep,
    [SALES_CUSTOMER_FIELD.route]: str(lead[LEAD_FIELD.route]),
    [SALES_CUSTOMER_FIELD.gstin]: str(lead[LEAD_FIELD.gstin]),
    [SALES_CUSTOMER_FIELD.latitude]: Number(lead[LEAD_FIELD.latitude]) || undefined,
    [SALES_CUSTOMER_FIELD.longitude]: Number(lead[LEAD_FIELD.longitude]) || undefined,
    [SALES_CUSTOMER_FIELD.locationStatus]: str(lead[LEAD_FIELD.locationStatus]),
  });
  const customerId = String(customer.name);

  // 2. The Sales Order, created already approved.
  const so = await createDoc<Record<string, unknown>>(DOCTYPE.salesOrder, {
    customer: customerId,
    transaction_date: lo.orderDate,
    delivery_date: lo.orderDate,
    [SALES_ORDER_FIELD.rep]: lo.rep,
    [SALES_ORDER_FIELD.poStatus]: PO_STATUS.approved,
    [SALES_ORDER_FIELD.ratesApproved]: 1,
    items: lo.lines.map((l) => ({
      item_code: l.itemCode,
      qty: l.qty,
      rate: l.rate,
      delivery_date: lo.orderDate,
      // No breakdown exists on the lead side, so the line is new production.
      [SALES_ORDER_ITEM_FIELD.fulfilmentMode]: FULFILMENT_MODE.newProduction,
      [SALES_ORDER_ITEM_FIELD.rateApproved]: 1,
    })),
  });
  const salesOrderId = String(so.name);

  /*
   * 3. Write back to the lead order.
   *
   * The handoff specifies a `sales_order` field here. **It does not exist on
   * this site** — the live `Lead Order` doctype has no such field — so the
   * linkage is recorded in `approval_remarks`, which does exist, and the
   * caller is told the structured link could not be stored.
   */
  await updateDoc(DOCTYPE.leadOrder, input.leadOrderId, {
    [LEAD_ORDER_FIELD.status]: LEAD_ORDER_STATUS.converted,
    [LEAD_ORDER_FIELD.approvalRemarks]: `Converted to customer ${customerId}, raised as ${salesOrderId}`,
  });

  return { customer: customerId, salesOrder: salesOrderId, linkageStored: false };
}

/** Reject a lead order. No conversion, nothing else touched. */
async function rejectLeadOrder(leadOrderId: string): Promise<void> {
  await updateDoc(DOCTYPE.leadOrder, leadOrderId, {
    [LEAD_ORDER_FIELD.status]: LEAD_ORDER_STATUS.rejected,
  });
}

// ------------------------------------------------------ combined orders ---

async function listCombinedOrders(input: { from?: string; to?: string } = {}): Promise<
  CombinedOrder[]
> {
  const filters: Filter[] = [];
  if (input.from && input.to) {
    filters.push([COMBINED_ORDER_FIELD.weekStart, 'between', [input.from, input.to]]);
  }
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.combinedOrder, {
    fields: ['name', ...Object.values(COMBINED_ORDER_FIELD)],
    filters,
    orderBy: `${COMBINED_ORDER_FIELD.weekStart} desc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.combinedOrder));

  return rows.map((r) => ({
    id: String(r.name),
    customer: str(r[COMBINED_ORDER_FIELD.customer]) ?? '',
    customerName:
      str(r[COMBINED_ORDER_FIELD.customerName]) ?? str(r[COMBINED_ORDER_FIELD.customer]) ?? '',
    weekStart: (str(r[COMBINED_ORDER_FIELD.weekStart]) ?? '').slice(0, 10),
    weekEnd: (str(r[COMBINED_ORDER_FIELD.weekEnd]) ?? '').slice(0, 10),
    status: str(r[COMBINED_ORDER_FIELD.status]) ?? '',
    orderCount: Number(r[COMBINED_ORDER_FIELD.orderCount]) || 0,
    total: Number(r[COMBINED_ORDER_FIELD.total]) || 0,
    groupedBy: str(r[COMBINED_ORDER_FIELD.groupedBy]),
  }));
}

/**
 * Orders eligible for grouping into a week's combined orders.
 *
 * All four conditions from the spec, and the `custom_combined_order` one is
 * checked in the client because Frappe writes an unset Link as `''` on one
 * path and `null` on another — a single `=` filter misses half of them.
 */
async function listGroupableOrders(week: { start: string; end: string }): Promise<TeamOrder[]> {
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.salesOrder, {
    fields: ['name', 'docstatus', ...Object.values(SALES_ORDER_FIELD)],
    filters: [
      [SALES_ORDER_FIELD.placedOn, 'between', [week.start, week.end]],
      [SALES_ORDER_FIELD.productionStatus, '=', PRODUCTION_STATUS.dispatched],
    ],
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.salesOrder));

  return rows
    .filter((r) => Number(r.docstatus) < 2 && !isLinkSet(str(r[SALES_ORDER_FIELD.combinedOrder])))
    .map(toTeamOrder);
}

/**
 * Group a week's completed orders, one `Combined Order` per customer.
 *
 * **Repeatable, never unwound.** Because already-grouped orders are excluded
 * from the eligible set, a run that fails halfway is finished by running it
 * again. There is deliberately no rollback: deleting a partially-populated
 * combined order risks pointing member orders at a record that no longer
 * exists, which is worse than the half-done state it was trying to tidy.
 *
 * Membership is written only to `Sales Order.custom_combined_order`. There is
 * no child table on `Combined Order`, on purpose — with no server scripts, two
 * records of the same fact drift the first time a save half-fails.
 */
async function closeWeek(input: {
  week: { start: string; end: string };
  groupedBy?: string;
}): Promise<{ groups: number; orders: number; failed: string[] }> {
  const eligible = await listGroupableOrders(input.week);

  const byCustomer = new Map<string, TeamOrder[]>();
  for (const o of eligible) {
    if (!o.customer) continue;
    const list = byCustomer.get(o.customer) ?? [];
    list.push(o);
    byCustomer.set(o.customer, list);
  }

  let groups = 0;
  let orders = 0;
  const failed: string[] = [];

  for (const [customer, list] of byCustomer) {
    try {
      const combined = await createDoc<Record<string, unknown>>(DOCTYPE.combinedOrder, {
        [COMBINED_ORDER_FIELD.customer]: customer,
        [COMBINED_ORDER_FIELD.weekStart]: input.week.start,
        [COMBINED_ORDER_FIELD.weekEnd]: input.week.end,
        [COMBINED_ORDER_FIELD.status]: 'Draft',
        [COMBINED_ORDER_FIELD.orderCount]: list.length,
        [COMBINED_ORDER_FIELD.total]: Math.round(list.reduce((s, o) => s + o.total, 0) * 100) / 100,
        // Usually null: a production manager is rarely a Sales Person. Omitted
        // rather than sent empty, so Frappe does not try to validate a Link
        // against a blank string.
        ...(input.groupedBy ? { [COMBINED_ORDER_FIELD.groupedBy]: input.groupedBy } : {}),
      });
      groups += 1;

      for (const o of list) {
        try {
          await updateDoc(DOCTYPE.salesOrder, o.id, {
            [SALES_ORDER_FIELD.combinedOrder]: String(combined.name),
          });
          orders += 1;
        } catch {
          failed.push(o.id);
        }
      }
    } catch {
      failed.push(`group for ${customer}`);
    }
  }

  return { groups, orders, failed };
}

// -------------------------------------------------------------- production ---

/**
 * The production queue — **with the customer removed before it is returned**.
 *
 * Production must never see who the order is for. The customer is used here
 * only to resolve a route, and is then dropped: it is not returned to the
 * caller in any field, so no screen can render it and no search can match it
 * even by accident.
 */
async function listProductionQueue(unit?: string): Promise<ProductionOrderRow[]> {
  const filters: Filter[] = [[SALES_ORDER_FIELD.poStatus, '=', PO_STATUS.approved]];
  if (unit) filters.push([SALES_ORDER_FIELD.unit, '=', unit]);

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.salesOrder, {
    fields: ['name', ...Object.values(SALES_ORDER_FIELD)],
    filters,
    orderBy: `${SALES_ORDER_FIELD.deliveryDate} asc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.salesOrder));

  // One lookup for the whole queue rather than one per order.
  const parties = await listSalesCustomers().catch(() => []);
  const routeOf = new Map(parties.map((c) => [c.id, c.route]));

  return rows.map((r) => {
    const customer = str(r[SALES_ORDER_FIELD.customer]) ?? '';
    const route = routeOf.get(customer);
    return {
      id: String(r.name),
      /*
       * "No route set" is correct and must not be improved on. This used to
       * fall back to `territory`, and since every customer sits in the single
       * territory "India", the floor was shown "India (no route set)" — a
       * string that reads like a destination, sorts like one, and is nowhere
       * you can drive. A blank cannot be mistaken for an answer.
       */
      route: isLinkSet(route) ? (route as string) : 'No route set',
      rep: str(r[SALES_ORDER_FIELD.rep]) ?? '',
      unit: str(r[SALES_ORDER_FIELD.unit]),
      placedOn: (str(r[SALES_ORDER_FIELD.placedOn]) ?? '').slice(0, 10),
      deliveryDate: (str(r[SALES_ORDER_FIELD.deliveryDate]) ?? '').slice(0, 10) || undefined,
      originalDeliveryDate:
        (str(r[SALES_ORDER_FIELD.originalDeliveryDate]) ?? '').slice(0, 10) || undefined,
      total: Number(r[SALES_ORDER_FIELD.total]) || 0,
      productionStatus: str(r[SALES_ORDER_FIELD.productionStatus]),
      productionFinishDate:
        (str(r[SALES_ORDER_FIELD.productionFinishDate]) ?? '').slice(0, 10) || undefined,
      changedAfterApproval: Number(r[SALES_ORDER_FIELD.changedAfterApproval]) === 1,
      combinedOrder: str(r[SALES_ORDER_FIELD.combinedOrder]),
    };
  });
}

/** One order for the floor: lines and stages, with the customer stripped. */
async function getOrderForProduction(
  id: string,
): Promise<ProductionOrderRow & { lines: OrderLine[] }> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.salesOrder, id);
  const customer = str(doc[SALES_ORDER_FIELD.customer]) ?? '';
  const parties = await listSalesCustomers().catch(() => []);
  const route = parties.find((c) => c.id === customer)?.route;

  const items = Array.isArray(doc.items) ? (doc.items as Record<string, unknown>[]) : [];
  return {
    id: String(doc.name),
    route: isLinkSet(route) ? (route as string) : 'No route set',
    rep: str(doc[SALES_ORDER_FIELD.rep]) ?? '',
    unit: str(doc[SALES_ORDER_FIELD.unit]),
    placedOn: (str(doc[SALES_ORDER_FIELD.placedOn]) ?? '').slice(0, 10),
    deliveryDate: (str(doc[SALES_ORDER_FIELD.deliveryDate]) ?? '').slice(0, 10) || undefined,
    originalDeliveryDate:
      (str(doc[SALES_ORDER_FIELD.originalDeliveryDate]) ?? '').slice(0, 10) || undefined,
    total: Number(doc[SALES_ORDER_FIELD.total]) || 0,
    productionStatus: str(doc[SALES_ORDER_FIELD.productionStatus]),
    productionFinishDate:
      (str(doc[SALES_ORDER_FIELD.productionFinishDate]) ?? '').slice(0, 10) || undefined,
    changedAfterApproval: Number(doc[SALES_ORDER_FIELD.changedAfterApproval]) === 1,
    combinedOrder: str(doc[SALES_ORDER_FIELD.combinedOrder]),
    lines: items.map(toOrderLine),
  };
}

/**
 * Set one line's production stage, and roll the order up to match.
 *
 * Two fields of different types are written together, and getting them the
 * wrong way round is fatal: the line's `custom_production_stage` is free text
 * and takes the fine stage name, while the order's `custom_production_status`
 * is a Select of four values and rejects anything else — taking the whole
 * update down with it, including the line change that was the point.
 */
async function setProductionStage(input: {
  orderId: string;
  lineId: string;
  stage: string;
  /**
   * Which half of the line moved. `stockStage` is the portion coming off the
   * shelf; `productionStage` is the portion being made. A split line has both
   * and they finish separately.
   */
  field?: 'stockStage' | 'productionStage';
}): Promise<ProductionOrderRow & { lines: OrderLine[] }> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.salesOrder, input.orderId);
  const items = Array.isArray(doc.items) ? (doc.items as Record<string, unknown>[]) : [];

  const target =
    input.field === 'stockStage'
      ? SALES_ORDER_ITEM_FIELD.stockStage
      : SALES_ORDER_ITEM_FIELD.productionStage;

  const nextItems = items.map((l) =>
    String(l.name) === input.lineId ? { ...l, [target]: input.stage } : l,
  );

  // The roll-up weighs BOTH halves of a split line, so it needs the live
  // reservations: four rolls dispatched off the shelf while four are still
  // being made is not a finished order.
  const reservations = await listStockReservations().catch(() => [] as StockReservationRow[]);
  const status = rollUp(
    nextItems.map((l) => {
      const code = str(l.item_code) ?? '';
      const held = heldBy(reservations, code, input.orderId);
      const rolls = Number(l[SALES_ORDER_ITEM_FIELD.rolls]) || 0;
      const belts = Number(l[SALES_ORDER_ITEM_FIELD.looseBelts]) || 0;
      return {
        category: str(l[SALES_ORDER_ITEM_FIELD.category]),
        fulfilmentMode: str(l[SALES_ORDER_ITEM_FIELD.fulfilmentMode]),
        productionStage: str(l[SALES_ORDER_ITEM_FIELD.productionStage]),
        stockStage: str(l[SALES_ORDER_ITEM_FIELD.stockStage]),
        reservedRolls: held.rolls,
        reservedBelts: held.belts,
        toMakeRolls: Math.max(0, rolls - held.rolls),
        toMakeBelts: Math.max(0, belts - held.belts),
        splitKnown: true,
      };
    }),
  );

  await updateDoc(DOCTYPE.salesOrder, input.orderId, {
    items: nextItems,
    [SALES_ORDER_FIELD.productionStatus]: status,
  });
  return getOrderForProduction(input.orderId);
}

/**
 * Move an order's delivery date.
 *
 * Writes `delivery_date`, and captures the previous value into
 * `custom_original_delivery_date` **the first time only**. Without that
 * capture the new date is just a number and nobody — including whoever moved
 * it — can see that it moved, or from what. Overwriting it on a second move
 * would lose what the customer actually asked for.
 *
 * `custom_order_placed_at` is deliberately never sent: the moment the order
 * was raised is not production's to move, and every deadline measures from it.
 */
async function moveDeliveryDate(input: {
  orderId: string;
  date: string;
}): Promise<ProductionOrderRow & { lines: OrderLine[] }> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.salesOrder, input.orderId);
  const current = (str(doc[SALES_ORDER_FIELD.deliveryDate]) ?? '').slice(0, 10);
  const alreadyCaptured = isLinkSet(str(doc[SALES_ORDER_FIELD.originalDeliveryDate]));

  const body: Record<string, unknown> = { [SALES_ORDER_FIELD.deliveryDate]: input.date };
  if (!alreadyCaptured && current) {
    body[SALES_ORDER_FIELD.originalDeliveryDate] = current;
  }

  await updateDoc(DOCTYPE.salesOrder, input.orderId, body);
  return getOrderForProduction(input.orderId);
}

/** Clear the "edited after approval" flag once the floor has taken it in. */
async function acknowledgeProductionChange(orderId: string): Promise<void> {
  await updateDoc(DOCTYPE.salesOrder, orderId, {
    [SALES_ORDER_FIELD.changedAfterApproval]: 0,
  });
}

// ===========================================================================
// TRIPS, EXPENSES AND ODOMETER VERIFICATION
// ===========================================================================

/** Per-km rates. A Single, so it is fetched by name, never listed. */
async function getTripRates(): Promise<TripRates> {
  const doc = await getDoc<Record<string, unknown>>(
    DOCTYPE.tripRateSettings,
    DOCTYPE.tripRateSettings,
  ).catch(() => null);
  if (!doc) return RATE_FALLBACK;
  const n = (k: string) => Number(doc[k]) || 0;
  return {
    ownCar: n(TRIP_RATE_FIELD.ownCar),
    ownBike: n(TRIP_RATE_FIELD.ownBike),
    companyCar: n(TRIP_RATE_FIELD.companyCar),
    companyBike: n(TRIP_RATE_FIELD.companyBike),
    mixed: n(TRIP_RATE_FIELD.mixed),
  };
}

function toLeg(r: Record<string, unknown>): TripLeg {
  const n = (k: string) => Number(r[k]) || 0;
  return {
    id: String(r.name),
    mode: str(r[TRIP_LEG_FIELD.mode]) ?? '',
    vehicleNo: str(r[TRIP_LEG_FIELD.vehicleNo]),
    hasOdometer: Number(r[TRIP_LEG_FIELD.hasOdometer]) === 1,
    startOdometer: n(TRIP_LEG_FIELD.startOdometer),
    endOdometer: n(TRIP_LEG_FIELD.endOdometer),
    distanceKm: n(TRIP_LEG_FIELD.distanceKm),
    startOdometerPhoto: str(r[TRIP_LEG_FIELD.startOdometerPhoto]),
    endOdometerPhoto: str(r[TRIP_LEG_FIELD.endOdometerPhoto]),
    notVerified: Number(r[TRIP_LEG_FIELD.notVerified]) === 1,
    actualStartOdometer: n(TRIP_LEG_FIELD.actualStartOdometer),
    actualEndOdometer: n(TRIP_LEG_FIELD.actualEndOdometer),
    claimedAmount: n(TRIP_LEG_FIELD.claimedAmount),
    approvedAmount: n(TRIP_LEG_FIELD.approvedAmount),
    status: str(r[TRIP_LEG_FIELD.status]),
    remarks: str(r[TRIP_LEG_FIELD.remarks]),
  };
}

function toTripExpense(r: Record<string, unknown>): TripExpense {
  return {
    id: String(r.name),
    category: str(r[TRIP_EXPENSE_FIELD.category]) ?? '',
    expenseName: str(r[TRIP_EXPENSE_FIELD.expenseName]),
    amount: Number(r[TRIP_EXPENSE_FIELD.amount]) || 0,
    approvedAmount: Number(r[TRIP_EXPENSE_FIELD.approvedAmount]) || 0,
    hasBill: Number(r[TRIP_EXPENSE_FIELD.hasBill]) === 1,
    billPhoto: str(r[TRIP_EXPENSE_FIELD.billPhoto]),
    status: str(r[TRIP_EXPENSE_FIELD.status]),
    remarks: str(r[TRIP_EXPENSE_FIELD.remarks]),
  };
}

function toTrip(r: Record<string, unknown>): Trip {
  const legs = Array.isArray(r.legs) ? (r.legs as Record<string, unknown>[]).map(toLeg) : [];
  const expenses = Array.isArray(r.expenses)
    ? (r.expenses as Record<string, unknown>[]).map(toTripExpense)
    : [];
  return {
    id: String(r.name),
    person: str(r[TRIP_FIELD.person]) ?? '',
    date: (str(r[TRIP_FIELD.date]) ?? '').slice(0, 10),
    startTime: str(r[TRIP_FIELD.startTime]),
    endTime: str(r[TRIP_FIELD.endTime]),
    primaryMode: str(r[TRIP_FIELD.primaryMode]) ?? '',
    costBasis: str(r[TRIP_FIELD.costBasis]),
    distanceKm: Number(r[TRIP_FIELD.distanceKm]) || 0,
    estimatedCost: Number(r[TRIP_FIELD.estimatedCost]) || 0,
    totalExpenses: Number(r[TRIP_FIELD.totalExpenses]) || 0,
    status: str(r[TRIP_FIELD.status]) ?? '',
    expenseStatus: str(r[TRIP_FIELD.expenseStatus]),
    purpose: str(r[TRIP_FIELD.purpose]),
    taggedReps: parseTagged(str(r[TRIP_FIELD.taggedCsv])),
    legs,
    expenses,
  };
}

/**
 * Trips in a date range, with their child tables.
 *
 * A list query cannot return child tables, so this lists the names in range
 * and then fetches each document. Bounded by the range rather than paginated:
 * a month is a few dozen trips, and the caller always wants the whole month.
 */
async function listTrips(fromIso: string, toIso: string): Promise<Trip[]> {
  const rows = await listDocs<{ name: string }>(DOCTYPE.trip, {
    fields: ['name'],
    filters: [
      [TRIP_FIELD.date, '>=', fromIso],
      [TRIP_FIELD.date, '<=', toIso],
    ],
    orderBy: `${TRIP_FIELD.date} asc`,
    limit: 0,
  }).catch(ifMissing<{ name: string }[]>([], DOCTYPE.trip));

  const docs = await Promise.all(
    rows.map((r) =>
      getDoc<Record<string, unknown>>(DOCTYPE.trip, r.name).catch(() => null),
    ),
  );
  return docs.filter(Boolean).map((d) => toTrip(d as Record<string, unknown>));
}

/** One trip with its child tables, for the detail view. */
async function getTrip(tripId: string): Promise<Trip> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.trip, tripId);
  return toTrip(doc);
}

/**
 * Everywhere a trip is known to have been, in time order.
 *
 * Assembled from three sources because no single one is a track:
 *
 *   - the trip's own `start_*`/`end_*` fixes — where the rep punched in and out,
 *   - the `Sales Visit` rows against the trip, resolved to the verified
 *     coordinates of the customer or lead they name,
 *   - any `gps_points` samples, plotted but never joined into the route.
 *
 * The visits are the substance. `Trip.gps_points` sounds like a breadcrumb
 * trail and is not: TRP-00250 claims 179 km and holds one point.
 *
 * Coordinates come from the **verified** fields first. Those are what a
 * manager signed off and what the 100 m punch-in check measures against; the
 * captured pair is whatever the phone reported and may never have been looked
 * at.
 */
async function getTripTrack(tripId: string): Promise<TripTrack> {
  const [doc, visits] = await Promise.all([
    getDoc<Record<string, unknown>>(DOCTYPE.trip, tripId),
    listVisitsForTrip(tripId),
  ]);

  const wantCustomers = [...new Set(visits.map((v) => v.customerId).filter(Boolean))] as string[];
  const wantLeads = [...new Set(visits.map((v) => v.leadId).filter(Boolean))] as string[];

  const [customers, leads] = await Promise.all([
    wantCustomers.length
      ? listDocs<Record<string, unknown>>(DOCTYPE.customer, {
          fields: ['name', ...Object.values(SALES_CUSTOMER_FIELD)],
          filters: [['name', 'in', wantCustomers]],
          limit: 0,
        }).catch(() => [] as Record<string, unknown>[])
      : Promise.resolve([] as Record<string, unknown>[]),
    wantLeads.length
      ? listDocs<Record<string, unknown>>(DOCTYPE.lead, {
          fields: ['name', ...Object.values(LEAD_FIELD)],
          filters: [['name', 'in', wantLeads]],
          limit: 0,
        }).catch(() => [] as Record<string, unknown>[])
      : Promise.resolve([] as Record<string, unknown>[]),
  ]);

  /** Verified coordinates win; the captured pair is the fallback. */
  const place = (
    r: Record<string, unknown>,
    f: { verifiedLatitude: string; verifiedLongitude: string; latitude: string; longitude: string },
  ) => {
    const vLat = Number(r[f.verifiedLatitude]);
    const vLng = Number(r[f.verifiedLongitude]);
    if (Number.isFinite(vLat) && Number.isFinite(vLng) && (vLat !== 0 || vLng !== 0)) {
      return { latitude: vLat, longitude: vLng };
    }
    const lat = Number(r[f.latitude]);
    const lng = Number(r[f.longitude]);
    return { latitude: lat, longitude: lng };
  };

  const byCustomer = new Map(
    customers.map((c) => [
      String(c.name),
      {
        name: str(c[SALES_CUSTOMER_FIELD.customerName]) ?? String(c.name),
        ...place(c, SALES_CUSTOMER_FIELD as never),
      },
    ]),
  );
  const byLead = new Map(
    leads.map((l) => [
      String(l.name),
      {
        name: str(l[LEAD_FIELD.leadName]) ?? String(l.name),
        ...place(l, LEAD_FIELD as never),
      },
    ]),
  );

  const stops = visits.map((visit) => {
    const found = visit.customerId
      ? byCustomer.get(visit.customerId)
      : visit.leadId
        ? byLead.get(visit.leadId)
        : undefined;
    return {
      visit,
      name: found?.name ?? visit.customerId ?? visit.leadId ?? 'Unknown party',
      place: found ? { latitude: found.latitude, longitude: found.longitude } : undefined,
    };
  });

  const gps = Array.isArray(doc.gps_points) ? (doc.gps_points as Record<string, unknown>[]) : [];

  return {
    trip: toTrip(doc),
    start: {
      latitude: Number(doc.start_latitude) || 0,
      longitude: Number(doc.start_longitude) || 0,
      at: str(doc.start_time),
    },
    end: {
      latitude: Number(doc.end_latitude) || 0,
      longitude: Number(doc.end_longitude) || 0,
      at: str(doc.end_time),
    },
    stops,
    gpsPoints: gps.map((g) => ({
      latitude: Number(g.latitude) || 0,
      longitude: Number(g.longitude) || 0,
      at: str(g.timestamp),
    })),
  };
}

/** Shop visits recorded against one trip. */
async function listVisitsForTrip(tripId: string): Promise<SalesVisit[]> {
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.salesVisit, {
    fields: ['name', ...Object.values(SALES_VISIT_FIELD)],
    filters: [[SALES_VISIT_FIELD.trip, '=', tripId]],
    orderBy: `${SALES_VISIT_FIELD.checkIn} asc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.salesVisit));
  return rows.map(toSalesVisit);
}

function toSalesVisit(r: Record<string, unknown>): SalesVisit {
  return {
    id: String(r.name),
    person: str(r[SALES_VISIT_FIELD.person]) ?? '',
    date: (str(r[SALES_VISIT_FIELD.date]) ?? '').slice(0, 10),
    tripId: str(r[SALES_VISIT_FIELD.trip]),
    leadId: str(r[SALES_VISIT_FIELD.lead]),
    customerId: str(r[SALES_VISIT_FIELD.customer]),
    checkIn: str(r[SALES_VISIT_FIELD.checkIn]),
    checkOut: str(r[SALES_VISIT_FIELD.checkOut]),
    durationMinutes: Number(r[SALES_VISIT_FIELD.durationMinutes]) || 0,
    purpose: str(r[SALES_VISIT_FIELD.purpose]),
    status: str(r[SALES_VISIT_FIELD.status]),
  };
}

async function listSalesVisits(fromIso: string, toIso: string): Promise<SalesVisit[]> {
  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.salesVisit, {
    fields: ['name', ...Object.values(SALES_VISIT_FIELD)],
    filters: [
      [SALES_VISIT_FIELD.date, '>=', fromIso],
      [SALES_VISIT_FIELD.date, '<=', toIso],
    ],
    orderBy: `${SALES_VISIT_FIELD.date} desc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.salesVisit));

  return rows.map(toSalesVisit);
}

export interface VerifyLegInput {
  tripId: string;
  legId: string;
  /**
   * `verified` — the photo agrees with what the rep typed. The typed figures
   *   are copied into the actual-reading fields so the expense sheet can show
   *   that somebody looked, rather than leaving a blank that reads the same as
   *   never having been checked.
   * `corrected` — the photo disagrees; `actualStart`/`actualEnd` are HR's.
   * `clear` — undo, back to unchecked.
   */
  outcome: 'verified' | 'corrected' | 'clear';
  actualStart?: number;
  actualEnd?: number;
  remarks?: string;
}

/**
 * Record HR's odometer check.
 *
 * `Trip Vehicle Leg` is a child table, so it cannot be written directly —
 * Frappe only accepts child rows through their parent. The whole `legs` array
 * is therefore re-sent with the one leg amended, which is also why the read
 * happens immediately before the write rather than from cached state: another
 * leg may have been checked in between, and re-sending stale rows would
 * quietly revert someone else's work.
 */
async function verifyLeg(input: VerifyLegInput): Promise<Trip> {
  const doc = await getDoc<Record<string, unknown>>(DOCTYPE.trip, input.tripId);
  const legs = Array.isArray(doc.legs) ? (doc.legs as Record<string, unknown>[]) : [];

  const next = legs.map((l) => {
    if (String(l.name) !== input.legId) return l;

    // "Verified" means the photo matched, so the confirmed readings ARE the
    // typed ones — written through rather than left blank.
    const typedStart = Number(l[TRIP_LEG_FIELD.startOdometer]) || 0;
    const typedEnd = Number(l[TRIP_LEG_FIELD.endOdometer]) || 0;

    let notVerified = 0;
    let actualStart = 0;
    let actualEnd = 0;
    if (input.outcome === 'verified') {
      actualStart = typedStart;
      actualEnd = typedEnd;
    } else if (input.outcome === 'corrected') {
      notVerified = 1;
      actualStart = input.actualStart ?? 0;
      actualEnd = input.actualEnd ?? 0;
    }

    return {
      ...l,
      [TRIP_LEG_FIELD.notVerified]: notVerified,
      [TRIP_LEG_FIELD.actualStartOdometer]: actualStart,
      [TRIP_LEG_FIELD.actualEndOdometer]: actualEnd,
      [TRIP_LEG_FIELD.remarks]: input.remarks ?? l[TRIP_LEG_FIELD.remarks] ?? '',
    };
  });

  const saved = await updateDoc<Record<string, unknown>>(DOCTYPE.trip, input.tripId, {
    legs: next,
  });
  return toTrip(saved);
}

async function listEmployees(): Promise<Employee[]> {
  if (USE_MOCK) return delay(getDb().employees, 80);

  const rows = await listDocs<Record<string, unknown>>(DOCTYPE.employee, {
    fields: [
      'name',
      ...Object.values(EMPLOYEE_FIELD),
    ],
    orderBy: `${EMPLOYEE_FIELD.employeeName} asc`,
    limit: 0,
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.employee));

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
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.attendance));

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
  }).catch(ifMissing<{ name: string }[]>([], DOCTYPE.attendance));

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
  }).catch(ifMissing<Record<string, unknown>[]>([], DOCTYPE.leaveApplication));

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
    // Absent on this site; `toEmploymentType` supplies its own default.
    employmentType: toEmploymentType(str(row[OPTIONAL_EMPLOYEE_FIELD.employmentType])),
    joinedOn: (str(row[EMPLOYEE_FIELD.joinedOn]) ?? nowIso()).slice(0, 10),
    // ERPNext keeps a relieving date on some active records; `status` is what
    // actually decides whether someone is still on the books.
    leftOn: str(row[EMPLOYEE_FIELD.status]) === 'Active' ? undefined : relieved?.slice(0, 10),
    phone: str(row[EMPLOYEE_FIELD.phone]),
    email: str(row[EMPLOYEE_FIELD.email]),
    location: str(row[EMPLOYEE_FIELD.branch]),
    reportsTo: str(row[EMPLOYEE_FIELD.reportsTo]),
    userId: str(row[EMPLOYEE_FIELD.user]),
    leaveBalance: Number(row[OPTIONAL_EMPLOYEE_FIELD.leaveBalance] ?? 0) || 0,
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

  /**
   * The real HR surface on this site — see `domain/attendance.ts`. Reads only;
   * approvals will be added here once the two-stage leave fields exist.
   */
  trips: {
    getRates: getTripRates,
    list: listTrips,
    get: getTrip,
    listVisitsForTrip,
    getTrack: getTripTrack,
    listVisits: listSalesVisits,
    verifyLeg,
  },

  sales: {
    listCustomers: listSalesCustomers,
    listOrders: listTeamOrders,
    getOrder: getSalesOrder,
    decideOrder: decideSalesOrder,
    setLineDiscount,
    listMinimumStock,
    recordProductionRun,
    claimFromRun,
    setRunStage,
    receiveRun,
    listReservations: listStockReservations,
    listItemOptions,
    setFulfilmentMode,
    saveOrderLines,
    listLeadOrders,
    getLeadOrder,
    checkLeadGaps,
    approveLeadOrder,
    rejectLeadOrder,
    listCombinedOrders,
    listGroupableOrders,
    closeWeek,
    listApprovalInbox,
    decideInboxItem,
    captureLocation,
    listLeads,
    listRoutesFor,
    assignRoute,
    decideLocation,
    listLocationQueue,
  },

  production: {
    listQueue: listProductionQueue,
    getOrder: getOrderForProduction,
    setStage: setProductionStage,
    moveDeliveryDate,
    acknowledgeChange: acknowledgeProductionChange,
  },

  attendance: {
    listSalesPeople,
    listAttendanceLogs,
    listLeaveRequests: listLeaveRequestsLive,
    listRegularizations,
    decideLeave: decideLeaveRequest,
    revokeLeave: revokeLeaveDecision,
    decideRegularization,
    revokeRegularization,
    applyRegularization,
    setAttendance: upsertAttendanceLog,
  },
} as const;

export default Api;
