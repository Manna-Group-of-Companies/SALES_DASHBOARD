/**
 * Domain vocabulary for the Sales module.
 *
 * Everything here is plain data. No React, no Redux, no Axios — so the rules in
 * the sibling modules can be reasoned about (and unit-tested) on their own.
 */

// ---------------------------------------------------------------- roles ---

/**
 * Roles that can sign in *here*.
 *
 * Sales Reps are deliberately absent: they work in the field-sales app, which
 * is where orders are raised. This module picks those orders up from the same
 * ERPNext site and takes them from approval through to dispatch, so a rep has
 * nothing to do in it and no login for it.
 */
export type Role =
  | 'sales_manager'
  | 'production_manager'
  | 'stock_manager'
  | 'hr';

export const ROLE_LABEL: Record<Role, string> = {
  sales_manager: 'Sales Manager',
  production_manager: 'Production Manager',
  stock_manager: 'Stock Manager',
  hr: 'HR',
};

/**
 * Who can appear on an order's audit trail.
 *
 * A superset of `Role`, because an order arrives here with the rep's own
 * entries already on it. `sales_rep` is therefore something this app *renders*
 * but can never *authenticate as* — keeping it out of `Role` is what stops a
 * rep identity leaking into a permission check.
 */
export type ActorRole = Role | 'sales_rep';

export const ACTOR_ROLE_LABEL: Record<ActorRole, string> = {
  ...ROLE_LABEL,
  sales_rep: 'Sales Rep',
};

export interface User {
  id: string;
  name: string;
  email: string;
  role: Role;
  /**
   * ERPNext `Sales Person` this login maps to, when it has one. Managers who
   * also carry a Sales Person record keep it; it is read for the linked
   * company, not for order ownership.
   */
  salesPerson?: string;
  /** Production unit (ERPNext company). Production/stock managers only. */
  productionUnit?: string;
}

// ------------------------------------------------------------- products ---

/**
 * The four product families. Each one prices and measures differently, which is
 * why category drives nearly every branch in `productRules`.
 */
export type ProductCategory = 'PCTR' | 'CTR' | 'BG' | 'VS';

export const CATEGORY_LABEL: Record<ProductCategory, string> = {
  PCTR: 'Precured Tread Rubber',
  CTR: 'Conventional Tread Rubber',
  BG: 'Bonding Gum',
  VS: 'Vulcanizing Solution',
};

/** Vulcanizing Solution ships in two tin sizes, each priced separately (1.5). */
export type TinSize = 10 | 30;

export interface Product {
  /** ERPNext `Item.name` / item_code. */
  code: string;
  name: string;
  category: ProductCategory;
  size?: string;
  /** PCTR: the *average* weight of one roll, in kg (1.2). */
  avgWeightPerRoll?: number;
  /** PCTR: how many belts one roll yields (1.2). */
  beltsPerRoll?: number;
  /** CTR: the *exact* weight of one roll, in kg (1.3). */
  exactWeightPerRoll?: number;
  /** VS: tin volume in litres — 10 or 30 (1.5). */
  tinSize?: TinSize;
  /** VS / BG: default selling rate. Reps still key PCTR/CTR rates by hand. */
  defaultRate?: number;
  hsnCode?: string;
  active: boolean;
}

// -------------------------------------------------------- minimum stock ---

/**
 * One dated intake of an item. Aging (1.6) is tracked per batch so a rep can be
 * told "8 of these are from the older lot, clear those first".
 */
export interface StockBatch {
  id: string;
  /** ISO date the batch was stocked in. */
  stockedOn: string;
  /** Quantity still on the shelf from this batch, in the item's stock UOM. */
  remaining: number;
  /** Quantity this batch was stocked with. */
  original: number;
}

export interface MinStockItem {
  itemCode: string;
  itemName: string;
  category: ProductCategory;
  uom: string;
  /** The threshold the Production Manager must keep this item above (3.5). */
  threshold: number;
  /** Physically on the shelf, across every batch. */
  onHand: number;
  /**
   * Held by draft/unapproved orders. Subtracted from `onHand` to give the
   * quantity another rep may still sell (1.2).
   */
  reserved: number;
  batches: StockBatch[];
  /** Set while a replenishment production order is open (3.5). */
  replenishmentRaised?: boolean;
  lastRestockedOn?: string;
}

/** A live hold placed by a rep the moment they key a quantity (1.2). */
export interface StockReservation {
  id: string;
  itemCode: string;
  qty: number;
  orderId: string | null;
  repId: string;
  repName: string;
  /** ISO timestamp. Soft holds on unsaved drafts expire; see minStock.service. */
  heldAt: string;
}

// --------------------------------------------------------------- orders ---

export type OrderStatus =
  | 'draft'
  | 'pending_approval'
  | 'approved'
  | 'in_production'
  | 'dispatched'
  | 'grouped'
  | 'rejected';

export const ORDER_STATUS_LABEL: Record<OrderStatus, string> = {
  draft: 'Draft',
  pending_approval: 'Pending Approval',
  approved: 'Approved',
  in_production: 'In Production',
  dispatched: 'Dispatched',
  grouped: 'Weekly Group',
  rejected: 'Rejected',
};

/** Where the goods come from — the Sales Manager's call, per order (2.3). */
export type FulfilmentSource = 'min_stock' | 'new_production';

export interface OrderItem {
  id: string;
  itemCode: string;
  itemName: string;
  category: ProductCategory;

  // --- what the rep keys, by category -------------------------------------
  /** PCTR + CTR. */
  rolls?: number;
  /** PCTR only — CTR has no loose-belt option (1.3). */
  looseBelts?: number;
  /** BG — must be a multiple of 5 kg (1.4). */
  kg?: number;
  /** VS — number of tins of `tinSize` (1.5). */
  tins?: number;
  tinSize?: TinSize;

  // --- derived, via productRules.computeLine ------------------------------
  /** Billable quantity in the item's own UOM (kg for PCTR/CTR/BG, L for VS). */
  quantity: number;
  uom: string;

  // --- money ---------------------------------------------------------------
  /** What the rep quoted. Per kg for PCTR/CTR/BG, per tin for VS. */
  quotedRate: number;
  /**
   * What the Sales Manager settled on. Once this is set the rate is frozen for
   * good, for everyone (2.2).
   */
  finalRate?: number;
  rateLocked: boolean;

  // --- fulfilment ----------------------------------------------------------
  source?: FulfilmentSource;
  /** Set when a rep/manager swapped this line onto an aged batch (1.6, 2.1). */
  agedBatchId?: string;
  /** Per-item process cycle position (3.2). */
  stage?: string;
  stageUpdatedAt?: string;
}

export interface Order {
  id: string;
  /** Human-facing number, e.g. `SO-2026-00042`. */
  orderNo: string;

  customerId: string;
  customerName: string;
  /** Shown to production in place of the customer's identity (3.1). */
  destination: string;

  /**
   * Who raised it. Usually a field-sales rep with no login here, so treat this
   * as attribution to display — never as a user to resolve or notify.
   */
  repId: string;
  repName: string;

  status: OrderStatus;
  items: OrderItem[];

  /** Requested by the rep (1.7). Drives the edit-freeze deadline (3.3). */
  deliveryDate: string;
  /**
   * Immutable. Captured at creation and carried untouched through the whole
   * lifecycle — production may never alter it (1.7, 3.2).
   */
  createdAt: string;

  /** Set by production when it moves the date; surfaced back to the rep (3.2). */
  revisedDeliveryDate?: string;
  deliveryDateHistory?: DeliveryDateChange[];

  approvedAt?: string;
  approvedBy?: string;
  rejectionReason?: string;

  proformaGenerated: boolean;
  proformaNo?: string;

  /** Set once every line has been dispatched. */
  dispatchedAt?: string;
  /** Weekly compilation this order was folded into (3.4). */
  weeklyGroupId?: string;

  notes?: string;
  timeline: TimelineEntry[];
}

export interface DeliveryDateChange {
  from: string;
  to: string;
  changedAt: string;
  changedBy: string;
  reason: string;
}

/** Append-only audit trail. Every screen reads the same one. */
export interface TimelineEntry {
  id: string;
  at: string;
  actorId: string;
  actorName: string;
  /** May be `sales_rep` — those entries come in with the order (see `ActorRole`). */
  actorRole: ActorRole;
  action: string;
  detail?: string;
  /** Marks a post-approval edit production must acknowledge (3.3). */
  requiresAck?: boolean;
  ackedAt?: string;
  ackedBy?: string;
}

// -------------------------------------------------------------- weekly ---

export interface WeeklyGroup {
  id: string;
  customerId: string;
  customerName: string;
  /** ISO date of the Monday. */
  weekStart: string;
  weekEnd: string;
  orderIds: string[];
  compiledAt: string;
  compiledBy: string;
  totalValue: number;
}

// ------------------------------------------------------- notifications ---

export type NotificationKind =
  | 'order_submitted'
  | 'order_approved'
  | 'order_rejected'
  | 'order_edited_post_approval'
  | 'delivery_date_changed'
  | 'stage_advanced'
  | 'order_dispatched'
  | 'orders_grouped'
  | 'min_stock_low'
  | 'min_stock_replenished'
  | 'edit_freeze_imminent'
  | 'leave_applied'
  | 'leave_decided'
  | 'attendance_unmarked';

export type NotificationSeverity = 'info' | 'warning' | 'critical';

export interface AppNotification {
  id: string;
  kind: NotificationKind;
  severity: NotificationSeverity;
  title: string;
  body: string;
  /** Which roles this lands in front of. */
  audience: Role[];
  /** Narrow further to one person when the message is personal. */
  audienceUserId?: string;
  orderId?: string;
  itemCode?: string;
  createdAt: string;
  readAt?: string;
  /**
   * Critical alerts (post-approval edits) stay on screen until the recipient
   * explicitly acknowledges them, so a floor change can't be scrolled past.
   */
  requiresAck?: boolean;
  ackedAt?: string;
}

// ------------------------------------------------------------ customers ---

export interface Customer {
  id: string;
  name: string;
  /** Delivery destination shown to production (3.1). */
  destination: string;
  address: string;
  gstin: string;
  state: string;
  phone?: string;
  email?: string;
  outstandingBalance: number;
  creditLimit: number;
  assignedReps: string[];
}

// -------------------------------------------------- production orders ---

export interface ProductionOrder {
  id: string;
  itemCode: string;
  itemName: string;
  qty: number;
  raisedAt: string;
  raisedBy: string;
  status: 'open' | 'completed';
  completedAt?: string;
  /** Priority replenishment for a below-threshold min-stock item (3.5). */
  reason: 'replenishment' | 'order';
  sourceOrderId?: string;
}

// ------------------------------------------------------------------- hr ---

/**
 * People, attendance and leave.
 *
 * Modelled on the three ERPNext HR doctypes this maps onto — `Employee`,
 * `Attendance` and `Leave Application` — so the mock backend and a real site
 * describe the same thing. An employee is *not* a `User`: most of the floor has
 * no login at all, and the ones who do are joined by `userId`.
 */

export type Department = 'Sales' | 'Production' | 'Stock' | 'Accounts' | 'Administration';

export const DEPARTMENTS: Department[] = [
  'Sales',
  'Production',
  'Stock',
  'Accounts',
  'Administration',
];

export type EmploymentType = 'permanent' | 'contract' | 'apprentice';

export const EMPLOYMENT_TYPE_LABEL: Record<EmploymentType, string> = {
  permanent: 'Permanent',
  contract: 'Contract',
  apprentice: 'Apprentice',
};

export interface Employee {
  /** ERPNext `Employee.name`, e.g. `HR-EMP-00012`. */
  id: string;
  name: string;
  designation: string;
  department: Department;
  employmentType: EmploymentType;
  /** ISO date of joining. Drives tenure and the anniversary list. */
  joinedOn: string;
  /** Set once they leave. Anyone with this set is out of the headcount. */
  leftOn?: string;
  phone?: string;
  email?: string;
  /** Which unit or branch they work out of. */
  location?: string;
  /** `Employee.id` of their reporting manager. */
  reportsTo?: string;
  /** The login this person maps to, for the few who have one. */
  userId?: string;
  /** Paid leave still available this year, in days. */
  leaveBalance: number;
}

export type AttendanceStatus = 'present' | 'absent' | 'on_leave' | 'half_day' | 'holiday';

export const ATTENDANCE_LABEL: Record<AttendanceStatus, string> = {
  present: 'Present',
  absent: 'Absent',
  on_leave: 'On Leave',
  half_day: 'Half Day',
  holiday: 'Holiday',
};

/** One row per employee per day — the same grain as ERPNext `Attendance`. */
export interface AttendanceRecord {
  id: string;
  employeeId: string;
  /** ISO date. */
  date: string;
  status: AttendanceStatus;
  /** `HH:MM`, local. Absent and leave rows carry neither. */
  checkIn?: string;
  checkOut?: string;
  markedBy?: string;
  note?: string;
}

export type LeaveType = 'casual' | 'sick' | 'earned' | 'unpaid';

export const LEAVE_TYPE_LABEL: Record<LeaveType, string> = {
  casual: 'Casual Leave',
  sick: 'Sick Leave',
  earned: 'Earned Leave',
  unpaid: 'Unpaid Leave',
};

export type LeaveStatus = 'pending' | 'approved' | 'rejected' | 'cancelled';

export const LEAVE_STATUS_LABEL: Record<LeaveStatus, string> = {
  pending: 'Pending',
  approved: 'Approved',
  rejected: 'Rejected',
  cancelled: 'Cancelled',
};

export interface LeaveRequest {
  id: string;
  employeeId: string;
  /** Denormalised so the queue renders without a second lookup. */
  employeeName: string;
  department: Department;
  type: LeaveType;
  fromDate: string;
  toDate: string;
  /** Working days claimed. Sundays are not counted; a half day counts 0.5. */
  days: number;
  reason: string;
  status: LeaveStatus;
  appliedAt: string;
  decidedAt?: string;
  decidedBy?: string;
  decisionNote?: string;
}
