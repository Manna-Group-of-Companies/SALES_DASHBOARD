/**
 * Seed data for the mock backend.
 *
 * Shaped to look like real Manna Treads stock so every screen has something
 * meaningful to render before the Excel imports land. Replace wholesale once
 * the real product sheet arrives — nothing outside this file depends on the
 * specific codes.
 */

import type {
  AttendanceRecord,
  AttendanceStatus,
  Customer,
  Employee,
  LeaveRequest,
  MinStockItem,
  Order,
  Product,
  ProductionOrder,
  User,
} from '@/domain/types';
import { toIsoDate } from '@/domain/orderRules';
import { isWeeklyOff } from '@/domain/hrRules';

/** Days ago as an ISO date, so fixture ages stay believable over time. */
function daysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return toIsoDate(d);
}

function daysAhead(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() + n);
  return toIsoDate(d);
}

function hoursAgoIso(n: number): string {
  const d = new Date();
  d.setHours(d.getHours() - n);
  return d.toISOString();
}

// ----------------------------------------------------------------- users ---

/**
 * Sign-in credentials for the fixture backend.
 *
 * DEVELOPMENT ONLY. These exist so the app can be signed into while
 * `VITE_USE_MOCK=true` and no ERPNext site is reachable. The moment
 * `VITE_USE_MOCK=false`, this map is never consulted — authentication goes to
 * Frappe's `/api/method/login` and these passwords mean nothing.
 *
 * Do not create ERPNext accounts with these passwords.
 */
export const MOCK_CREDENTIALS: Record<string, string> = {
  'rajesh@mannarubber.com': 'Rajesh@2026',
  'anil@mannarubber.com': 'Anil@2026',
  'fahad@mannarubber.com': 'Fahad@2026',
  'meera@mannarubber.com': 'Meera@2026',
};

/**
 * Sales Reps are absent on purpose — they sign into the field-sales app, not
 * this one. Their names still appear on orders and timelines below, as data
 * that arrives with the order.
 */
export const USERS: User[] = [
  {
    id: 'U-SM-1',
    name: 'Rajesh Menon',
    email: 'rajesh@mannarubber.com',
    role: 'sales_manager',
  },
  {
    id: 'U-PM-1',
    name: 'Anil Kumar',
    email: 'anil@mannarubber.com',
    role: 'production_manager',
    productionUnit: 'Hi-Tech Pretreads',
  },
  {
    id: 'U-STK-1',
    name: 'Fahad M',
    email: 'fahad@mannarubber.com',
    role: 'stock_manager',
    productionUnit: 'Hi-Tech Pretreads',
  },
  {
    id: 'U-HR-1',
    name: 'Meera Nair',
    email: 'meera@mannarubber.com',
    role: 'hr',
  },
];

// -------------------------------------------------------------- products ---

export const PRODUCTS: Product[] = [
  // --- PCTR: average roll weight + belts per roll (1.2) --------------------
  { code: 'PCTR-140-08', name: 'Precured Tread 140mm x 8mm', category: 'PCTR', size: '140 x 8', avgWeightPerRoll: 28.5, beltsPerRoll: 6, hsnCode: '40061000', active: true },
  { code: 'PCTR-160-09', name: 'Precured Tread 160mm x 9mm', category: 'PCTR', size: '160 x 9', avgWeightPerRoll: 34.2, beltsPerRoll: 6, hsnCode: '40061000', active: true },
  { code: 'PCTR-180-10', name: 'Precured Tread 180mm x 10mm', category: 'PCTR', size: '180 x 10', avgWeightPerRoll: 42.8, beltsPerRoll: 5, hsnCode: '40061000', active: true },
  { code: 'PCTR-200-12', name: 'Precured Tread 200mm x 12mm', category: 'PCTR', size: '200 x 12', avgWeightPerRoll: 56.4, beltsPerRoll: 5, hsnCode: '40061000', active: true },
  { code: 'PCTR-220-13', name: 'Precured Tread 220mm x 13mm', category: 'PCTR', size: '220 x 13', avgWeightPerRoll: 64.0, beltsPerRoll: 4, hsnCode: '40061000', active: true },
  { code: 'PCTR-240-14', name: 'Precured Tread 240mm x 14mm', category: 'PCTR', size: '240 x 14', avgWeightPerRoll: 72.5, beltsPerRoll: 4, hsnCode: '40061000', active: true },

  // --- CTR: exact roll weight, no belts (1.3) ------------------------------
  { code: 'CTR-06-400', name: 'Conventional Tread 6mm x 400mm', category: 'CTR', size: '6 x 400', exactWeightPerRoll: 25.0, hsnCode: '40061000', active: true },
  { code: 'CTR-08-400', name: 'Conventional Tread 8mm x 400mm', category: 'CTR', size: '8 x 400', exactWeightPerRoll: 30.0, hsnCode: '40061000', active: true },
  { code: 'CTR-10-450', name: 'Conventional Tread 10mm x 450mm', category: 'CTR', size: '10 x 450', exactWeightPerRoll: 40.0, hsnCode: '40061000', active: true },
  { code: 'CTR-12-500', name: 'Conventional Tread 12mm x 500mm', category: 'CTR', size: '12 x 500', exactWeightPerRoll: 50.0, hsnCode: '40061000', active: true },

  // --- BG: 5 kg rolls, 4 to a box (1.4) ------------------------------------
  { code: 'BG-STD', name: 'Bonding Gum — Standard', category: 'BG', defaultRate: 185, hsnCode: '40059100', active: true },
  { code: 'BG-PREM', name: 'Bonding Gum — Premium', category: 'BG', defaultRate: 210, hsnCode: '40059100', active: true },

  // --- VS: two tin sizes, separate rates (1.5) -----------------------------
  { code: 'VS-10L', name: 'Vulcanizing Solution — 10L Tin', category: 'VS', tinSize: 10, defaultRate: 1450, hsnCode: '40059900', active: true },
  { code: 'VS-30L', name: 'Vulcanizing Solution — 30L Tin', category: 'VS', tinSize: 30, defaultRate: 4100, hsnCode: '40059900', active: true },
];

// ------------------------------------------------------------- customers ---

export const CUSTOMERS: Customer[] = [
  {
    id: 'CUST-0001',
    name: 'Kerala Tyre Retreaders',
    destination: 'Aluva, Ernakulam',
    address: 'Door 14/221, NH Bypass, Aluva, Ernakulam 683101',
    gstin: '32AABCK1234M1Z5',
    state: 'Kerala',
    phone: '+91 98470 11223',
    outstandingBalance: 184_500,
    creditLimit: 500_000,
    assignedReps: ['Subhash'],
  },
  {
    id: 'CUST-0002',
    name: 'Malabar Tread Works',
    destination: 'Kozhikode',
    address: '3/78 Mavoor Road, Kozhikode 673004',
    gstin: '32AACFM5566P1ZQ',
    state: 'Kerala',
    phone: '+91 94470 55667',
    outstandingBalance: 462_000,
    creditLimit: 450_000,
    assignedReps: ['Subhash'],
  },
  {
    id: 'CUST-0003',
    name: 'Coimbatore Retread Centre',
    destination: 'Coimbatore, TN',
    address: '221 Avinashi Road, Coimbatore 641018',
    gstin: '33AAGCC7788R1ZL',
    state: 'Tamil Nadu',
    phone: '+91 98430 77889',
    outstandingBalance: 92_300,
    creditLimit: 600_000,
    assignedReps: ['Vineeth'],
  },
  {
    id: 'CUST-0004',
    name: 'Trichur Tyre House',
    destination: 'Thrissur',
    address: 'Round South, Thrissur 680001',
    gstin: '32AADFT9900K1ZB',
    state: 'Kerala',
    outstandingBalance: 0,
    creditLimit: 250_000,
    assignedReps: ['Subhash', 'Vineeth'],
  },
  {
    id: 'CUST-0005',
    name: 'Bangalore Tread Supply Co',
    destination: 'Peenya, Bengaluru',
    address: 'Plot 42, Peenya Industrial Area, Bengaluru 560058',
    gstin: '29AAECB2233N1ZY',
    state: 'Karnataka',
    outstandingBalance: 311_000,
    creditLimit: 750_000,
    assignedReps: ['Vineeth'],
  },
];

// ---------------------------------------------------------- minimum stock ---

/**
 * Only some items are kept as minimum stock. Anything absent from this list
 * shows "No minimum stock" on the order row (1.2).
 *
 * `PCTR-160-09` is deliberately seeded split across an old and a fresh batch so
 * the "8/10 from an older date, 2 newly restocked" case from 1.6 is visible on
 * first load. `PCTR-220-13` sits below its threshold to exercise the low-stock
 * alert (3.5).
 */
export const MIN_STOCK: MinStockItem[] = [
  {
    itemCode: 'PCTR-140-08',
    itemName: 'Precured Tread 140mm x 8mm',
    category: 'PCTR',
    uom: 'Kg',
    threshold: 900,
    onHand: 1_140,
    reserved: 0,
    lastRestockedOn: daysAgo(12),
    batches: [
      { id: 'B-1401', stockedOn: daysAgo(95), remaining: 425, original: 600 },
      { id: 'B-1402', stockedOn: daysAgo(12), remaining: 715, original: 715 },
    ],
  },
  {
    itemCode: 'PCTR-160-09',
    itemName: 'Precured Tread 160mm x 9mm',
    category: 'PCTR',
    uom: 'Kg',
    threshold: 342,
    onHand: 342,
    reserved: 0,
    lastRestockedOn: daysAgo(4),
    batches: [
      // 8 rolls' worth from the old lot, 2 rolls newly restocked.
      { id: 'B-1601', stockedOn: daysAgo(138), remaining: 273.6, original: 342 },
      { id: 'B-1602', stockedOn: daysAgo(4), remaining: 68.4, original: 68.4 },
    ],
  },
  {
    itemCode: 'PCTR-180-10', itemName: 'Precured Tread 180mm x 10mm',
    category: 'PCTR', uom: 'Kg', threshold: 800, onHand: 968, reserved: 0,
    lastRestockedOn: daysAgo(30),
    batches: [
      { id: 'B-1801', stockedOn: daysAgo(72), remaining: 326, original: 500 },
      { id: 'B-1802', stockedOn: daysAgo(30), remaining: 642, original: 642 },
    ],
  },
  {
    itemCode: 'PCTR-220-13', itemName: 'Precured Tread 220mm x 13mm',
    category: 'PCTR', uom: 'Kg', threshold: 640, onHand: 384, reserved: 0,
    lastRestockedOn: daysAgo(61),
    batches: [{ id: 'B-2201', stockedOn: daysAgo(61), remaining: 384, original: 640 }],
  },
  {
    itemCode: 'CTR-08-400', itemName: 'Conventional Tread 8mm x 400mm',
    category: 'CTR', uom: 'Kg', threshold: 600, onHand: 750, reserved: 0,
    lastRestockedOn: daysAgo(18),
    batches: [
      { id: 'B-C0801', stockedOn: daysAgo(110), remaining: 210, original: 450 },
      { id: 'B-C0802', stockedOn: daysAgo(18), remaining: 540, original: 540 },
    ],
  },
  {
    itemCode: 'CTR-10-450', itemName: 'Conventional Tread 10mm x 450mm',
    category: 'CTR', uom: 'Kg', threshold: 400, onHand: 440, reserved: 0,
    lastRestockedOn: daysAgo(9),
    batches: [{ id: 'B-C1001', stockedOn: daysAgo(9), remaining: 440, original: 440 }],
  },
  {
    itemCode: 'BG-STD', itemName: 'Bonding Gum — Standard',
    category: 'BG', uom: 'Kg', threshold: 300, onHand: 260, reserved: 0,
    lastRestockedOn: daysAgo(45),
    batches: [
      { id: 'B-BG01', stockedOn: daysAgo(128), remaining: 80, original: 200 },
      { id: 'B-BG02', stockedOn: daysAgo(45), remaining: 180, original: 180 },
    ],
  },
  {
    itemCode: 'VS-10L', itemName: 'Vulcanizing Solution — 10L Tin',
    category: 'VS', uom: 'L', threshold: 500, onHand: 620, reserved: 0,
    lastRestockedOn: daysAgo(21),
    batches: [{ id: 'B-VS01', stockedOn: daysAgo(21), remaining: 620, original: 700 }],
  },
];

// ------------------------------------------------------- production orders ---

export const PRODUCTION_ORDERS: ProductionOrder[] = [
  {
    id: 'PROD-0001',
    itemCode: 'PCTR-220-13',
    itemName: 'Precured Tread 220mm x 13mm',
    qty: 256,
    raisedAt: hoursAgoIso(30),
    raisedBy: 'Anil Kumar',
    status: 'open',
    reason: 'replenishment',
  },
];

// ---------------------------------------------------------------- orders ---

/**
 * A handful of orders spread across the lifecycle so every board has rows on
 * first load: one waiting for the manager, one on the floor mid-cycle, one
 * dispatched and ready to be compiled into a weekly group.
 */
export const ORDERS: Order[] = [
  {
    id: 'SO-2026-0031',
    orderNo: 'SO-2026-0031',
    customerId: 'CUST-0001',
    customerName: 'Kerala Tyre Retreaders',
    destination: 'Aluva, Ernakulam',
    repId: 'U-REP-1',
    repName: 'Subhash R',
    status: 'pending_approval',
    deliveryDate: daysAhead(6),
    createdAt: hoursAgoIso(20),
    proformaGenerated: true,
    proformaNo: 'PF-2026-0031',
    items: [
      {
        id: 'IT-1', itemCode: 'PCTR-140-08', itemName: 'Precured Tread 140mm x 8mm',
        category: 'PCTR', rolls: 12, looseBelts: 3, quantity: 356.25, uom: 'Kg',
        quotedRate: 262, rateLocked: false,
      },
      {
        id: 'IT-2', itemCode: 'BG-STD', itemName: 'Bonding Gum — Standard',
        category: 'BG', kg: 60, quantity: 60, uom: 'Kg', quotedRate: 185, rateLocked: false,
      },
    ],
    timeline: [
      {
        id: 'TL-1', at: hoursAgoIso(20), actorId: 'U-REP-1', actorName: 'Subhash R',
        actorRole: 'sales_rep', action: 'Order created',
        detail: '2 items · proforma PF-2026-0031 generated',
      },
      {
        id: 'TL-2', at: hoursAgoIso(20), actorId: 'U-REP-1', actorName: 'Subhash R',
        actorRole: 'sales_rep', action: 'Sent for approval',
      },
    ],
  },
  {
    id: 'SO-2026-0028',
    orderNo: 'SO-2026-0028',
    customerId: 'CUST-0003',
    customerName: 'Coimbatore Retread Centre',
    destination: 'Coimbatore, TN',
    repId: 'U-REP-2',
    repName: 'Vineeth K',
    status: 'in_production',
    deliveryDate: daysAhead(3),
    createdAt: hoursAgoIso(96),
    approvedAt: hoursAgoIso(84),
    approvedBy: 'Rajesh Menon',
    proformaGenerated: true,
    proformaNo: 'PF-2026-0028',
    items: [
      {
        id: 'IT-3', itemCode: 'CTR-10-450', itemName: 'Conventional Tread 10mm x 450mm',
        category: 'CTR', rolls: 20, quantity: 800, uom: 'Kg',
        quotedRate: 240, finalRate: 236, rateLocked: true,
        source: 'new_production', stage: 'calendering', stageUpdatedAt: hoursAgoIso(10),
      },
      {
        id: 'IT-4', itemCode: 'VS-30L', itemName: 'Vulcanizing Solution — 30L Tin',
        category: 'VS', tins: 4, tinSize: 30, quantity: 120, uom: 'L',
        quotedRate: 4100, finalRate: 4100, rateLocked: true,
        source: 'min_stock', stage: 'qc', stageUpdatedAt: hoursAgoIso(5),
      },
    ],
    timeline: [
      { id: 'TL-3', at: hoursAgoIso(96), actorId: 'U-REP-2', actorName: 'Vineeth K', actorRole: 'sales_rep', action: 'Order created' },
      { id: 'TL-4', at: hoursAgoIso(84), actorId: 'U-SM-1', actorName: 'Rajesh Menon', actorRole: 'sales_manager', action: 'Approved', detail: 'Rates finalised and locked' },
      { id: 'TL-5', at: hoursAgoIso(60), actorId: 'U-PM-1', actorName: 'Anil Kumar', actorRole: 'production_manager', action: 'Production started' },
    ],
  },
  {
    id: 'SO-2026-0024',
    orderNo: 'SO-2026-0024',
    customerId: 'CUST-0001',
    customerName: 'Kerala Tyre Retreaders',
    destination: 'Aluva, Ernakulam',
    repId: 'U-REP-1',
    repName: 'Subhash R',
    status: 'dispatched',
    deliveryDate: daysAgo(2),
    createdAt: hoursAgoIso(220),
    approvedAt: hoursAgoIso(210),
    approvedBy: 'Rajesh Menon',
    dispatchedAt: hoursAgoIso(40),
    proformaGenerated: false,
    items: [
      {
        id: 'IT-5', itemCode: 'PCTR-180-10', itemName: 'Precured Tread 180mm x 10mm',
        category: 'PCTR', rolls: 8, looseBelts: 0, quantity: 342.4, uom: 'Kg',
        quotedRate: 268, finalRate: 265, rateLocked: true,
        source: 'min_stock', stage: 'ready', stageUpdatedAt: hoursAgoIso(44),
      },
    ],
    timeline: [
      { id: 'TL-6', at: hoursAgoIso(220), actorId: 'U-REP-1', actorName: 'Subhash R', actorRole: 'sales_rep', action: 'Order created' },
      { id: 'TL-7', at: hoursAgoIso(210), actorId: 'U-SM-1', actorName: 'Rajesh Menon', actorRole: 'sales_manager', action: 'Approved' },
      { id: 'TL-8', at: hoursAgoIso(40), actorId: 'U-PM-1', actorName: 'Anil Kumar', actorRole: 'production_manager', action: 'Dispatched' },
    ],
  },
  {
    id: 'SO-2026-0022',
    orderNo: 'SO-2026-0022',
    customerId: 'CUST-0001',
    customerName: 'Kerala Tyre Retreaders',
    destination: 'Aluva, Ernakulam',
    repId: 'U-REP-1',
    repName: 'Subhash R',
    status: 'dispatched',
    deliveryDate: daysAgo(4),
    createdAt: hoursAgoIso(280),
    approvedAt: hoursAgoIso(270),
    approvedBy: 'Rajesh Menon',
    dispatchedAt: hoursAgoIso(64),
    proformaGenerated: true,
    proformaNo: 'PF-2026-0022',
    items: [
      {
        id: 'IT-6', itemCode: 'BG-PREM', itemName: 'Bonding Gum — Premium',
        category: 'BG', kg: 80, quantity: 80, uom: 'Kg',
        quotedRate: 210, finalRate: 208, rateLocked: true,
        source: 'new_production', stage: 'ready', stageUpdatedAt: hoursAgoIso(68),
      },
    ],
    timeline: [
      { id: 'TL-9', at: hoursAgoIso(280), actorId: 'U-REP-1', actorName: 'Subhash R', actorRole: 'sales_rep', action: 'Order created' },
      { id: 'TL-10', at: hoursAgoIso(270), actorId: 'U-SM-1', actorName: 'Rajesh Menon', actorRole: 'sales_manager', action: 'Approved' },
      { id: 'TL-11', at: hoursAgoIso(64), actorId: 'U-PM-1', actorName: 'Anil Kumar', actorRole: 'production_manager', action: 'Dispatched' },
    ],
  },
];

// ------------------------------------------------------------- employees ---

/**
 * The people on the books. The four who also have a login *here* are joined to
 * it by `userId`; everyone else — most of the floor, and the reps, who log into
 * the field-sales app instead — exists only here, which is the whole reason
 * `Employee` is not `User`.
 */
export const EMPLOYEES: Employee[] = [
  // --- Sales ---------------------------------------------------------------
  { id: 'HR-EMP-0001', name: 'Rajesh Menon', designation: 'Sales Manager', department: 'Sales', employmentType: 'permanent', joinedOn: daysAgo(2860), phone: '98470 11201', email: 'rajesh@mannarubber.com', location: 'Head Office', userId: 'U-SM-1', leaveBalance: 12 },
  { id: 'HR-EMP-0002', name: 'Subhash R', designation: 'Sales Representative', department: 'Sales', employmentType: 'permanent', joinedOn: daysAgo(1490), phone: '98470 11202', email: 'subhash@mannarubber.com', location: 'Ernakulam', reportsTo: 'HR-EMP-0001', leaveBalance: 8 },
  { id: 'HR-EMP-0003', name: 'Vineeth K', designation: 'Sales Representative', department: 'Sales', employmentType: 'permanent', joinedOn: daysAgo(1105), phone: '98470 11203', email: 'vineeth@mannarubber.com', location: 'Thrissur', reportsTo: 'HR-EMP-0001', leaveBalance: 15 },
  { id: 'HR-EMP-0004', name: 'Jaseem P A', designation: 'Sales Representative', department: 'Sales', employmentType: 'permanent', joinedOn: daysAgo(620), phone: '98470 11204', location: 'Kozhikode', reportsTo: 'HR-EMP-0001', leaveBalance: 11 },
  { id: 'HR-EMP-0005', name: 'Deepa Suresh', designation: 'Sales Coordinator', department: 'Sales', employmentType: 'permanent', joinedOn: daysAgo(58), phone: '98470 11205', location: 'Head Office', reportsTo: 'HR-EMP-0001', leaveBalance: 3 },

  // --- Production ----------------------------------------------------------
  { id: 'HR-EMP-0006', name: 'Anil Kumar', designation: 'Production Manager', department: 'Production', employmentType: 'permanent', joinedOn: daysAgo(3290), phone: '98470 11206', email: 'anil@mannarubber.com', location: 'Hi-Tech Pretreads', userId: 'U-PM-1', leaveBalance: 18 },
  { id: 'HR-EMP-0007', name: 'Shibu Varghese', designation: 'Shift Supervisor', department: 'Production', employmentType: 'permanent', joinedOn: daysAgo(2190), phone: '98470 11207', location: 'Hi-Tech Pretreads', reportsTo: 'HR-EMP-0006', leaveBalance: 9 },
  { id: 'HR-EMP-0008', name: 'Ramesh Babu', designation: 'Mill Operator', department: 'Production', employmentType: 'permanent', joinedOn: daysAgo(1825), phone: '98470 11208', location: 'Hi-Tech Pretreads', reportsTo: 'HR-EMP-0007', leaveBalance: 6 },
  { id: 'HR-EMP-0009', name: 'Sunil Joseph', designation: 'Press Operator', department: 'Production', employmentType: 'permanent', joinedOn: daysAgo(1460), phone: '98470 11209', location: 'Hi-Tech Pretreads', reportsTo: 'HR-EMP-0007', leaveBalance: 14 },
  { id: 'HR-EMP-0010', name: 'Nishad A', designation: 'Press Operator', department: 'Production', employmentType: 'contract', joinedOn: daysAgo(365), phone: '98470 11210', location: 'Hi-Tech Pretreads', reportsTo: 'HR-EMP-0007', leaveBalance: 4 },
  { id: 'HR-EMP-0011', name: 'Praveen T', designation: 'Curing Helper', department: 'Production', employmentType: 'contract', joinedOn: daysAgo(240), phone: '98470 11211', location: 'Hi-Tech Pretreads', reportsTo: 'HR-EMP-0007', leaveBalance: 2 },
  { id: 'HR-EMP-0012', name: 'Arjun Das', designation: 'Trainee Operator', department: 'Production', employmentType: 'apprentice', joinedOn: daysAgo(34), phone: '98470 11212', location: 'Hi-Tech Pretreads', reportsTo: 'HR-EMP-0007', leaveBalance: 1 },

  // --- Stock ---------------------------------------------------------------
  { id: 'HR-EMP-0013', name: 'Fahad M', designation: 'Stock Manager', department: 'Stock', employmentType: 'permanent', joinedOn: daysAgo(1680), phone: '98470 11213', email: 'fahad@mannarubber.com', location: 'Hi-Tech Pretreads', userId: 'U-STK-1', leaveBalance: 10 },
  { id: 'HR-EMP-0014', name: 'Bijoy Thomas', designation: 'Store Keeper', department: 'Stock', employmentType: 'permanent', joinedOn: daysAgo(940), phone: '98470 11214', location: 'Hi-Tech Pretreads', reportsTo: 'HR-EMP-0013', leaveBalance: 7 },

  // --- Accounts ------------------------------------------------------------
  { id: 'HR-EMP-0015', name: 'Lakshmi Menon', designation: 'Accountant', department: 'Accounts', employmentType: 'permanent', joinedOn: daysAgo(2555), phone: '98470 11215', location: 'Head Office', leaveBalance: 13 },
  { id: 'HR-EMP-0016', name: 'Anoop Krishnan', designation: 'Accounts Assistant', department: 'Accounts', employmentType: 'permanent', joinedOn: daysAgo(730), phone: '98470 11216', location: 'Head Office', reportsTo: 'HR-EMP-0015', leaveBalance: 9 },

  // --- Administration ------------------------------------------------------
  { id: 'HR-EMP-0017', name: 'Meera Nair', designation: 'HR Executive', department: 'Administration', employmentType: 'permanent', joinedOn: daysAgo(1200), phone: '98470 11217', email: 'meera@mannarubber.com', location: 'Head Office', userId: 'U-HR-1', leaveBalance: 16 },
  { id: 'HR-EMP-0018', name: 'Vinod Pillai', designation: 'Driver', department: 'Administration', employmentType: 'permanent', joinedOn: daysAgo(1550), phone: '98470 11218', location: 'Head Office', reportsTo: 'HR-EMP-0017', leaveBalance: 5 },

  // Relieved — kept on file, out of the headcount.
  { id: 'HR-EMP-0019', name: 'Sajeev Kumar', designation: 'Press Operator', department: 'Production', employmentType: 'permanent', joinedOn: daysAgo(2100), leftOn: daysAgo(45), location: 'Hi-Tech Pretreads', leaveBalance: 0 },
];

// ------------------------------------------------------------ attendance ---

/**
 * A fortnight of marked attendance.
 *
 * Deterministic rather than random: the same fixture on every reload means a
 * screenshot of the dashboard keeps meaning the same thing. Today is left
 * partly unmarked on purpose — that is the state HR actually opens the app in.
 */
function patternFor(index: number, daysBack: number): AttendanceStatus {
  const n = (index * 7 + daysBack * 3) % 23;
  if (n === 0) return 'absent';
  if (n === 5) return 'on_leave';
  if (n === 11) return 'half_day';
  return 'present';
}

function buildAttendance(): AttendanceRecord[] {
  const rows: AttendanceRecord[] = [];

  for (let back = 13; back >= 0; back -= 1) {
    const date = daysAgo(back);
    const off = isWeeklyOff(date);

    EMPLOYEES.forEach((employee, index) => {
      if (employee.joinedOn > date) return;
      if (employee.leftOn && employee.leftOn <= date) return;
      // The tail of the list is left unmarked for today, so the dashboard has a
      // real "not marked yet" number to show rather than a tidy zero.
      if (back === 0 && index >= EMPLOYEES.length - 3) return;

      const status = off ? 'holiday' : patternFor(index, back);
      const worked = status === 'present' || status === 'half_day';

      rows.push({
        id: `ATT-${date}-${employee.id}`,
        employeeId: employee.id,
        date,
        status,
        checkIn: worked ? ['08:52', '08:58', '09:03', '09:11'][index % 4] : undefined,
        checkOut: status === 'present' ? ['17:34', '17:40', '18:05', '17:12'][index % 4] : status === 'half_day' ? '13:00' : undefined,
        markedBy: off ? undefined : 'Meera Nair',
      });
    });
  }

  return rows;
}

export const ATTENDANCE: AttendanceRecord[] = buildAttendance();

// ----------------------------------------------------------------- leave ---

export const LEAVE_REQUESTS: LeaveRequest[] = [
  // --- pending: what HR opens the app to decide ---------------------------
  {
    id: 'LV-0007',
    employeeId: 'HR-EMP-0009',
    employeeName: 'Sunil Joseph',
    department: 'Production',
    type: 'earned',
    fromDate: daysAhead(6),
    toDate: daysAhead(10),
    days: 5,
    reason: 'Family function at home. Cover arranged with Nishad for the press.',
    status: 'pending',
    appliedAt: hoursAgoIso(20),
  },
  {
    id: 'LV-0008',
    // Overlaps LV-0007, same department — the clash the queue warns about.
    employeeId: 'HR-EMP-0010',
    employeeName: 'Nishad A',
    department: 'Production',
    type: 'casual',
    fromDate: daysAhead(8),
    toDate: daysAhead(9),
    days: 2,
    reason: 'Personal work.',
    status: 'pending',
    appliedAt: hoursAgoIso(6),
  },
  {
    id: 'LV-0009',
    employeeId: 'HR-EMP-0005',
    employeeName: 'Deepa Suresh',
    department: 'Sales',
    type: 'sick',
    fromDate: daysAhead(1),
    toDate: daysAhead(2),
    days: 2,
    reason: 'Viral fever, doctor advised two days rest.',
    status: 'pending',
    appliedAt: hoursAgoIso(3),
  },

  // --- decided: history, so the queue is not the whole story ---------------
  {
    id: 'LV-0006',
    employeeId: 'HR-EMP-0003',
    employeeName: 'Vineeth K',
    department: 'Sales',
    type: 'casual',
    fromDate: daysAgo(2),
    toDate: daysAgo(1),
    days: 2,
    reason: 'House shifting.',
    status: 'approved',
    appliedAt: hoursAgoIso(190),
    decidedAt: hoursAgoIso(180),
    decidedBy: 'Meera Nair',
  },
  {
    id: 'LV-0005',
    employeeId: 'HR-EMP-0011',
    employeeName: 'Praveen T',
    department: 'Production',
    type: 'unpaid',
    fromDate: daysAgo(9),
    toDate: daysAgo(5),
    days: 5,
    reason: 'Went home to the village.',
    status: 'approved',
    appliedAt: hoursAgoIso(320),
    decidedAt: hoursAgoIso(300),
    decidedBy: 'Meera Nair',
  },
  {
    id: 'LV-0004',
    employeeId: 'HR-EMP-0008',
    employeeName: 'Ramesh Babu',
    department: 'Production',
    type: 'earned',
    fromDate: daysAgo(12),
    toDate: daysAgo(4),
    days: 8,
    reason: "Wanted to carry forward last year's balance.",
    status: 'rejected',
    appliedAt: hoursAgoIso(420),
    decidedAt: hoursAgoIso(400),
    decidedBy: 'Meera Nair',
    decisionNote: 'Only 6 days of balance left. Reapply for a shorter period.',
  },
  {
    id: 'LV-0003',
    employeeId: 'HR-EMP-0014',
    employeeName: 'Bijoy Thomas',
    department: 'Stock',
    type: 'sick',
    fromDate: daysAgo(20),
    toDate: daysAgo(19),
    days: 2,
    reason: 'Dengue.',
    status: 'approved',
    appliedAt: hoursAgoIso(520),
    decidedAt: hoursAgoIso(515),
    decidedBy: 'Meera Nair',
  },
];
