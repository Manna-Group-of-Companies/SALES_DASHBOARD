// Minimum stock: the items management wants kept on the shelf at all times.
//
// The list is a demand-and-lead-time decision, not an age one. A product earns
// its place by moving fast enough, or by taking long enough to make, that
// running out would cost a sale. So most of what is on this list is exactly
// what a rep should be pushing.
//
// The risk is the other direction. Market trends move, and a product that
// earned its place two years ago can quietly stop selling while stock keeps
// sitting against its name. Nobody notices, because "we always keep ten of
// those" is the rule that put it there. [MinStock.daysSinceSold] is what
// catches that: an item on the list that has not been sold in months is on its
// way to being dead stock, and wants clearing before it gets there.
//
// Two reps standing in two different shops can also both be shown the same
// eight rolls. Whoever commits first should get them, and the other rep's
// screen has to stop offering them. See `services/stock_service.dart` for how
// that is enforced now the site cannot run server scripts.
//
// Rolls and loose belts are counted separately, because that is how the stock
// physically sits on the shelf. Nothing cuts a whole roll into belts to cover a
// belt shortfall.

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/models/product_category.dart';

double _num(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

int _int(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

/// Frappe sends a missing Date as null and a set one as `yyyy-MM-dd`. Both
/// arrive here as strings, so the literal 'null' has to be caught too.
String _date(dynamic v) {
  final s = '${v ?? ''}';
  return (s.isEmpty || s == 'null') ? '' : s.substring(0, 10);
}

/// Frappe sends an unset Data or Datetime as null, and string interpolation
/// turns that into the literal 'null'. Both have to read as empty.
String _clean(dynamic v) {
  final s = '${v ?? ''}'.trim();
  return (s.isEmpty || s == 'null') ? '' : s;
}

/// A `yyyy-MM-dd HH:mm:ss` stamp, trimmed to the date and minute.
String _stamp(dynamic v) {
  final s = _clean(v);
  return s.length >= 16 ? s.substring(0, 16) : s;
}

/// Quantities read better without trailing zeroes — "8 rolls", not "8.00
/// rolls" — but half a kilogram still has to survive. Shared so the order row,
/// the aging list, and the review line all round the same way.
String trimQty(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// What the server says about one minimum-stock item right now.
class MinStock {
  final String itemCode;

  /// The size of the held-back pool, in the item's stock unit — rolls for tread
  /// rubber, kilograms for bonding gum, tins for solution.
  final double minimumQty;

  /// Belts held outside whole rolls. PCTR only; zero everywhere else.
  final int minimumLooseBelts;

  /// Booked by any rep, on any order, and not yet released or delivered.
  final double reservedQty;
  final int reservedLooseBelts;

  /// Of the reserved figures, how much this rep booked. Shown separately so a
  /// rep is not confused by their own booking looking like someone else's.
  final double myReservedQty;
  final int myReservedLooseBelts;

  /// When this item last went on an order, `yyyy-MM-dd`, or empty if it never
  /// has since the list was set up.
  final String lastSoldOn;

  /// Who is holding what, one entry per rep.
  final List<StockBooking> bookings;

  final List<StockBatch> batches;

  /// How many belts one roll cuts into, from the Item master. Zero when the
  /// item is not sold in belts, or its master is incomplete — either way no
  /// roll is ever treated as cuttable.
  final int beltsPerRoll;

  /// What the production manager has told everyone is being made to refill
  /// this pool.
  ///
  /// The production order itself is raised in SAP, which this app cannot see.
  /// Without this figure a short pool looks equally short whether a run was
  /// ordered this morning or nobody has looked at it for a fortnight — so the
  /// manager records it here once, and every rep asking about the item gets
  /// the answer instead of ringing the factory.
  ///
  /// It is a statement of intent, not stock. Nothing can be booked against it
  /// and it never counts towards what is available; it becomes real when the
  /// goods arrive and a batch is created.
  final double inProductionQty;
  final int inProductionBelts;

  /// When that figure was last set, and by whom. A quantity with no date on it
  /// is worth little — "20 rolls coming" means one thing said yesterday and
  /// another said two months ago.
  final String inProductionUpdatedOn;
  final String inProductionUpdatedBy;

  /// Of the run, how much reps have already claimed.
  ///
  /// Counted apart from [reservedQty] on purpose. The two draw on different
  /// things — one on goods that exist, one on goods that do not — and adding
  /// them together is how a pool would appear to have stock it has not made
  /// yet.
  final double reservedInProductionQty;
  final int reservedInProductionBelts;

  /// The stage the run itself is on, set by the production manager.
  ///
  /// One batch is being made, not one job per order, so the stage lives on the
  /// run and every line booked against it follows. Blank until the floor
  /// touches it.
  final String productionRunStage;

  /// "10 rolls + 4 belts", or just "200 kg" where belts do not apply. Belts are
  /// only ever mentioned when there are some — on CTR, bonding gum and solution
  /// the counter is permanently zero and saying so is noise.
  String describe(double qty, int belts, String unit) {
    final head = '${trimQty(qty)} $unit';
    if (belts <= 0) return head;
    return '$head + $belts belt${belts == 1 ? '' : 's'}';
  }

  /// Days since the last sale, against the server's clock. -1 when there is no
  /// recorded sale at all, which reads differently from "sold today".
  int get daysSinceSold => lastSoldOn.isEmpty ? -1 : daysSince(lastSoldOn);

  /// True when an item that is *supposed* to be fast-moving has stopped
  /// moving. This is the dead-stock warning: the list put it on the shelf, and
  /// nothing about the list will take it off again on its own.
  bool get isDeadStockRisk {
    if (minimumQty <= 0 && minimumLooseBelts <= 0) return false;
    final d = daysSinceSold;
    return d < 0 || d >= kDeadStockDays;
  }

  /// Between healthy and dead — worth a nudge, not an alarm.
  bool get isSlowMoving {
    final d = daysSinceSold;
    return !isDeadStockRisk && d >= kSlowMovingDays;
  }

  /// What is physically in the plant — everything that has not been dispatched.
  ///
  /// Summed from the dated batches, which are the live record. [minimumQty] is
  /// not: restocking **adds a batch row** and never edits the pool upward, so
  /// the two diverge the moment stock arrives. `minimumQty` is the "keep at
  /// least this much" threshold that drives the dead-stock warnings, and
  /// nothing more.
  ///
  /// **A booking does not reduce this.** Stock a rep has booked is still on the
  /// floor until it ships, and that is exactly the number a rep needs when
  /// asking the manager to have some of it allotted to them. It falls only on
  /// dispatch.
  double get onHandQty =>
      batches.fold<double>(0, (t, b) => t + (b.qty > 0 ? b.qty : 0));

  int get onHandLooseBelts =>
      batches.fold<int>(0, (t, b) => t + (b.looseBelts > 0 ? b.looseBelts : 0));

  /// True when this item has no batch rows at all.
  ///
  /// A pool set up without a batch list has declared a threshold but recorded
  /// no stock. Reading that as zero available would take every such item off
  /// the market overnight, so those fall back to the old pool arithmetic —
  /// which is a lower number than the real shelf, so it can only ever be
  /// cautious.
  bool get _noBatchRecord => batches.isEmpty;

  /// Gross rolls and belts, before anything booked is taken off.
  double get _grossQty => _noBatchRecord ? minimumQty : onHandQty;
  int get _grossBelts => _noBatchRecord ? minimumLooseBelts : onHandLooseBelts;

  /// Rolls that have to be cut to cover the belts already booked.
  ///
  /// Booking two belts against a pool with none loose commits a whole roll —
  /// the roll leaves the roll count even though only two of its belts are
  /// spoken for. Without this the roll stayed on the shelf *and* the belts
  /// appeared from nowhere.
  int get _rollsCutForBookings =>
      rollsToOpen(reservedLooseBelts, _grossBelts, beltsPerRoll);

  /// Whole rolls a rep can still commit to.
  ///
  /// This is the number that moves when somebody books. [onHandQty] does not —
  /// the two answer different questions, and a rep needs both: "how much
  /// exists" and "how much can I promise".
  ///
  /// Never below zero, because a pool over-reserved by a race the server
  /// rejected should read as empty rather than as a negative number.
  double get availableQty {
    final left = _grossQty - reservedQty - _rollsCutForBookings;
    return left < 0 ? 0 : left;
  }

  /// Belts a rep can still commit to *without opening another roll*.
  ///
  /// Includes the remainder of any roll already cut for a booking. Four rolls
  /// at ten belts each, with three rolls and two belts booked, leaves no whole
  /// roll and eight belts — the rest of the fourth roll — not six.
  int get availableLooseBelts {
    final left = _grossBelts +
        (_rollsCutForBookings * beltsPerRoll) -
        reservedLooseBelts;
    return left < 0 ? 0 : left;
  }

  // --------------------------------------------------- the making question ---
  //
  // A rep asks "how much can I promise". The production manager asks a
  // different question — "how much do I have to make" — and it is answered off
  // the shelf, not off what is left to sell. Stock that is booked but not yet
  // dispatched is still in the building and does not need replacing.

  /// What the app believes is physically on the shelf, in the pool's unit.
  ///
  /// The same basis availability is computed from, so the two can never tell
  /// different stories about one item.
  double get shelfQty => _grossQty;
  int get shelfLooseBelts => _grossBelts;

  /// How far the shelf sits below the level management set, 0 when at or above.
  ///
  /// This is the quantity to put on a production run to restore the pool.
  /// Measured against the shelf rather than against what is available to sell:
  /// booked stock has not left yet, and making a second lot to cover it would
  /// build the same goods twice.
  double get shortfallQty {
    final short = minimumQty - shelfQty;
    return short < 0 ? 0 : short;
  }

  /// True when the shelf has fallen under the threshold and needs a run.
  bool get belowMinimum => shortfallQty > 0;

  /// True when a production run has been recorded against this pool.
  bool get hasProductionRun => inProductionQty > 0 || inProductionBelts > 0;

  // ------------------------------------------------- claiming out of a run ---
  //
  // Deliberately its own arithmetic, never merged with the shelf. A run is a
  // promise about goods that do not exist; the shelf is goods that do. The one
  // mistake that must be impossible here is a rep seeing the two added
  // together and promising a customer stock nobody has made.

  /// What is left of the run for a rep to claim.
  double get availableInProductionQty {
    final left = inProductionQty - reservedInProductionQty;
    return left < 0 ? 0 : left;
  }

  int get availableInProductionBelts {
    final left = inProductionBelts - reservedInProductionBelts;
    return left < 0 ? 0 : left;
  }

  /// True when there is a run with something still unclaimed on it.
  bool get canClaimFromRun =>
      hasProductionRun &&
      (availableInProductionQty > 0 || availableInProductionBelts > 0);

  /// True when the whole run is spoken for. The goods are still coming, but
  /// not to anybody new.
  bool get runFullyClaimed => hasProductionRun && !canClaimFromRun;

  /// What still needs ordering after the run already under way.
  ///
  /// The gap on its own says nothing about whether anybody has acted on it. A
  /// pool 20 rolls short with 20 rolls being made needs no second order, and a
  /// manager who cannot see that either orders it twice or has to remember
  /// what they did last week.
  double get uncoveredShortfallQty {
    final left = shortfallQty - inProductionQty;
    return left < 0 ? 0 : left;
  }

  /// True when the shortfall is fully covered by a run already ordered.
  bool get shortfallCovered => belowMinimum && uncoveredShortfallQty <= 0;

  /// True when nothing is left to promise, whatever is on the shelf.
  ///
  /// A separate alarm from [belowMinimum], and often the earlier one: a pool
  /// can sit exactly at its minimum and still be entirely spoken for, at which
  /// point the next rep to ask is turned away even though the shelf looks full.
  bool get fullyBooked => availableQty <= 0 && availableLooseBelts <= 0;

  /// How urgently this item needs a production run. Higher is worse.
  ///
  /// Ordering by shortfall alone would bury a fully-booked item that happens to
  /// be sitting at its minimum, which is the one a rep is about to be refused.
  int get productionUrgency {
    if (fullyBooked && belowMinimum) return 3;
    if (fullyBooked) return 2;
    if (belowMinimum) return 1;
    return 0;
  }

  /// Total belts a rep could take, counting whole rolls that would be cut.
  ///
  /// Ordering belts opens a roll: the belts asked for go out and the rest of
  /// that roll comes back as loose stock. So the belt ceiling is not just the
  /// loose ones — it is every belt in the pool.
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

  MinStock({
    required this.itemCode,
    required this.minimumQty,
    required this.reservedQty,
    required this.myReservedQty,
    this.minimumLooseBelts = 0,
    this.reservedLooseBelts = 0,
    this.myReservedLooseBelts = 0,
    this.lastSoldOn = '',
    this.bookings = const [],
    this.batches = const [],
    this.beltsPerRoll = 0,
    this.inProductionQty = 0,
    this.inProductionBelts = 0,
    this.inProductionUpdatedOn = '',
    this.inProductionUpdatedBy = '',
    this.reservedInProductionQty = 0,
    this.reservedInProductionBelts = 0,
    this.productionRunStage = '',
  });

  factory MinStock.fromJson(Map<String, dynamic> j) => MinStock(
        itemCode: '${j['item_code']}',
        minimumQty: _num(j['minimum_qty']),
        minimumLooseBelts: _int(j['minimum_loose_belts']),
        reservedQty: _num(j['reserved_qty']),
        reservedLooseBelts: _int(j['reserved_loose_belts']),
        myReservedQty: _num(j['my_reserved_qty']),
        myReservedLooseBelts: _int(j['my_reserved_loose_belts']),
        lastSoldOn: _date(j['last_sold_on']),
        bookings: ((j['bookings'] as List?) ?? const [])
            .whereType<Map>()
            .map((b) => StockBooking(
                  salesPerson: '${b['sales_person'] ?? 'Unknown'}',
                  qty: _num(b['qty']),
                  looseBelts: _int(b['loose_belts']),
                  // A booking names exactly one of the two, depending on
                  // whether the order is still against a lead.
                  salesOrder: '${b['sales_order'] ?? b['lead_order'] ?? ''}',
                ))
            .toList(),
        batches: ((j['batches'] as List?) ?? const [])
            .whereType<Map>()
            .map((b) => StockBatch.fromJson(b.cast<String, dynamic>()))
            .toList(),
        beltsPerRoll: _int(j['belts_per_roll']),
        inProductionQty: _num(j['in_production_qty']),
        inProductionBelts: _int(j['in_production_belts']),
        inProductionUpdatedOn: _stamp(j['in_production_updated_on']),
        inProductionUpdatedBy: _clean(j['in_production_updated_by']),
        reservedInProductionQty: _num(j['reserved_in_production_qty']),
        reservedInProductionBelts: _int(j['reserved_in_production_belts']),
        productionRunStage: _clean(j['production_run_stage']),
      );

  /// The oldest batch still holding stock — what a rep should be pushing.
  StockBatch? get oldestOpenBatch {
    for (final b in batches) {
      if (b.qty > 0 || b.looseBelts > 0) return b;
    }
    return null;
  }
}

/// One rep's hold on an item.
///
/// "4 booked" is not much use to a rep deciding whether to chase the last of
/// something — they want to know who has it, so they can ring them.
class StockBooking {
  final String salesPerson;
  final double qty;
  final int looseBelts;
  final String salesOrder;

  StockBooking({
    required this.salesPerson,
    required this.qty,
    required this.looseBelts,
    required this.salesOrder,
  });
}

/// A minimum-stock position together with the product it is a position in.
///
/// The pool records only an item code, which is no use to a rep deciding what
/// to push — they need the name, the packing, and what a roll weighs. Joining
/// the two here keeps the screen from having to know how either is fetched.
class MinStockDetail {
  final MinStock stock;
  final Product product;

  MinStockDetail({required this.stock, required this.product});

  String get name => product.name;
  ProductCategory get category => product.category;

  /// The pool and what is left of it, in the product's own unit — "6 of 10
  /// rolls", "40 of 60 kg".
  String get availabilityLabel =>
      '${trimQty(stock.availableQty)} of ${trimQty(stock.minimumQty)} '
      '${category.stockUnit}';
}

/// A dated slice of a minimum-stock pool.
///
/// Restocking does not top the pool back up to a single number; it adds a new
/// dated batch alongside whatever is left of the old one. That is the whole
/// point of the aging list — "8 of the original 10 from March, plus 2 restocked
/// last week" tells a rep which two to leave alone and which eight to clear.
class StockBatch {
  final String name;
  final String itemCode;

  /// When this slice came into stock, `yyyy-MM-dd`.
  final String batchDate;

  /// What is left of it.
  final double qty;
  final int looseBelts;

  /// What it held when it was created, so the row can read "8/10".
  final double originalQty;

  /// Days since [batchDate], computed by the server against its own clock so
  /// that a phone with a wrong date cannot make stock look older than it is.
  final int ageDays;

  StockBatch({
    required this.name,
    required this.itemCode,
    required this.batchDate,
    required this.qty,
    required this.originalQty,
    required this.ageDays,
    this.looseBelts = 0,
  });

  factory StockBatch.fromJson(Map<String, dynamic> j) => StockBatch(
        name: '${j['name']}',
        itemCode: '${j['item_code']}',
        batchDate: '${j['batch_date'] ?? ''}',
        qty: _num(j['qty']),
        looseBelts: _int(j['loose_belts']),
        originalQty: _num(j['original_qty']),
        ageDays: _int(j['age_days']),
      );

}
