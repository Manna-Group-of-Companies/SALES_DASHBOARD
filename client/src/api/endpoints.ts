/**
 * Every ERPNext doctype and field name this module touches, in one place.
 *
 * The existing field-sales app already uses `Sales Order` with the
 * `custom_sales_person` / `custom_po_status` / `custom_production_status`
 * custom fields, so this module extends that same document rather than
 * introducing a parallel one. The genuinely new concepts — the minimum-stock
 * ledger, dated batches, reservations and the notification feed — get their own
 * doctypes.
 *
 * See `docs/ERPNEXT_DOCTYPES.md` for the create-these-in-ERPNext spec.
 */

export const DOCTYPE = {
  salesOrder: 'Sales Order',
  customer: 'Customer',
  item: 'Item',
  salesPerson: 'Sales Person',
  user: 'User',

  // --- new for this module ---------------------------------------------
  minStock: 'Min Stock Item',
  stockBatch: 'Min Stock Batch',
  stockReservation: 'Stock Reservation',
  weeklyGroup: 'Weekly Order Group',
  productionOrder: 'Production Order Request',
  notification: 'Sales Notification',
  orderTimeline: 'Sales Order Timeline',

  // --- HR: stock ERPNext HR doctypes, not new ones ----------------------
  employee: 'Employee',
  attendance: 'Attendance',
  leaveApplication: 'Leave Application',
} as const;

/**
 * `Employee` fields this module reads. All standard ERPNext HR except
 * `custom_leave_balance`, which is a rolled-up convenience field — the real
 * per-type balance lives in `Leave Ledger Entry`.
 */
export const EMPLOYEE_FIELD = {
  employeeName: 'employee_name',
  designation: 'designation',
  department: 'department',
  employmentType: 'employment_type',
  joinedOn: 'date_of_joining',
  relievedOn: 'relieving_date',
  status: 'status',
  phone: 'cell_number',
  email: 'company_email',
  branch: 'branch',
  reportsTo: 'reports_to',
  user: 'user_id',
  leaveBalance: 'custom_leave_balance',
} as const;

/** `Attendance` fields. One document per employee per day. */
export const ATTENDANCE_FIELD = {
  employee: 'employee',
  date: 'attendance_date',
  status: 'status',
  checkIn: 'in_time',
  checkOut: 'out_time',
  note: 'custom_note',
} as const;

/** `Leave Application` fields. */
export const LEAVE_FIELD = {
  employee: 'employee',
  employeeName: 'employee_name',
  type: 'leave_type',
  fromDate: 'from_date',
  toDate: 'to_date',
  days: 'total_leave_days',
  reason: 'description',
  status: 'status',
  decisionNote: 'custom_decision_note',
} as const;

/** Custom fields added to `Sales Order` for this module. */
export const SO_FIELD = {
  salesPerson: 'custom_sales_person',
  destination: 'custom_destination',
  status: 'custom_sales_status',
  approvedAt: 'custom_approved_at',
  approvedBy: 'custom_approved_by',
  rateLocked: 'custom_rate_locked',
  fulfilmentSource: 'custom_fulfilment_source',
  revisedDeliveryDate: 'custom_revised_delivery_date',
  proformaGenerated: 'custom_proforma_generated',
  proformaNo: 'custom_proforma_no',
  weeklyGroup: 'custom_weekly_group',
  dispatchedAt: 'custom_dispatched_at',
  rejectionReason: 'custom_rejection_reason',
} as const;

/** Custom fields added to `Sales Order Item`. */
export const SO_ITEM_FIELD = {
  category: 'custom_category',
  rolls: 'custom_rolls',
  looseBelts: 'custom_loose_belts',
  tins: 'custom_tins',
  tinSize: 'custom_tin_size',
  quotedRate: 'custom_quoted_rate',
  finalRate: 'custom_final_rate',
  rateLocked: 'custom_rate_locked',
  source: 'custom_source',
  agedBatch: 'custom_aged_batch',
  stage: 'custom_stage',
  stageUpdatedAt: 'custom_stage_updated_at',
} as const;

/** Custom fields added to `Item`. */
export const ITEM_FIELD = {
  category: 'custom_product_category',
  avgWeightPerRoll: 'custom_avg_weight_per_roll',
  beltsPerRoll: 'custom_belts_per_roll',
  exactWeightPerRoll: 'custom_exact_weight_per_roll',
  tinSize: 'custom_tin_size',
  size: 'custom_size',
} as const;

/** Custom fields added to `Customer` (address/GST arrive via Excel import). */
export const CUSTOMER_FIELD = {
  destination: 'custom_destination',
  gstin: 'gstin',
  outstanding: 'custom_outstanding_balance',
  creditLimit: 'custom_credit_limit',
  assignedReps: 'custom_assigned_reps',
  phone: 'custom_phone',
} as const;

/**
 * `User` flags that decide a login's role. These already drive the field-sales
 * app, except `custom_is_stock_manager`, which is new for this module.
 */
export const USER_FIELD = {
  managedTeam: 'custom_managed_team',
  isProductionManager: 'custom_is_production_manager',
  isStockManager: 'custom_is_stock_manager',
  isHr: 'custom_is_hr',
  productionCompany: 'custom_production_company',
} as const;

/** Whitelisted server methods this module expects (see the doctype doc). */
export const METHOD = {
  login: '/api/method/login',
  logout: '/api/method/logout',
  loggedUser: '/api/method/frappe.auth.get_logged_user',
  /** Atomic reserve/release so two reps cannot oversell the same stock. */
  reserveStock: '/api/method/manna_sales.api.reserve_stock',
  releaseStock: '/api/method/manna_sales.api.release_stock',
  /** Server-side approval so the rate lock cannot be bypassed by a raw PUT. */
  approveOrder: '/api/method/manna_sales.api.approve_order',
  compileWeek: '/api/method/manna_sales.api.compile_weekly_group',
} as const;
