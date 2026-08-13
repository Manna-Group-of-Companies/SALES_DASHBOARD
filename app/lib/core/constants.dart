


// ===== Proforma letterhead - Hi-Tech Pretreads (other companies' formats later) =====
const String kCoName = 'HI-TECH PRETREADS';
const String kCoAddress =
    'VIII/67-C, PVIP Canal Road Keezhillam\nErnakulam-683541\nKerala, India';
const String kCoGST = '32AEJPM5698B1ZF';
const String kCoPAN = 'AEJPM5698B';
const String kCoPhone = '';
const String kBankName = 'CANARA BANK';
const String kBankBranch = 'M G Road Ernakulam';
const String kBankAcc = '125002176279';
const String kBankIFSC = 'CNRB0014301';
const String kDefaultHSN = '40061000';
const String kJurisdiction = 'SUBJECT TO PERUMBAVOOR JURISDICTION';
// ================================================================================

// ===== Business units =====
//
// `Sales Person.custom_company` puts a rep in one of three units. They are not
// ERPNext Companies — those are only Manna Rubber Products Private Limited and
// Manna Rubber UAE — they are the trading units the field is organised into.
//
// Minimum stock, the product families, and everything else Phase 1 added are
// Manna Treads' way of working. Retreads and UAE run a different process
// entirely, so those screens stay hidden from them rather than showing an empty
// version of something that does not apply.
const String kUnitTreads = 'Manna Treads';
const String kUnitRetreads = 'Manna Tyre Retreads';
const String kUnitUae = 'Manna Tyres UAE';

// The ERPNext Companies those units book into. There are only two, and they
// carry different currencies — rupees for the Indian business, dirhams for the
// UAE one — so getting this wrong does not just misfile an order, it runs it
// through a currency conversion nobody asked for.
const String kCompanyIndia = 'Manna Rubber Products Private Limited';
const String kCompanyUae = 'Manna Rubber UAE';

/// Which company a unit's orders belong to. Only the UAE unit sells out of the
/// dirham company; Treads and Retreads are both the Indian business.
String companyForUnit(String? unit) =>
    unit == kUnitUae ? kCompanyUae : kCompanyIndia;

// ===== Product families =====
//
// An Item's `item_group` decides which order row a rep is shown. These are
// matched case-insensitively, so the product import only has to get the words
// right, not the capitalisation. An item group that matches none of them still
// sells — it just falls back to a plain quantity-and-rate row.
//
// Precured and Hot Rubber are the names the item master already uses, and the
// several hundred items filed under them are the reason: renaming the groups
// would mean re-tagging every one of those items to gain nothing.
const String kGroupPctr = 'PRECURED';
const String kGroupCtr = 'HOT RUBBER';
const String kGroupBondingGum = 'BONDING GUM';
const String kGroupVulcanizing = 'VULCANIZING SOLUTION';

// Bonding gum is packed to a fixed scheme rather than per-Item, so the two
// numbers live here instead of on every Item record. Ordering in boxes and
// whole rolls is what keeps every BG line a multiple of 5 kg.
const int kBgRollsPerBox = 4;
const double kBgKgPerRoll = 5;

// How the sales manager decided an order will be served. Stored on the Sales
// Order as `custom_fulfilment_mode`.
//
// The choice is a priority call, not a logistics one: an important customer is
// served out of minimum stock and gets their order quickly, while everyone else
// waits for a production run. Picking new production also releases whatever the
// order was holding, so the pool goes back to whoever needs it sooner.
const String kFulfilMinimumStock = 'From Minimum Stock';
const String kFulfilNewProduction = 'New Production';

// A third answer, between the other two.
//
// The goods are not on the shelf, so they cannot come from minimum stock; but
// they are already being made against a run the production manager has raised
// in SAP, so the customer is not waiting for a decision either. A rep can claim
// out of that run, and everyone downstream can see the claim is against goods
// that do not exist yet.
const String kFulfilProductionRun = 'From Production Run';

// Which pool a reservation drew on, stored on `Manna Stock Reservation` as
// `custom_source`. Kept apart from the fulfilment mode above: the mode is what
// the sales side decided, this is what the stock system actually did.
const String kSourceShelf = 'Shelf';
const String kSourceProductionRun = 'Production Run';

// Dead-stock thresholds.
//
// Everything on the minimum-stock list is there because management expects it
// to move. These two numbers are how the app notices when one of them has
// stopped: a fast-moving item that has not sold in a quarter is not fast-moving
// any more, whatever the list says, and is on its way to being written off.
const int kSlowMovingDays = 60;
const int kDeadStockDays = 120;

/// How often the order screen re-reads booked quantities while it is open.
/// Minimum stock is shared across every rep in the field, so a row that says
/// "3 available" has to stop saying that within seconds of someone else
/// taking them.
const Duration kStockRefreshInterval = Duration(seconds: 10);
// ================================================================================
