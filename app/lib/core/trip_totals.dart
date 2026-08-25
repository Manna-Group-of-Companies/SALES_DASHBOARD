// What a trip's stored figures must say, computed from its legs.
//
// WHY THIS EXISTS
//
// `estimated_cost`, `primary_mode`, `total_distance_km` and `cost_basis` are
// summaries of the legs. The legs are the record of what was actually driven;
// the trip-level fields are what the reports, the payouts and the mobile app
// read. Nothing on this site keeps them in step — there are no server scripts
// — so every writer has to recompute them, and both apps write trips.
//
// TRP-00311 is what happens when one does not. A leg was created as
// 'Own Vehicle' on 19 August 2026 and priced at Rs 7/km: 53 x 7 = Rs 371,
// stored. The leg was later edited to 'Bike' at Rs 3.5/km. Nothing recomputed
// the trip, so it went on claiming Rs 371 against the Rs 185.50 actually
// earned — exactly double. Four of Prasad V's trips are in that state.
//
// THE TRAP IN THE NAMING
//
// **'Own Vehicle' prices at the own-CAR rate.** A rep on their own motorbike
// reads that as "my own vehicle", picks it, and is paid twice what they earned.
// It is the single easiest way to lose money here.
//
// A MIXED LEG CARRIES A FARE
//
// `claimed_amount` on a Mixed leg is a ticket — a bus or train fare that is not
// per kilometre — and it counts on top of the distance. Five of Prashanth's
// trips are a Mixed leg with no distance and a fare between Rs 168 and
// Rs 1,088; the dashboard was dropping it and reading them all as zero.
// On any other mode the claimed amount is ignored: the kilometres already paid
// for that journey and adding it would pay for it twice.
//
// Pinned by `shared/fixtures/trip_totals.json`, which the dashboard reads too.

/// Recomputed trip-level figures.
class TripTotals {
  final double totalKm;
  final double odometerKm;
  final double cost;

  /// Null with no legs — nothing to derive it from, so the caller should leave
  /// whatever is stored. It is at least what the rep originally chose.
  final String? primaryMode;

  final String costBasis;

  const TripTotals({
    required this.totalKm,
    required this.odometerKm,
    required this.cost,
    required this.primaryMode,
    required this.costBasis,
  });
}

/// One leg, as this rule needs to see it.
class TripLegInput {
  final String? mode;
  final double km;
  final bool hasOdometer;
  final double claimedAmount;

  const TripLegInput({
    required this.mode,
    required this.km,
    required this.hasOdometer,
    this.claimedAmount = 0,
  });
}

double _round(double v, int places) {
  final f = places == 1 ? 10 : 100;
  return (v * f).round() / f;
}

/// Money for one leg: distance at its own mode's rate, plus a Mixed fare.
double legClaim(TripLegInput leg, double Function(String?) rateFor) {
  final perKm = leg.km * rateFor(leg.mode);
  final fare = leg.mode == 'Mixed' ? leg.claimedAmount : 0.0;
  return _round(perKm + fare, 2);
}

/// Everything a trip's stored fields should be set to.
///
/// [rateFor] maps a leg's mode to its per-km rate. An unknown mode must earn
/// nothing rather than guess — a wrong rate is money.
TripTotals tripTotalsFromLegs(
  List<TripLegInput> legs,
  double Function(String?) rateFor,
) {
  var totalKm = 0.0, odometerKm = 0.0, cost = 0.0;
  final modes = <String>{};

  for (final leg in legs) {
    totalKm += leg.km;
    if (leg.hasOdometer) odometerKm += leg.km;
    cost += legClaim(leg, rateFor);
    final m = (leg.mode ?? '').trim();
    if (m.isNotEmpty) modes.add(m);
  }

  return TripTotals(
    totalKm: _round(totalKm, 1),
    odometerKm: _round(odometerKm, 1),
    cost: _round(cost, 2),
    primaryMode:
        modes.isEmpty ? null : (modes.length == 1 ? modes.first : 'Mixed'),
    costBasis: odometerKm > 0 ? 'Odometer' : 'GPS Distance',
  );
}
