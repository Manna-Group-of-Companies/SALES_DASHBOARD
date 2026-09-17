


// ===== Proforma letterhead =====
//
// The name only. The address, GST number, PAN and bank details still belong to
// the same registered entity and are deliberately unchanged — this is what the
// document is headed, not who it is issued by.
const String kCoName = 'MANNA TREADS';
const String kCoAddress =
    'VIII/67-C, PVIP Canal Road Keezhillam\nErnakulam-683541\nKerala, India';
const String kCoGST = '32AEJPM5698B1ZF';
const String kCoPAN = 'AEJPM5698B';
const String kCoPhone = '';
const String kBankName = 'CANARA BANK';
const String kBankBranch = 'M G Road Ernakulam';
const String kBankAcc = '125002176279';
const String kBankIFSC = 'CNRB0014301';

/// The UPI address printed on the proforma as a QR code.
///
/// Supplied 11 September 2026 as a photograph of the BHIM QR card. The code on
/// the proforma is GENERATED from this string, never a copy of that photo: a
/// scan of a printout of a QR is grey, skewed and often unreadable by a phone
/// camera, and a payment QR that will not scan in front of a customer is worse
/// than none at all.
///
/// VERIFY THIS AGAINST THE BANK CARD BEFORE IT REACHES A CUSTOMER. It was read
/// off an image, and one wrong character sends money to a stranger.
const String kUpiVpa = 'pos.5126391@indus';
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
// served off the shelf and gets their order quickly, while everyone else waits
// for a production run.
//
// It is a note for the floor and nothing else. Until 17 September 2026 picking
// new production also released whatever the order was holding, so the label
// moved stock; SAP commits stock against its own sales order now, and no label
// in this app moves a roll.
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

/// How often the order screen re-reads what is available while it is open.
///
/// The shelf is shared with every other rep, and with everyone raising orders
/// in SAP directly, so a row that says "3 available" has to stop saying that
/// once they have gone. Ten seconds is the app's side of it; the figure itself
/// is only as fresh as the five-minute SAP stock sync behind it.
const Duration kStockRefreshInterval = Duration(seconds: 10);
// ================================================================================
