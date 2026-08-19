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
  | 'general_manager'
  | 'production_manager'
  | 'stock_manager'
  | 'hr';

export const ROLE_LABEL: Record<Role, string> = {
  sales_manager: 'Sales Manager',
  general_manager: 'General Manager',
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
  /**
   * The team token this login manages — `Pareeth`, `Saneesh`, `Renjith` — from
   * `User.custom_managed_team`.
   *
   * Held separately from `role` because the two are not the same question.
   * `renjith@mannauae.com` carries `custom_is_production_manager = 1` *and*
   * manages the UAE sales team; role resolution picks production because it is
   * checked first, and without this field he could never reach a sales screen
   * even though five reps report to him. A role is what someone mainly is; this
   * is a capability they also hold.
   */
  managedTeam?: string;
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
  /**
   * PCTR: the weight of one *belt*, in kg (1.2).
   *
   * ERPNext holds this in `custom_avg_weight_per_roll`, whose name is wrong.
   * The live master settles it — `field x belts_per_roll = roll weight` on
   * every row (10.1 x 4 = 40.4; 2.4 x 14 = 33.6). The name is left alone on
   * the site because every import sheet uses it, so it is corrected here, at
   * the model boundary, and nowhere else. Read as a roll weight it prices a
   * 40.4 kg roll at 10.1 kg — about a quarter of the money.
   */
  weightPerBelt?: number;
  /**
   * PCTR: how many belts one roll yields (1.2).
   *
   * Absent or zero means *no roll is cuttable* — an incomplete master, not a
   * pack size to be guessed at.
   */
  beltsPerRoll?: number;
  /**
   * PCTR and CTR: the weight of one whole roll, in kg (1.2, 1.3).
   *
   * ERPNext holds this in `custom_weight_per_roll` for both families. Derived
   * from `weightPerBelt x beltsPerRoll` when the site has not stored it.
   */
  weightPerRoll?: number;
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

// ----------------------------------------------------- field attendance ---

/**
 * A person, as this site actually models one: a `Sales Person`, not an
 * `Employee`. See `domain/attendance.ts` for why.
 */
export interface SalesPerson {
  /** `Sales Person.name` — also the link target used by attendance and leave. */
  id: string;
  name: string;
  /** `custom_team_manager` — Pareeth / Saneesh / Renjith. */
  teamManager: string;
  /** `custom_company` — the business unit, not the ERPNext Company. */
  unit: string;
  /** `custom_user` — their login, when they have one. */
  userId?: string;
  enabled: boolean;
  /** Roll-up nodes in the Sales Person tree are not people. */
  isGroup: boolean;
}

export type PunchStatus = 'Punched In' | 'Punched Out';

/** One day's punch record from the field-sales app. */
export interface AttendanceLog {
  id: string;
  person: string;
  date: string;
  punchIn?: string;
  punchOut?: string;
  status: PunchStatus;
  /** Measured by the site; meaningless until the shift is closed. */
  workingHours: number;
  remarks?: string;
}

export type ApprovalStatus = 'Pending Approval' | 'Approved' | 'Rejected';
export type ApproverType = 'Sales Manager' | 'HR';

export interface FieldLeaveRequest {
  id: string;
  person: string;
  /** A single day — this doctype has no from/to range. */
  date: string;
  /** 1 or 0.5. */
  days: number;
  halfDay: boolean;
  halfDayPeriod?: 'Morning' | 'Afternoon';
  reason?: string;
  status: ApprovalStatus;
  approverType: ApproverType;
  teamManager?: string;
  /** Set when the requester is themselves a manager. */
  requesterIsManager: boolean;
  decidedBy?: string;
  /**
   * The two approvals are INDEPENDENT and unordered: either party may act
   * first, and the leave is granted only once both have. Neither is a
   * precondition for the other.
   */
  managerApproved: boolean;
  managerApprovedBy?: string;
  hrApproved: boolean;
  hrApprovedBy?: string;
}

/** Whether an approved regularization was actually written into the log. */
export type CompletionStatus = 'Completed' | 'Not Completed';

export interface AttendanceRegularization {
  id: string;
  person: string;
  date: string;
  requestedPunchIn?: string;
  requestedPunchOut?: string;
  reason?: string;
  status: ApprovalStatus;
  approverType: ApproverType;
  teamManager?: string;
  requesterIsManager: boolean;
  decidedBy?: string;
  decisionRemarks?: string;
  /**
   * The gap this module exists to close: a regularization can be `Approved`
   * while still `Not Completed`, meaning nobody rewrote the attendance log and
   * the hours never moved.
   */
  completionStatus: CompletionStatus;
}

// ------------------------------------------------- customers & sales orders ---

/** A trading party, as the live site models one. */
export interface SalesCustomer {
  id: string;
  name: string;
  /** `custom_assigned_reps` — a Link to Sales Person holding a bare name. */
  assignedRep?: string;
  route?: string;
  gstin?: string;
  /** SAP sends one figure, so this stays one figure. */
  creditLimit: number;
  /** The total, and what the credit limit is checked against. */
  outstanding: number;
  /**
   * SAP's four aging buckets, as stored. Read them through `domain/credit.ts`
   * rather than directly — it is the only place that knows the total wins over
   * the sum, and that four zeros mean "not synced" rather than "nothing due".
   */
  outstanding0_30: number;
  outstanding30_60: number;
  outstanding60_90: number;
  outstanding90Plus: number;
  locationStatus?: LocationStatus;
  latitude: number;
  longitude: number;
  capturedBy?: string;
  bannerPhoto?: string;
}

/** A Sales Order as the manager's screens need it. */
export interface TeamOrder {
  id: string;
  customer: string;
  customerName: string;
  /** `custom_sales_person` — who raised it. */
  rep: string;
  /** Business unit (`custom_company`), not the ERPNext Company. */
  unit?: string;
  placedOn: string;
  deliveryDate?: string;
  total: number;
  /** `custom_po_status` — the raw stored string; label it before display. */
  poStatus: string;
  productionStatus?: string;
  /** Set once the week is closed and the order folded into a group. */
  combinedOrder?: string;
  ratesApproved: boolean;
  route?: string;
}

/** Where a captured location stands. */
export type LocationStatus =
  | 'Not Captured'
  | 'Pending Verification'
  | 'Verified'
  | 'Rejected';

/** A lead — a party that has not yet placed an approved order. */
export interface SalesLead {
  id: string;
  name: string;
  /** `company_name` — the trading name, often the same as `lead_name`. */
  companyName?: string;
  rep?: string;
  route?: string;
  gstin?: string;
  address?: string;
  city?: string;
  mobile?: string;
  shopType?: string;
  status?: string;
  /** Set once the lead has been converted. */
  customer?: string;
  locationStatus?: LocationStatus;
  capturedBy?: string;
  latitude: number;
  longitude: number;
  bannerPhoto?: string;
}

/** A route a rep can be given. */
export interface SalesRoute {
  id: string;
  name: string;
  rep?: string;
  isActive: boolean;
}

/**
 * One thing waiting on a location decision — a customer or a lead.
 *
 * Both queues have the same shape and the same decision, so they are one type
 * and one screen. The `kind` is what decides which doctype gets written.
 */
/**
 * One capture waiting on a manager's eye.
 *
 * Carries the party's full detail, not just a name and a pin. The manager is
 * deciding whether a photograph is the place the record claims — and a shop
 * sign matches a *name*, a *town* and a *trade*, not a document id. Without
 * the mobile number there is also no way to query a doubtful one except by
 * going back through the rep.
 */
export interface LocationCheck {
  /** A site is new premises being asserted; the judgement is the same. */
  kind: 'customer' | 'lead' | 'site';
  id: string;
  name: string;
  /** Lead only: the trading name, when it differs from the contact name. */
  companyName?: string;
  rep?: string;
  route?: string;
  capturedBy?: string;
  latitude: number;
  longitude: number;
  bannerPhoto?: string;
  address?: string;
  city?: string;
  mobile?: string;
  shopType?: string;
  gstin?: string;
  /** Lead only: where it sits in the CRM pipeline. */
  status?: string;
}

/** One line of a Sales Order, as the approval screen needs it. */
export interface OrderLine {
  /** The child row's own name — required to write back to it. */
  id: string;
  itemCode: string;
  itemName: string;
  itemGroup?: string;
  category?: string;
  qty: number;
  uom?: string;
  /** Derived: ratePerKg x roll weight. ERPNext stores this, people read the other. */
  rate: number;
  amount: number;
  /** What the rep actually quoted, per kilogram. */
  ratePerKg: number;
  totalWeight: number;
  rolls: number;
  looseBelts: number;
  packingNote?: string;
  /** Per-line: "this price is final". Survives an edit that reopens the order. */
  rateApproved: boolean;
  /**
   * The manager's concession on this line, 0–100. Locked by the same approval
   * that locks the rate — a discount is a price.
   */
  discountPercent: number;
  /**
   * Per unit, before the discount. `rate` is always the figure AFTER it, so
   * these are equal on a line nobody has discounted.
   */
  priceListRate: number;
  /** The line at the rep's quoted rate: qty x priceListRate. */
  amountBeforeDiscount: number;
  /** What the customer is invoiced. Prefers the stored `amount`. */
  amountAfterDiscount: number;
  fulfilmentMode?: string;
  /** Free text (`Data`) — the stage of the portion being MADE. */
  productionStage?: string;
  /** Free text (`Data`) — the stage of the portion coming off the SHELF. */
  stockStage?: string;
  /** Link to `Manna Minimum Stock Batch` when the line was filled from aged stock. */
  agedBatch?: string;
  /**
   * Cumulative across every `Manna Dispatch` that has touched this line —
   * never one dispatch's own amount. Read through `domain/dispatch.ts`'s
   * `remainingToDispatch`/`isFullyDispatched`, never compared to
   * `rolls`/`looseBelts` directly.
   */
  dispatchedRolls?: number;
  dispatchedLooseBelts?: number;
  /** The *current outstanding* shortfall reason — blank once fully caught up. */
  dispatchShortReason?: string;
}

/**
 * One row of `Manna Stock Reservation` — a claim on pooled stock.
 *
 * Live and maintained by the field-sales app. The pool's `custom_reserved_qty`
 * is the denormalised sum of the Active rows here, and the two are kept in
 * step by whoever writes them; nothing on the server enforces it.
 */
export interface StockReservationRow {
  id: string;
  itemCode: string;
  rolls: number;
  looseBelts: number;
  salesOrder?: string;
  leadOrder?: string;
  salesPerson?: string;
  batch?: string;
  reservedOn?: string;
  /** `Active` | `Released`. Only Active rows hold anything. */
  status: string;
  /** `Shelf` | `Production Run` — which of the two pools this claim came from. */
  source?: string;
}

/** A lead order — the pre-customer equivalent of a Sales Order. */
export interface LeadOrder {
  id: string;
  lead: string;
  leadName: string;
  rep?: string;
  orderDate: string;
  total: number;
  status: string;
  poNumber?: string;
  approvalRemarks?: string;
  lines: LeadOrderLine[];
}

/**
 * A lead order line. Deliberately thin: `Lead Order Item` holds only item,
 * qty, rate and amount — no roll/belt breakdown and no bookings — so an order
 * raised from one always reads as new production.
 */
export interface LeadOrderLine {
  id: string;
  itemCode: string;
  itemName: string;
  qty: number;
  /** Per unit, AFTER any discount — what the lead will be invoiced. */
  rate: number;
  amount: number;
  /**
   * `Lead Order Item` has no standard pricing fields, so the discount lives in
   * `custom_discount_percentage` / `custom_price_list_rate`. Same two numbers
   * as a Sales Order, different spelling; `domain/discount.ts` is the only
   * place that knows which.
   */
  discountPercent: number;
  priceListRate: number;
  amountBeforeDiscount: number;
}

/**
 * An order as the **production** dashboard sees it.
 *
 * Note what is not here: no `customer`, no `customerName`, no address. The
 * production manager must never see who the order is for, and the way to
 * guarantee that is for the identity never to reach the screen — not to hide
 * it in CSS, and not to leave it on the object where a search box could match
 * it. The customer is resolved to a `route` at the API boundary and dropped.
 */
export interface ProductionOrderRow {
  id: string;
  /** The destination route, or the literal "No route set". Never a territory. */
  route: string;
  rep: string;
  unit?: string;
  placedOn: string;
  deliveryDate?: string;
  /** What the customer originally asked for, if production has moved the date. */
  originalDeliveryDate?: string;
  total: number;
  productionStatus?: string;
  productionFinishDate?: string;
  changedAfterApproval: boolean;
  combinedOrder?: string;
}

/**
 * One order line still owed some quantity, offered up for a manager to add
 * to a `Manna Dispatch`. Route, never customer — same rule as
 * `ProductionOrderRow`.
 */
export interface DispatchableLine {
  salesOrder: string;
  /** The child row's own name on that order. */
  salesOrderItem: string;
  itemCode: string;
  itemName: string;
  route: string;
  remainingRolls: number;
  remainingLooseBelts: number;
}

/** One line staged in a `Manna Dispatch`, at whichever stage it currently sits. */
export interface DispatchLine {
  salesOrder: string;
  salesOrderItem: string;
  itemCode: string;
  itemName: string;
  route: string;
  plannedRolls: number;
  plannedLooseBelts: number;
  /** Only meaningful once the header is `Dispatched`. */
  dispatchedRolls: number;
  dispatchedLooseBelts: number;
  shortfallReason?: string;
}

/**
 * `Manna Dispatch` — one vehicle, one date, any number of order lines.
 * Freely editable while `status = Draft`; `Dispatched` is a final click.
 */
export interface Dispatch {
  id: string;
  vehicle: string;
  dispatchDate?: string;
  unit?: string;
  status: string;
  lines: DispatchLine[];
}

/** A weekly grouping of one customer's completed orders. */
export interface CombinedOrder {
  id: string;
  customer: string;
  customerName: string;
  weekStart: string;
  weekEnd: string;
  status: string;
  orderCount: number;
  total: number;
  groupedBy?: string;
}

/** A Sales Order with everything a decision needs. */
export interface OrderDetail extends TeamOrder {
  lines: OrderLine[];
  proformaStatus?: string;
  changedAfterApproval: boolean;
  placedAt?: string;
}

/**
 * One item's position in the minimum-stock pool.
 *
 * `rolls` is what is on the shelf and `reservedRolls` is what other orders
 * have already claimed; only the difference can be promised. See
 * `domain/minimumStock.ts` for why the two are never collapsed into one figure.
 */
export interface MinStockLine {
  /** The row's own name on the site, which is the item code itself. */
  itemCode: string;
  /** The level to hold — `Manna Minimum Stock Item.qty`, NOT the shelf. */
  minimumRolls: number;
  minimumBelts: number;
  /** What physically exists — from the matching `Manna Minimum Stock Batch`. */
  shelfRolls: number;
  shelfBelts: number;
  /** Booked off the shelf by reps. */
  reservedRolls: number;
  reservedBelts: number;
  /** A run raised in SAP to refill this pool. Intent, never availability. */
  inProductionRolls: number;
  inProductionBelts: number;
  /** Of that run, what reps have already claimed — a second, separate pool. */
  reservedInProductionRolls: number;
  reservedInProductionBelts: number;
  runStage?: string;
  runUpdatedOn?: string;
  runUpdatedBy?: string;
  lastSoldOn?: string;
  /** Oldest batch date, for the stock-age note. */
  batchDate?: string;
}

/**
 * An `Item` as the order editor's picker needs it.
 *
 * Separate from `Product` because the picker shows the packing figures
 * verbatim — belts per roll, the per-belt average, the exact roll weight — so
 * the manager can see *why* a line will price the way it does before adding it.
 */
export interface ItemOption {
  code: string;
  name: string;
  /** The order-line vocabulary (`PCTR`/`CTR`/`BG`/`VS`), already translated. */
  category: ProductCategory;
  /** How the Item master itself spells the category. */
  itemCategory?: string;
  itemGroup?: string;
  uom: string;
  weightPerBelt?: number;
  beltsPerRoll?: number;
  weightPerRoll?: number;
  packLitres?: number;
  sapCode?: string;
  /** The master's own verdict — "No Data" means it cannot be priced. */
  weightStatus?: string;
}

// ------------------------------------------------------ trips & expenses ---

/** Transport modes a leg can use. Free text on the site; these are what exist. */
export type TravelMode =
  | 'Own Vehicle'
  | 'Bike'
  | 'Company Vehicle (Car)'
  | 'Mixed'
  | string;

/** Per-km reimbursement rates, from the `Trip Rate Settings` Single. */
export interface TripRates {
  ownCar: number;
  ownBike: number;
  companyCar: number;
  companyBike: number;
  /** Fallback only — a "Mixed" trip really prices leg by leg. */
  mixed: number;
}

/**
 * One vehicle leg of a trip.
 *
 * `startOdometer`/`endOdometer` are what the rep typed. The photo is what the
 * dial actually said. When those disagree, HR ticks `notVerified` and enters
 * the real figures in `actualStart`/`actualEnd`, which then govern the claim.
 */
export interface TripLeg {
  id: string;
  mode: TravelMode;
  vehicleNo?: string;
  hasOdometer: boolean;
  startOdometer: number;
  endOdometer: number;
  /** As recorded on the site; recomputed from the odometers when verifying. */
  distanceKm: number;
  startOdometerPhoto?: string;
  endOdometerPhoto?: string;
  notVerified: boolean;
  actualStartOdometer: number;
  actualEndOdometer: number;
  claimedAmount: number;
  approvedAmount: number;
  status?: string;
  remarks?: string;
}

export interface TripExpense {
  id: string;
  category: string;
  expenseName?: string;
  amount: number;
  /**
   * Whose expense this is on a shared trip, or undefined when it is common to
   * everyone who travelled. Read it through `expenseOwner` in `domain/trips`,
   * which is the only place that knows an unset Link comes back three ways.
   */
  forPerson?: string;
  approvedAmount: number;
  hasBill: boolean;
  billPhoto?: string;
  status?: string;
  remarks?: string;
}

export interface Trip {
  id: string;
  person: string;
  date: string;
  startTime?: string;
  endTime?: string;
  primaryMode: TravelMode;
  costBasis?: string;
  distanceKm: number;
  estimatedCost: number;
  totalExpenses: number;
  status: string;
  expenseStatus?: string;
  purpose?: string;
  /** Names of reps who travelled along. Empty for a solo trip. */
  taggedReps: string[];
  legs: TripLeg[];
  expenses: TripExpense[];
}

export interface SalesVisit {
  id: string;
  person: string;
  date: string;
  tripId?: string;
  leadId?: string;
  customerId?: string;
  checkIn?: string;
  checkOut?: string;
  durationMinutes: number;
  purpose?: string;
  status?: string;
}

/**
 * Everywhere a trip is known to have been.
 *
 * The stops are the substance — real records of a rep checking in somewhere
 * whose coordinates are known. `gpsPoints` is kept separate and deliberately
 * not treated as a path: trips carry one or two samples, hours apart, and
 * joining them would draw a route nobody took.
 */
export interface TripTrack {
  trip: Trip;
  start: { latitude: number; longitude: number; at?: string };
  end: { latitude: number; longitude: number; at?: string };
  stops: Array<{
    visit: SalesVisit;
    name: string;
    place?: { latitude: number; longitude: number };
  }>;
  gpsPoints: Array<{ latitude: number; longitude: number; at?: string }>;
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
  /**
   * `custom_sales_route` — which delivery run this party is on.
   *
   * Distinct from `destination`: the route decides the van, and an order
   * cannot be started without one (see `canStartOrder`).
   */
  route?: string;
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

/**
 * `Manna Production Order` — the two flows in `shared/PRODUCTION_FLOWS.md`.
 *
 * `itemName` is not stored on the doctype — joined from the product catalogue
 * or the minimum-stock ledger by `itemCode` at display time, the same way a
 * `StockBatch` has no item name of its own.
 */
export interface ProductionOrder {
  id: string;
  itemCode: string;
  itemName: string;
  qty: number;
  looseBelts?: number;
  raisedAt: string;
  raisedBy: string;
  /** `Open` → `In Production` → `Made` → `Received` (flow A) or `Dispatched` (flow B). */
  status: 'open' | 'in_production' | 'made' | 'received' | 'dispatched' | 'cancelled';
  /** Set once at creation, never edited afterwards — see PRODUCTION_FLOWS.md. */
  purpose: 'stock' | 'order';
  /** Required when `purpose` is `'order'`, empty when `'stock'`. */
  salesOrderId?: string;
  receivedAt?: string;
  receivedBy?: string;
  /** The batch receiving created, so the trail is followable. */
  batchId?: string;
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
