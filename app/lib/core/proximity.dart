// Whether a place already exists where a rep is standing.
//
// Two reps working neighbouring routes used to be able to walk into the same
// shop a fortnight apart and each raise a lead for it, because nothing in the
// app ever compared one lead's position with another's. The duplicates only
// surfaced later, in the office, as two orders for one customer.
//
// The arithmetic lives here rather than next to the screens so it can be tested
// without a network or a map, and so the radius is stated in exactly one place.

import 'dart:math' as math;

/// How close counts as "the same place". A shop found inside this radius is
/// treated as already on record.
///
/// 250 m, not a kilometre. A kilometre covers most of a market town and was
/// refusing genuinely separate shops on the same street; a quarter of that is
/// close enough that two records almost certainly describe one place.
const double kDuplicateRadiusMetres = 250;

/// How far from a shop's registered position a rep may punch in.
///
/// Generous on purpose. This is not a test of whether the rep is standing in
/// the doorway — it is a check that they are at the place they say they are.
/// The registered pin is wherever somebody happened to stand when they first
/// captured it, a customer may have several premises, and a phone in a shed
/// behind a workshop can read a few hundred metres out. Two kilometres passes
/// every honest visit and still refuses a punch from the next town.
const double kPunchInRadiusMetres = 2000;

/// A place a visit can legitimately be punched at: the party's own registered
/// position, or one of its sites.
class RegisteredPlace {
  /// What to call it if this is the nearest one — the shop's name, or the
  /// site's.
  final String label;
  final double lat;
  final double lng;

  const RegisteredPlace(this.label, this.lat, this.lng);
}

/// The closest registered place to where the rep is standing, or null when
/// none of them has a usable coordinate.
///
/// Null means "cannot tell", not "too far". The caller must not treat it as a
/// refusal: a party whose location was never captured would otherwise strand
/// the rep at the counter, and the capture gate already covers that case.
({RegisteredPlace place, double metres})? nearestRegistered(
    double lat, double lng, Iterable<RegisteredPlace> places) {
  RegisteredPlace? best;
  var bestMetres = double.infinity;
  for (final p in places) {
    if (!isRealCoordinate(p.lat, p.lng)) continue;
    final d = metresBetween(lat, lng, p.lat, p.lng);
    if (d < bestMetres) {
      bestMetres = d;
      best = p;
    }
  }
  return best == null ? null : (place: best, metres: bestMetres);
}

/// Metres between two coordinates, by the haversine formula.
///
/// Great-circle rather than flat-earth: over a kilometre the difference is
/// centimetres, but the formula does not care how far apart the points are, so
/// nothing breaks if it is ever called with two ends of the state.
double metresBetween(
    double lat1, double lng1, double lat2, double lng2) {
  const earthRadius = 6371000.0;
  double rad(double d) => d * math.pi / 180.0;
  final p1 = rad(lat1), p2 = rad(lat2);
  final dLat = rad(lat2 - lat1), dLng = rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  // Clamped before asin: rounding can push `a` a hair above 1 for antipodal
  // points, and asin(1.0000000001) is NaN.
  return 2 * earthRadius * math.asin(math.min(1.0, math.sqrt(a)));
}

// Metres in a degree, deliberately understated.
//
// The earth is not a sphere, so a degree is worth between about 110,570 m
// (a meridian degree at the equator) and 111,690 m. These spans size the
// database's bounding box, and the box only pre-selects rows — the exact
// haversine distance then decides. So the two error directions are not equal:
// a box a little too big costs a few extra rows, while a box a little too
// small silently drops a duplicate before anything ever measures it. Taking
// the smallest real figure, and then widening by a further 2%, makes the box
// err the only way it can afford to.
const double _metresPerDegree = 110540.0;
const double _boxSafetyMargin = 1.02;

/// Degrees of latitude covering [metres], rounded outwards.
double latSpanForMetres(double metres) =>
    (metres / _metresPerDegree) * _boxSafetyMargin;

/// Degrees of longitude covering [metres] at [atLatitude], rounded outwards.
///
/// Meridians converge towards the poles, so a degree of longitude is worth
/// less the further north you go. Kerala is near the equator and the
/// difference is small, but a box computed as if it were constant would be too
/// narrow, and a too-narrow box silently misses duplicates.
double lngSpanForMetres(double metres, double atLatitude) {
  final shrink = math.cos(atLatitude * math.pi / 180.0).abs();
  // Near the poles cos goes to zero and the span to infinity. Clamped so the
  // box stays a box rather than becoming the whole world.
  return (metres / (_metresPerDegree * math.max(shrink, 0.01))) *
      _boxSafetyMargin;
}

/// A lead or customer already on record near where the rep is standing.
class NearbyPlace {
  /// The ERPNext docname, e.g. `CRM-LEAD-2026-00042`.
  final String name;

  /// What the rep would recognise it by — the shop or company name.
  final String label;

  /// 'Lead' or 'Customer'. Which one decides who can remove it.
  final String kind;

  /// The rep it belongs to, blank when nobody is assigned.
  final String owner;

  final double metres;

  const NearbyPlace({
    required this.name,
    required this.label,
    required this.kind,
    required this.owner,
    required this.metres,
  });

  /// Distance as a rep would say it: metres up close, kilometres beyond that.
  String get distanceLabel => metres < 1000
      ? '${metres.round()} m away'
      : '${(metres / 1000).toStringAsFixed(1)} km away';

  /// Who to chase, phrased for the rep. A record with no rep on it is still
  /// blocking, and saying so is more use than leaving the line blank.
  String get ownerLabel => owner.isEmpty ? 'no rep assigned' : owner;
}

/// Every candidate inside [radiusMetres] of the given point, nearest first.
///
/// [excludeNames] drops records that are not duplicates of anything — above
/// all the lead being captured, which sits at zero metres from itself and
/// would otherwise block every capture on the first run.
List<NearbyPlace> placesWithin({
  required double lat,
  required double lng,
  required double radiusMetres,
  required List<NearbyPlace Function()> candidates,
  Set<String> excludeNames = const {},
}) {
  final hits = <NearbyPlace>[];
  for (final make in candidates) {
    final p = make();
    if (excludeNames.contains(p.name)) continue;
    if (p.metres <= radiusMetres) hits.add(p);
  }
  hits.sort((a, b) => a.metres.compareTo(b.metres));
  return hits;
}

/// True when a coordinate pair is worth comparing against.
///
/// (0, 0) is in the Atlantic and is what an unset field reads as, so a record
/// that has never been captured must not be treated as a place. Letting it
/// through would put every uncaptured lead half a world away — harmless — but
/// letting a *rep* at (0, 0) through would compare nothing meaningfully at all.
bool isRealCoordinate(double lat, double lng) =>
    lat.isFinite &&
    lng.isFinite &&
    lat.abs() <= 90 &&
    lng.abs() <= 180 &&
    !(lat == 0 && lng == 0);
