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
  /** Attachments. The shop photo lives here, not on the party's own field. */
  file: 'File',
  user: 'User',

  /*
   * --- minimum stock -----------------------------------------------------
   *
   * `Manna Minimum Stock Item` is real and verified — 164 rows, named by
   * item code. It was guessed here as `Min Stock Item`, which does not exist.
   * The batch and reservation doctypes carry the same prefix on the site.
   */
  minStock: 'Manna Minimum Stock Item',
  stockBatch: 'Manna Minimum Stock Batch',
  stockReservation: 'Manna Stock Reservation',

  /*
   * --- the manager module ------------------------------------------------
   *
   * All verified present on 7 Aug 2026. `Lead Order` has no rows yet and
   * `Customer Site` has none either, so both are read defensively.
   */
  leadOrder: 'Lead Order',
  combinedOrder: 'Combined Order',
  customerSite: 'Customer Site',
  weeklyGroup: 'Weekly Order Group',
  productionOrder: 'Production Order Request',
  notification: 'Sales Notification',
  orderTimeline: 'Sales Order Timeline',

  /*
   * --- HR ---------------------------------------------------------------
   *
   * Verified against the live site on 7 Aug 2026. These are custom doctypes
   * built for the field-sales app; Frappe HR (`hrms`) is NOT installed, so
   * `Attendance` and `Leave Application` genuinely do not exist here and
   * `Employee` holds a single disabled test row.
   */
  attendanceLog: 'Attendance Log',
  leaveRequest: 'Leave Request',
  attendanceRegularization: 'Attendance Regularization',

  /*
   * --- Trips and expenses ------------------------------------------------
   *
   * `Trip` is the parent; `legs`, `expenses` and `tagged_reps` are child
   * tables on it, so they are written by updating the Trip, never directly.
   * `Trip Rate Settings` is a Single — read it with `getDoc`, not a list.
   */
  trip: 'Trip',
  tripRateSettings: 'Trip Rate Settings',
  salesVisit: 'Sales Visit',
  lead: 'Lead',
  salesRoute: 'Sales Route',

  /**
   * DEPRECATED — the original HR guess. `Employee` exists but is unused (one
   * disabled test row); the other two do not exist on this site at all. Still
   * referenced by the fixture-era HR screens until those are replaced by the
   * attendance module above, then all three go.
   */
  employee: 'Employee',
  attendance: 'Attendance',
  leaveApplication: 'Leave Application',
} as const;

/** `Attendance Log` — one punch pair per person per day. */
export const ATTENDANCE_LOG_FIELD = {
  person: 'sales_person',
  date: 'attendance_date',
  punchIn: 'punch_in_time',
  punchOut: 'punch_out_time',
  status: 'status',
  workingHours: 'working_hours',
  remarks: 'remarks',
} as const;

/** `Leave Request` — a single dated day, not a range. */
export const LEAVE_REQUEST_FIELD = {
  person: 'sales_person',
  date: 'leave_date',
  days: 'leave_days',
  halfDay: 'half_day',
  halfDayPeriod: 'half_day_period',
  reason: 'reason',
  status: 'status',
  approverType: 'approver_type',
  teamManager: 'team_manager',
  requesterIsManager: 'requester_is_manager',
  decidedBy: 'decided_by',
  /** Independent, unordered approvals — see `FieldLeaveRequest`. */
  managerApproved: 'manager_approved',
  managerApprovedBy: 'manager_approved_by',
  hrApproved: 'hr_approved',
  hrApprovedBy: 'hr_approved_by',
} as const;

/** `Attendance Regularization` — a correction request against a log. */
export const REGULARIZATION_FIELD = {
  person: 'sales_person',
  date: 'attendance_date',
  requestedPunchIn: 'requested_punch_in',
  requestedPunchOut: 'requested_punch_out',
  reason: 'reason',
  status: 'status',
  approverType: 'approver_type',
  teamManager: 'team_manager',
  requesterIsManager: 'requester_is_manager',
  decidedBy: 'decided_by',
  decisionRemarks: 'decision_remarks',
  completionStatus: 'completion_status',
} as const;

/** `Trip` — one day's travel for one sales person. */
export const TRIP_FIELD = {
  person: 'sales_person',
  date: 'trip_date',
  startTime: 'start_time',
  endTime: 'end_time',
  primaryMode: 'primary_mode',
  costBasis: 'cost_basis',
  distanceKm: 'total_distance_km',
  odometerDistanceKm: 'odometer_distance_km',
  gpsDistanceKm: 'gps_distance_km',
  estimatedCost: 'estimated_cost',
  totalExpenses: 'total_expenses',
  status: 'status',
  expenseStatus: 'custom_expense_status',
  expenseRemarks: 'custom_expense_remarks',
  purpose: 'purpose',
  /**
   * Pipe-wrapped names of the reps who travelled along, e.g.
   * `|Renjith|Saneesh|`. The wrapping is what makes an exact-name `LIKE`
   * safe — `%|Saneesh|%` cannot also match a longer name containing it.
   */
  taggedCsv: 'tagged_csv',
} as const;

/**
 * `Trip Vehicle Leg` — child of `Trip`. One leg per vehicle/mode.
 *
 * The odometer verification lives here: a rep types the reading *and*
 * photographs it, and the two can disagree. HR ticks `custom_not_verified`
 * and types what the photo actually shows into the two `custom_actual_*`
 * fields, which then become the figures the claim is computed from.
 */
export const TRIP_LEG_FIELD = {
  mode: 'mode',
  vehicleNo: 'vehicle_no',
  hasOdometer: 'has_odometer',
  startOdometer: 'start_odometer',
  endOdometer: 'end_odometer',
  distanceKm: 'leg_distance_km',
  startOdometerPhoto: 'start_odometer_photo',
  endOdometerPhoto: 'end_odometer_photo',
  notVerified: 'custom_not_verified',
  actualStartOdometer: 'custom_actual_start_odometer',
  actualEndOdometer: 'custom_actual_end_odometer',
  claimedAmount: 'claimed_amount',
  approvedAmount: 'custom_approved_amount',
  status: 'status',
  remarks: 'remarks',
} as const;

/** `Trip Expense` — child of `Trip`. Daily allowance, accommodation, tickets. */
export const TRIP_EXPENSE_FIELD = {
  category: 'category',
  expenseName: 'expense_name',
  amount: 'amount',
  approvedAmount: 'custom_approved_amount',
  hasBill: 'has_bill',
  billPhoto: 'bill_photo',
  status: 'status',
  remarks: 'remarks',
} as const;

/**
 * `Trip Rate Settings` — a Single. Per-km rates by mode.
 *
 * `rate_company` looks vestigial: a Company Vehicle (Car) trip prices at
 * `rate_company_car`, which is 0. Read the specific fields, not the general one.
 */
export const TRIP_RATE_FIELD = {
  ownCar: 'rate_own_car',
  ownBike: 'rate_own_bike',
  companyCar: 'rate_company_car',
  companyBike: 'rate_company_bike',
  mixed: 'rate_mixed',
} as const;

/** `Sales Visit` — a shop visit, created when a rep checks in at a lead/customer. */
export const SALES_VISIT_FIELD = {
  person: 'sales_person',
  date: 'visit_date',
  trip: 'custom_trip',
  lead: 'custom_lead',
  customer: 'customer',
  site: 'custom_site',
  checkIn: 'check_in_time',
  checkOut: 'check_out_time',
  durationMinutes: 'custom_duration_minutes',
  purpose: 'visit_purpose',
  status: 'visit_status',
} as const;

/**
 * `Sales Order` — the real custom fields on this site.
 *
 * Note `custom_po_status`, NOT `custom_sales_status`: the latter was invented
 * for this module and does not exist. The stored strings still say "PO"; label
 * them with `approvalLabel` before showing anyone.
 */
export const SALES_ORDER_FIELD = {
  rep: 'custom_sales_person',
  unit: 'custom_company',
  poStatus: 'custom_po_status',
  productionStatus: 'custom_production_status',
  ratesApproved: 'custom_rate_approved',
  combinedOrder: 'custom_combined_order',
  placedOn: 'transaction_date',
  deliveryDate: 'delivery_date',
  total: 'grand_total',
  customer: 'customer',
  customerName: 'customer_name',
  /** Set once by production when the promised date moves. Never overwritten. */
  originalDeliveryDate: 'custom_original_delivery_date',
  productionFinishDate: 'custom_production_finish_date',
  changedAfterApproval: 'custom_changed_after_approval',
  proformaStatus: 'custom_proforma_status',
  proformaRequired: 'custom_proforma_required',
  poNumber: 'custom_po_number',
  poAttachment: 'custom_po_attachment',
  /**
   * When the order was raised. **Production must never write this** — every
   * deadline is measured from it and it is not theirs to move.
   */
  placedAt: 'custom_order_placed_at',
} as const;

/** The six values `custom_proforma_status` accepts. */
export const PROFORMA_STATUS = {
  ready: 'Ready',
  blocked: 'Blocked - Credit',
  pendingRelease: 'Pending Release Approval',
  released: 'Released',
  sent: 'Sent',
  notRequired: 'Not Required',
} as const;

/** The three production units `custom_company` accepts. */
export const UNITS = ['Manna Tyre Retreads', 'Manna Treads', 'Manna Tyres UAE'] as const;

/**
 * `Sales Order Item` — child of `Sales Order`.
 *
 * `custom_rate_per_kg` is what the rep actually quoted; `rate` is the derived
 * per-unit figure ERPNext needs. Show the former, compute the latter.
 */
export const SALES_ORDER_ITEM_FIELD = {
  category: 'custom_product_category',
  rolls: 'custom_rolls',
  looseBelts: 'custom_loose_belts',
  boxes: 'custom_boxes',
  cans: 'custom_cans',
  totalWeight: 'custom_total_weight',
  ratePerKg: 'custom_rate_per_kg',
  packingNote: 'custom_packing_note',
  rateApproved: 'custom_rate_approved',
  /**
   * Select: `"" | "From Minimum Stock" | "New Production"` (label "Fulfil From").
   * Empty on every live line today — nothing has been deciding it. A value
   * outside those three is refused by Frappe on save.
   */
  fulfilmentMode: 'custom_fulfilment_mode',
  /**
   * `Data`, free text — the fine stage such as "Curing". Confirmed present as
   * a Custom Field; it is simply unset on every live line, which is why it is
   * absent from the JSON of a document rather than present as null.
   *
   * Never write this value to the order's `custom_production_status`, which is
   * a Select of four values and rejects anything else outright.
   */
  productionStage: 'custom_production_stage',
  /**
   * Data, free text — the stage of the portion coming off the SHELF.
   * custom_production_stage is the stage of the portion being MADE. A split
   * line carries both, and they finish separately.
   */
  stockStage: 'custom_stock_stage',
  /** Link to `Manna Minimum Stock Batch` when filled from aged stock. */
  agedBatch: 'custom_aged_batch',

  /*
   * The discount the sales manager grants at approval.
   *
   * ERPNext's OWN pricing fields, not custom ones. They already exist on
   * `Sales Order Item` — only the Desk `discount_and_margin` section is
   * hidden, by a Property Setter — and `net_total`, `grand_total`, the
   * proforma, GST and the eventual Sales Invoice are all built from `amount`.
   * A custom field would show the discount here and lose it on the invoice.
   *
   * (`Lead Order Item` is the exception: it was given
   * `custom_price_list_rate` / `custom_discount_percentage` by the app team
   * because it is a custom doctype with no native pricing of its own. See
   * LEAD_ORDER_ITEM_FIELD.)
   */
  priceListRate: 'price_list_rate',
  discountPercent: 'discount_percentage',
  discountAmount: 'discount_amount',
} as const;

/**
 * The four values `custom_fulfilment_mode` accepts on Sales Order and Sales
 * Order Item. Anything else is refused on save.
 *
 * `From Production Run` was added 8 Aug 2026. Note `Lead Order Item` still has
 * only the original three — it cannot carry a run claim.
 *
 * This is **reported, never chosen.** The first booking takes the shelf, a
 * claim takes the run, and the rest is made to order; a manager picking from a
 * dropdown would be taking stock off whoever booked it first.
 */
export const FULFILMENT_MODE = {
  undecided: '',
  minimumStock: 'From Minimum Stock',
  productionRun: 'From Production Run',
  newProduction: 'New Production',
} as const;

/** `Manna Stock Reservation.custom_source` — which pool the claim came from. */
export const RESERVATION_SOURCE = {
  shelf: 'Shelf',
  productionRun: 'Production Run',
} as const;

/**
 * `Customer` — the party master.
 *
 * `custom_assigned_reps` is a Link to Sales Person holding a bare name. Match
 * it with equality; a pipe-wrapped LIKE against it returns nothing.
 */
export const SALES_CUSTOMER_FIELD = {
  customerName: 'customer_name',
  assignedRep: 'custom_assigned_reps',
  route: 'custom_sales_route',
  gstin: 'custom_gstin',
  /** One figure, because SAP sends one. Deliberately not aged. */
  creditLimit: 'custom_credit_limit',
  /** The TOTAL. What the credit limit is checked against. */
  outstanding: 'custom_outstanding_balance',
  /** SAP's four aging buckets. Read via `domain/credit.ts`, never directly. */
  outstanding0_30: 'custom_outstanding_0_30',
  outstanding30_60: 'custom_outstanding_30_60',
  outstanding60_90: 'custom_outstanding_60_90',
  outstanding90Plus: 'custom_outstanding_90_plus',
  locationStatus: 'custom_location_status',
  latitude: 'custom_latitude',
  longitude: 'custom_longitude',
  verifiedLatitude: 'custom_verified_latitude',
  verifiedLongitude: 'custom_verified_longitude',
  capturedBy: 'custom_location_captured_by',
  bannerPhoto: 'custom_banner_photo',
} as const;

/**
 * `Lead` — a separate doctype from `Customer`, 3,001 of them.
 *
 * A lead becomes a customer on approval of its first order. Until then it has
 * its own route, its own captured location and its own verification queue, so
 * it needs its own screen rather than being folded into the customer list.
 */
export const LEAD_FIELD = {
  leadName: 'lead_name',
  companyName: 'company_name',
  rep: 'custom_sales_person',
  route: 'custom_sales_route',
  gstin: 'custom_gstin',
  address: 'custom_address',
  city: 'city',
  mobile: 'mobile_no',
  shopType: 'custom_shop_type',
  status: 'status',
  customer: 'customer',
  locationStatus: 'custom_location_status',
  capturedBy: 'custom_location_captured_by',
  latitude: 'custom_latitude',
  longitude: 'custom_longitude',
  verifiedLatitude: 'custom_verified_latitude',
  verifiedLongitude: 'custom_verified_longitude',
  bannerPhoto: 'custom_banner_photo',
} as const;

/** `Sales Route` — named `<Rep> - <Place>`, and owned by one rep. */
export const SALES_ROUTE_FIELD = {
  routeName: 'route_name',
  rep: 'sales_person',
  isActive: 'is_active',
} as const;

/** `Sales Person` — the people master for attendance and leave. */
export const SALES_PERSON_FIELD = {
  personName: 'sales_person_name',
  teamManager: 'custom_team_manager',
  unit: 'custom_company',
  user: 'custom_user',
  enabled: 'enabled',
  isGroup: 'is_group',
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
  joinedOn: 'date_of_joining',
  relievedOn: 'relieving_date',
  status: 'status',
  phone: 'cell_number',
  email: 'company_email',
  branch: 'branch',
  reportsTo: 'reports_to',
  user: 'user_id',
} as const;

/**
 * Fields this module would like on `Employee` but which the live site does not
 * have — verified 6 Aug 2026 by reading a full record.
 *
 * They are kept out of `EMPLOYEE_FIELD` because Frappe fails the *entire* list
 * query with a 417 if one requested field is unknown, so a single absent field
 * blanks the whole employee list. Read through `OPTIONAL_EMPLOYEE_FIELD` and a
 * missing one simply arrives undefined.
 *
 * `employment_type` is standard ERPNext HR but lives in the `hrms` app, which
 * is not installed here. `custom_leave_balance` was only ever a convenience
 * roll-up — the real per-type balance is in `Leave Ledger Entry`.
 */
export const OPTIONAL_EMPLOYEE_FIELD = {
  employmentType: 'employment_type',
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

/**
 * Custom fields added to `Item`.
 *
 * Verified field-by-field against the live master on 7 Aug 2026. `custom_size`
 * and `custom_tin_size` were listed here and **do not exist** — Frappe answers
 * 417 and rejects the whole query when either is named, so asking for them cost
 * the entire catalogue rather than one column.
 */
export const ITEM_FIELD = {
  category: 'custom_product_category',
  /**
   * Despite the name, this holds the weight of one **belt**, not one roll —
   * `field x custom_belts_per_roll = custom_weight_per_roll` on every row of
   * the live master. It is misnamed on the site because every import sheet
   * uses that header; the correction happens once, in `toProduct`.
   */
  weightPerBelt: 'custom_avg_weight_per_roll',
  beltsPerRoll: 'custom_belts_per_roll',
  /** The whole-roll weight, for PCTR *and* CTR. */
  weightPerRoll: 'custom_weight_per_roll',
  /** Vulcanising Solution: tin volume in litres. This is the real tin-size field. */
  packLitres: 'custom_pack_litres',
  sapCode: 'custom_sap_item_code',
  /** "Data Available" | "No Data" — the master's own view of its weights. */
  weightStatus: 'custom_weight_data_status',
} as const;

/**
 * `Item.custom_product_category` and `Sales Order Item.custom_product_category`
 * do **not** share a vocabulary, and nothing on the site reconciles them.
 *
 * The Item field is a Select of `HOT | Precured | Vulcanising Solution |
 * Bonding Gum`; the order line is free Data holding `PCTR | CTR | BG | VS`.
 * Filtering Items by the order-line codes is what silently returned an empty
 * catalogue, so every crossing of that boundary goes through this map.
 *
 * "HOT" is hot rubber — conventional tread, sold at an exact roll weight —
 * which is `CTR` on the order line.
 */
export const ITEM_CATEGORY_TO_LINE = {
  Precured: 'PCTR',
  HOT: 'CTR',
  'Bonding Gum': 'BG',
  'Vulcanising Solution': 'VS',
} as const;

/** The Select options on `Item.custom_product_category`, as the site spells them. */
export const ITEM_CATEGORIES = Object.keys(ITEM_CATEGORY_TO_LINE) as (keyof typeof ITEM_CATEGORY_TO_LINE)[];

/** The same crossing in the other direction, for writes back to the master. */
export const LINE_CATEGORY_TO_ITEM = {
  PCTR: 'Precured',
  CTR: 'HOT',
  BG: 'Bonding Gum',
  VS: 'Vulcanising Solution',
} as const;

/**
 * `Manna Minimum Stock Item` — the pool of ready rolls held against demand.
 *
 * The row's `name` **is** the item code, so a line is matched to the pool by
 * item code with no join. `qty`/`loose_belts` are what physically exists;
 * the `custom_reserved_*` pair is what other orders have already spoken for.
 * Free stock is the difference — reading `qty` alone promises rolls twice.
 */
/**
 * `Manna Minimum Stock Item` — the **minimum to hold**, not the shelf.
 *
 * This is the trap in the whole module. `qty` here is the target level, and
 * the physical stock lives on the matching `Manna Minimum Stock Batch` row.
 * Proven on the live site: `120 AJAX 69` has `qty 2` here and `qty 4` on batch
 * MSB-00057, and `160 RTS 99` has `qty 10` here against a batch reading 0 —
 * which is exactly the "below minimum" condition the production screen exists
 * to raise. Read `qty` as the shelf and every availability figure is wrong,
 * usually in the direction of promising stock that is not there.
 */
export const MIN_STOCK_FIELD = {
  itemCode: 'item_code',
  /** The MINIMUM to hold. Shelf stock is on the batch. */
  minimumRolls: 'qty',
  minimumBelts: 'loose_belts',
  reservedRolls: 'custom_reserved_qty',
  reservedLooseBelts: 'custom_reserved_loose_belts',
  lastSoldOn: 'custom_last_sold_on',
  /** A run raised in SAP to refill this pool. Intent, never availability. */
  inProductionRolls: 'custom_in_production_qty',
  inProductionBelts: 'custom_in_production_belts',
  inProductionUpdatedOn: 'custom_in_production_updated_on',
  inProductionUpdatedBy: 'custom_in_production_updated_by',
  /** Of that run, how much reps have already claimed. Its own pool. */
  reservedInProductionRolls: 'custom_reserved_in_production_qty',
  reservedInProductionBelts: 'custom_reserved_in_production_belts',
  runStage: 'custom_production_run_stage',
} as const;

/** `Manna Minimum Stock Batch` — the actual rubber on the shelf. */
export const MIN_STOCK_BATCH_FIELD = {
  itemCode: 'item_code',
  rolls: 'qty',
  looseBelts: 'loose_belts',
  originalRolls: 'original_qty',
  originalBelts: 'original_loose_belts',
  batchDate: 'batch_date',
} as const;

/** `Manna Stock Reservation` — one claim on the pool. Verified live. */
export const STOCK_RESERVATION_FIELD = {
  itemCode: 'item_code',
  rolls: 'qty',
  looseBelts: 'loose_belts',
  salesOrder: 'sales_order',
  leadOrder: 'lead_order',
  salesPerson: 'sales_person',
  batch: 'batch',
  reservedOn: 'reserved_on',
  /** `Active` | `Released`. */
  status: 'status',
  /** `Shelf` (default) | `Production Run`. */
  source: 'custom_source',
} as const;

/**
 * `Lead Order` — read off the live doctype definition, not guessed.
 *
 * **There is no `sales_order` field.** The manager handoff's approval
 * write-back names one; it does not exist on this site, so the raised Sales
 * Order's id is recorded in `approval_remarks` instead and the gap is
 * reported rather than papered over.
 */
export const LEAD_ORDER_FIELD = {
  lead: 'lead',
  leadName: 'lead_name',
  rep: 'sales_person',
  orderDate: 'order_date',
  total: 'total_amount',
  /**
   * Select — `Pending Approval | Approved | Rejected | PO Uploaded |
   * PO Approved - Ready for SAP | Converted`.
   *
   * Note the absence of `Pending GM Approval`: a lead order cannot be
   * escalated, and writing that string is refused by Frappe.
   */
  status: 'status',
  poNumber: 'po_number',
  poAttachment: 'po_attachment',
  approvalRemarks: 'approval_remarks',
} as const;

/** `Lead Order Item` — item, qty, rate, amount and nothing else. */
export const LEAD_ORDER_ITEM_FIELD = {
  itemCode: 'item_code',
  itemName: 'item_name',
  qty: 'qty',
  rate: 'rate',
  amount: 'amount',
  /*
   * A custom doctype has no native pricing, so the app team added its own
   * pair here — labelled "Rate Before Discount" and "Discount (%)". The
   * Sales Order side uses ERPNext's native fields instead; see
   * SALES_ORDER_ITEM_FIELD. Same meaning, different storage, because the two
   * doctypes are not the same kind of record.
   */
  priceListRate: 'custom_price_list_rate',
  discountPercent: 'custom_discount_percentage',
} as const;

/**
 * `Combined Order` — the weekly grouping. Verified against COMB-00001..3.
 *
 * Membership lives only on `Sales Order.custom_combined_order`; there is no
 * child table here. With no server scripts, two records of the same fact drift
 * the first time a save half-fails.
 */
export const COMBINED_ORDER_FIELD = {
  customer: 'customer',
  customerName: 'customer_name',
  weekStart: 'week_start',
  weekEnd: 'week_end',
  status: 'status',
  orderCount: 'order_count',
  total: 'total_amount',
  /** Often null — a production manager is usually not a Sales Person. */
  groupedBy: 'grouped_by',
  notes: 'notes',
} as const;

/** Custom fields added to `Customer` (address/GST arrive via Excel import). */
export const CUSTOMER_FIELD = {
  destination: 'custom_destination',
  gstin: 'gstin',
  outstanding: 'custom_outstanding_balance',
  creditLimit: 'custom_credit_limit',
  /*
   * SAP ages its receivables into four buckets and sends all four. Created on
   * the live site 13 Aug 2026. `custom_outstanding_balance` stays the TOTAL —
   * it is what the credit limit has always been checked against, and it is
   * zero on no customer while the buckets are zero on all of them until the
   * SAP job is changed. The credit LIMIT is not split: SAP gives one figure.
   *
   * The rules live in `domain/credit.ts`, paired with `app/lib/core/credit.dart`
   * and pinned by `shared/fixtures/credit.json`.
   */
  outstanding0_30: 'custom_outstanding_0_30',
  outstanding30_60: 'custom_outstanding_30_60',
  outstanding60_90: 'custom_outstanding_60_90',
  outstanding90Plus: 'custom_outstanding_90_plus',
  assignedReps: 'custom_assigned_reps',
  phone: 'custom_phone',
} as const;

/**
 * `User` flags that decide a login's role. These already drive the field-sales
 * app, except `custom_is_stock_manager`, which is new for this module.
 */
export const USER_FIELD = {
  /**
   * Verified against the live site on 6 Aug 2026 by reading a real `User`
   * document: the complete set of custom flags there is
   * `custom_is_general_manager`, `custom_is_hr_manager`,
   * `custom_is_production_manager`. Everything below marked "not on the site"
   * was specified for this module and never created.
   */
  isGeneralManager: 'custom_is_general_manager',
  isHr: 'custom_is_hr_manager',
  isProductionManager: 'custom_is_production_manager',

  /** Not on the site yet — the Stock Manager role cannot resolve until it is. */
  isStockManager: 'custom_is_stock_manager',
  /**
   * Not on the site yet. A manager's team is meant to be every `Sales Person`
   * whose `custom_team_manager` matches this value, so without it the Sales
   * Manager role has nothing to key off.
   */
  managedTeam: 'custom_managed_team',
  /** Not on the site yet; falls back to the linked Sales Person's company. */
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
