// What a rep travelled and spent, added up.
//
// Kept out of the screen so the arithmetic can be tested without a network or
// a widget, and because it decides money: a rep reads these figures before
// asking to be paid.
//
// The one judgement here is what "shared" means. A trip with colleagues tagged
// on it is one cost between several people. Every one of them sees the trip in
// their own summary, so folding its whole amount into each of their totals
// would count the same money once per person on board. The totals therefore
// keep shared apart from own, and the screen labels it.

/// A number as Frappe might hand it back — a num, a numeric string, or null.
double expenseNum(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

/// Distance for one trip.
///
/// The odometer delta is what gets paid when it is there, because it is a
/// reading off the vehicle rather than a figure somebody typed. The entered
/// total is the fallback.
double tripKm(Map<String, dynamic> t) {
  final odo = expenseNum(t['odometer_distance_km']);
  return odo > 0 ? odo : expenseNum(t['total_distance_km']);
}

/// The travel allowance for a trip — distance times the vehicle's rate.
///
/// Held in `estimated_cost` despite the name. It is not a guess at what the
/// rep spent: it is computed off the legs and the trip rates, and it is money
/// owed.
double tripTravelAllowance(Map<String, dynamic> t) =>
    expenseNum(t['estimated_cost']);

/// What the rep paid out of pocket on a trip — food, tolls, parking.
double tripOutOfPocket(Map<String, dynamic> t) =>
    expenseNum(t['total_expenses']);

/// What one trip comes to in total.
///
/// The allowance and the out-of-pocket expenses **add up**; they are not two
/// readings of the same number. Treating them as alternatives would drop a
/// rep's entire mileage on any day they also bought lunch. This matches the
/// trip detail and HR expense screens, which must not disagree with this one
/// about what a rep is owed.
///
/// `final_cost` overrides both once somebody has settled the trip by hand.
double tripCost(Map<String, dynamic> t) {
  final settled = expenseNum(t['final_cost']);
  if (settled > 0) return settled;
  return tripTravelAllowance(t) + tripOutOfPocket(t);
}

/// True when a trip's cost is split with other reps.
///
/// Read off `tagged_csv`, which is empty on a solo trip. Frappe hands an unset
/// field back as null, '' or the string 'null' depending on how it was written,
/// so all three are treated as nobody tagged.
bool isSharedTrip(Map<String, dynamic> t) {
  final csv = '${t['tagged_csv'] ?? ''}'.trim();
  return csv.isNotEmpty && csv != 'null';
}

/// A period's travel and spend, with the shared part kept separate.
class ExpenseTotals {
  final int trips;

  /// Trips this rep made alone.
  final double ownKm;
  final double ownCost;

  /// Trips shared with other reps — the same money appears in their summaries
  /// too, so it is never merged into the own figures.
  final double sharedKm;
  final double sharedCost;

  /// The whole period split by what the money is, rather than who it is with.
  /// A rep queries these two separately: the allowance is arithmetic off the
  /// odometer, the out-of-pocket is receipts they are holding.
  final double travelAllowance;
  final double outOfPocket;

  const ExpenseTotals({
    required this.trips,
    required this.ownKm,
    required this.ownCost,
    required this.sharedKm,
    required this.sharedCost,
    required this.travelAllowance,
    required this.outOfPocket,
  });

  double get totalKm => ownKm + sharedKm;
  double get totalCost => ownCost + sharedCost;
  bool get hasShared => sharedKm > 0 || sharedCost > 0;
}

/// Adds up a period's trips.
ExpenseTotals sumExpenses(Iterable<Map<String, dynamic>> trips) {
  var n = 0;
  var ownKm = 0.0, ownCost = 0.0, sharedKm = 0.0, sharedCost = 0.0;
  var allowance = 0.0, pocket = 0.0;
  for (final t in trips) {
    n++;
    allowance += tripTravelAllowance(t);
    pocket += tripOutOfPocket(t);
    if (isSharedTrip(t)) {
      sharedKm += tripKm(t);
      sharedCost += tripCost(t);
    } else {
      ownKm += tripKm(t);
      ownCost += tripCost(t);
    }
  }
  return ExpenseTotals(
    trips: n,
    ownKm: ownKm,
    ownCost: ownCost,
    sharedKm: sharedKm,
    sharedCost: sharedCost,
    travelAllowance: allowance,
    outOfPocket: pocket,
  );
}

/// A figure as a rep would read it — no trailing `.00` on whole numbers.
String money(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
