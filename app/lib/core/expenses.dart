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

// ---------------------------------------------------- shared-trip expenses ---

/// Whose money an expense on a shared trip was.
///
/// One rep raises the trip and tags the colleagues who travelled with them, so
/// "whose expense is this" stops being obvious the moment there is more than
/// one person in the car. A lunch is one person's; a toll is everybody's.
///
/// Untagged means COMMON — it belongs to the journey, not to whoever happened
/// to key it in. That is the safer default: attributing a shared toll to the
/// person who typed it would quietly load their sheet with the team's costs,
/// and nobody would notice until somebody queried a claim.
///
/// Paired with `client/src/domain/trips.ts`; pinned by
/// `shared/fixtures/trip_sharing.json`.
const String kExpenseOwnerField = 'custom_for_person';

/// Frappe returns an unset Link as null, '' or the string 'null'.
String? _link(dynamic v) {
  final s = '${v ?? ''}'.trim();
  return (s.isEmpty || s == 'null' || s == 'undefined') ? null : s;
}

String? expenseOwner(Map<String, dynamic> expense) =>
    _link(expense[kExpenseOwnerField]);

bool isCommonExpense(Map<String, dynamic> expense) =>
    expenseOwner(expense) == null;

class ExpenseSplit {
  /// Person -> the expenses tagged to them, summed.
  final Map<String, double> own;

  /// Untagged: the journey's own costs.
  final double common;

  /// Everything on the trip, however it is tagged.
  final double total;

  const ExpenseSplit(this.own, this.common, this.total);
}

/// Split a trip's expenses by who they belong to.
///
/// The common pot is REPORTED, not divided. Nobody asked for it to be split
/// between the travellers, and inventing a division would put money on
/// somebody's sheet that was never agreed with them.
ExpenseSplit splitExpenses(List<Map<String, dynamic>> expenses) {
  final own = <String, double>{};
  var common = 0.0;
  var total = 0.0;

  for (final e in expenses) {
    final amount = expenseNum(e['amount']);
    total += amount;
    final owner = expenseOwner(e);
    if (owner == null) {
      common += amount;
    } else {
      // Counted even when the owner is not on the trip. The tag is a statement
      // about whose money it was; dropping it would lose the amount entirely.
      own[owner] = (own[owner] ?? 0) + amount;
    }
  }

  double r2(double v) => double.parse(v.toStringAsFixed(2));
  return ExpenseSplit(
      own.map((k, v) => MapEntry(k, r2(v))), r2(common), r2(total));
}

/// What one person personally spent on a trip. Excludes the common pot.
double personalExpense(List<Map<String, dynamic>> expenses, String person) =>
    splitExpenses(expenses).own[person] ?? 0;

/// The reps tagged on a trip.
///
/// `tagged_csv` is pipe-WRAPPED — `|Pareeth Kb|`, `|A|B|` — so that an exact
/// name can be matched with a LIKE without a longer name containing it also
/// matching. Splitting on the pipe leaves empty ends, which are dropped.
List<String> parseTagged(String? csv) {
  if (csv == null) return const [];
  return csv
      .split('|')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && s != 'null')
      .toList();
}

/// Whether this trip counts as travelling with the team manager.
///
/// [managerName] is the manager's Sales Person NAME, never their team token.
/// A team is stored as a short token (`Pareeth`) while the manager's record is
/// named `Pareeth Kb`, and a trip tags the record name — comparing the token
/// matches nothing, which is exactly what made the dashboard's "Shop visit with
/// manager" column read zero on every row until 18 Aug 2026.
bool travelledWithManager(
  Map<String, dynamic> trip,
  String personId,
  String managerName,
) {
  if (managerName.isEmpty) return false;
  final owner = '${trip['sales_person'] ?? ''}';
  final tagged = parseTagged('${trip['tagged_csv'] ?? ''}');
  // They have to have been on it.
  if (owner != personId && !tagged.contains(personId)) return false;
  // The manager took them out, or they took the manager along. Both count.
  return owner == managerName || tagged.contains(managerName);
}
