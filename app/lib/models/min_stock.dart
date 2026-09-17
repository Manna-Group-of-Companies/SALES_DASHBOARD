// What SAP says is on the shelf for one item, expressed in what a rep sells.
//
// WHAT THIS USED TO BE, AND WHY IT IS NOT THAT ANY MORE
//
// Until 17 September 2026 this file modelled a *pool*: a minimum level
// management wanted kept on the shelf, dated batches making up what was
// actually there, and a set of reservation counters recording what each rep
// had booked against it. Availability was pool minus bookings, and the app
// enforced the arithmetic itself because the site could not run server
// scripts.
//
// All three of those inputs are gone:
//
//   * **The minimums were never used.** All 129 pool rows carried `qty = 0`.
//     Not one item on the site had a minimum set, so every alarm built on top
//     of it — below-minimum, shortfall, dead stock, replenishment urgency —
//     was computing against zero and could never fire.
//   * **The batches were a hand-typed snapshot** taken on 10 September 2026
//     during the catalogue import, and they *beat* SAP: `load()` skipped the
//     warehouse fill for any item that had a pool row, so those 129 items
//     showed a week-old hand count instead of live stock.
//   * **Booking is SAP's job now.** A sales order in SAP commits the stock the
//     moment it is placed, and the stock sync pulls back *available to
//     promise* — on hand, less what SAP has committed. Subtracting an ERPNext
//     reservation on top of that deducted the same roll twice.
//
// So the shape here is now the honest one: one figure per item, straight from
// SAP, already net of everything anyone has booked. There is nothing left for
// the app to reserve, and nothing left for it to get wrong.
//
// Rolls and loose belts are still counted separately, because that is how the
// stock physically sits on the shelf. Nothing cuts a whole roll into belts to
// cover a belt shortfall.

import 'package:manna_field_sales/models/product_category.dart';

double _num(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

int _int(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

/// Quantities read better without trailing zeroes — "8 rolls", not "8.00
/// rolls" — but half a kilogram still has to survive. Shared so the order row,
/// the aging list, and the review line all round the same way.
String trimQty(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// What SAP says is available for one item right now.
class MinStock {
  final String itemCode;

  /// Whole rolls a rep can commit to, in the item's stock unit — rolls for
  /// tread rubber, kilograms for bonding gum, tins for solution.
  ///
  /// This is **available to promise**, not what is in the building. SAP has
  /// already taken off every quantity committed to an open sales order,
  /// whoever placed it. Nothing in this app subtracts anything further.
  final double availableQty;

  /// Belts available outside whole rolls. PCTR only; zero everywhere else.
  final int availableLooseBelts;

  /// How many belts one roll cuts into, from the Item master. Zero when the
  /// item is not sold in belts, or its master is incomplete — either way no
  /// roll is ever treated as cuttable.
  final int beltsPerRoll;

  /// False when the item master has no weight-per-roll or belts-per-roll, so
  /// SAP's kilograms could not be turned into rolls.
  ///
  /// Those items are reported as nothing available, on instruction: the
  /// weights are being uploaded for the rest of the catalogue and a rep should
  /// not be quoting a figure nobody has checked in the meantime. The flag is
  /// kept apart from the quantity so a screen can say *why* it is zero — "we
  /// have not set this item up" is a different sentence from "we are out", and
  /// only one of them is worth ringing the office about.
  final bool weightsKnown;

  /// "10 rolls + 4 belts", or just "200 kg" where belts do not apply. Belts are
  /// only ever mentioned when there are some — on CTR, bonding gum and solution
  /// the counter is permanently zero and saying so is noise.
  String describe(double qty, int belts, String unit) {
    final head = '${trimQty(qty)} $unit';
    if (belts <= 0) return head;
    return '$head + $belts belt${belts == 1 ? '' : 's'}';
  }

  /// Total belts a rep could take, counting whole rolls that would be cut.
  ///
  /// Ordering belts opens a roll: the belts asked for go out and the rest of
  /// that roll comes back as loose stock. So the belt ceiling is not just the
  /// loose ones — it is every belt available.
  int beltCeiling(int beltsPerRoll) {
    if (beltsPerRoll <= 0) return availableLooseBelts;
    return availableLooseBelts + (availableQty.floor() * beltsPerRoll);
  }

  /// How many whole rolls would have to be cut to fill [belts].
  static int rollsToOpen(int belts, int looseAvailable, int beltsPerRoll) {
    final shortfall = belts - looseAvailable;
    if (shortfall <= 0 || beltsPerRoll <= 0) return 0;
    return (shortfall + beltsPerRoll - 1) ~/ beltsPerRoll;
  }

  const MinStock({
    required this.itemCode,
    required this.availableQty,
    this.availableLooseBelts = 0,
    this.beltsPerRoll = 0,
    this.weightsKnown = true,
  });

  factory MinStock.fromJson(Map<String, dynamic> j) {
    final known = j['weights_known'] != false;
    return MinStock(
      itemCode: '${j['item_code']}',
      // An item whose weights are unset reports nothing available whatever
      // arrived in the payload, so no caller can route around the rule by
      // reading the quantity directly.
      availableQty: known ? _num(j['available_qty']) : 0,
      availableLooseBelts: known ? _int(j['available_loose_belts']) : 0,
      beltsPerRoll: _int(j['belts_per_roll']),
      weightsKnown: known,
    );
  }
}

/// An availability figure together with the product it is a figure for.
///
/// SAP records only an item code, which is no use to a rep deciding what to
/// push — they need the name, the packing, and what a roll weighs. Joining the
/// two here keeps the screen from having to know how either is fetched.
class MinStockDetail {
  final MinStock stock;
  final Product product;

  MinStockDetail({required this.stock, required this.product});

  String get name => product.name;
  ProductCategory get category => product.category;

  /// What is left to sell, in the product's own unit — "6 rolls", "40 kg".
  String get availabilityLabel => stock.weightsKnown
      ? '${trimQty(stock.availableQty)} ${category.stockUnit}'
      : 'not set up';
}
