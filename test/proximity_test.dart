// The duplicate-place check.
//
// The costly mistake here is a radius that measures short: it reports "nothing
// nearby" for a shop that is already on record, which is the exact duplicate
// the feature exists to stop. So the distances are checked against known
// separations rather than against the formula's own output.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/proximity.dart';

// Kottayam, roughly. Everything below is measured from here.
const kLat = 9.5916;
const kLng = 76.5222;

NearbyPlace _at(String name, double lat, double lng,
        {String kind = 'Lead', String owner = 'Jaimon D'}) =>
    NearbyPlace(
      name: name,
      label: name,
      kind: kind,
      owner: owner,
      metres: metresBetween(kLat, kLng, lat, lng),
    );

void main() {
  group('distance', () {
    test('a point measured against itself is zero', () {
      expect(metresBetween(kLat, kLng, kLat, kLng), 0);
    });

    test('one degree of latitude is about 111 km', () {
      final d = metresBetween(0, 0, 1, 0);
      expect(d, closeTo(111195, 500));
    });

    test('a known short hop comes out right', () {
      // 0.009 degrees of latitude is almost exactly a kilometre.
      final d = metresBetween(kLat, kLng, kLat + 0.009, kLng);
      expect(d, closeTo(1000, 15));
    });

    test('distance is symmetric', () {
      final a = metresBetween(kLat, kLng, 10.5, 76.2);
      final b = metresBetween(10.5, 76.2, kLat, kLng);
      expect(a, closeTo(b, 0.001));
    });

    test('antipodal points do not come back as NaN', () {
      // asin of a rounding error above 1.0 is NaN, which would compare false
      // against every radius and silently wave everything through.
      final d = metresBetween(0, 0, 0, 180);
      expect(d.isNaN, isFalse);
      expect(d, greaterThan(19000000));
    });
  });

  group('bounding box', () {
    test('the latitude span covers the radius', () {
      final span = latSpanForMetres(1000);
      final covered = metresBetween(kLat, kLng, kLat + span, kLng);
      expect(covered, greaterThanOrEqualTo(1000));
    });

    test('the longitude span covers the radius at this latitude', () {
      // A box built as if a degree of longitude were worth as much as a degree
      // of latitude would be too narrow, and would miss duplicates due east.
      final span = lngSpanForMetres(1000, kLat);
      final covered = metresBetween(kLat, kLng, kLat, kLng + span);
      expect(covered, greaterThanOrEqualTo(1000));
    });

    test('the longitude span widens further from the equator', () {
      expect(lngSpanForMetres(1000, 60), greaterThan(lngSpanForMetres(1000, 0)));
    });

    test('the span stays finite at the pole', () {
      expect(lngSpanForMetres(1000, 90).isFinite, isTrue);
    });
  });

  group('placesWithin', () {
    List<NearbyPlace> run(List<NearbyPlace> ps,
            {Set<String> exclude = const {}, double radius = 1000}) =>
        placesWithin(
          lat: kLat,
          lng: kLng,
          radiusMetres: radius,
          candidates: ps.map((p) => () => p).toList(),
          excludeNames: exclude,
        );

    test('a shop inside the radius is reported', () {
      final hits = run([_at('LEAD-1', kLat + 0.002, kLng)]);
      expect(hits, hasLength(1));
      expect(hits.single.name, 'LEAD-1');
    });

    test('a shop beyond the radius is not', () {
      // ~2.2 km north.
      expect(run([_at('LEAD-1', kLat + 0.02, kLng)]), isEmpty);
    });

    test('the record being captured is excluded from its own check', () {
      // Without this, every first capture would block on itself.
      final self = _at('LEAD-SELF', kLat, kLng);
      expect(run([self]), hasLength(1));
      expect(run([self], exclude: {'LEAD-SELF'}), isEmpty);
    });

    test('customers block just as leads do', () {
      final hits = run([_at('CUST-1', kLat, kLng + 0.001, kind: 'Customer')]);
      expect(hits.single.kind, 'Customer');
    });

    test('the nearest is listed first', () {
      final hits = run([
        _at('FAR', kLat + 0.008, kLng),
        _at('NEAR', kLat + 0.001, kLng),
        _at('MID', kLat + 0.004, kLng),
      ]);
      expect(hits.map((p) => p.name).toList(), ['NEAR', 'MID', 'FAR']);
    });

    test('a shop exactly on the radius still blocks', () {
      // The boundary belongs to the blocked side. A shop measured at precisely
      // 1000 m is the same place as far as this rule is concerned.
      final onEdge = NearbyPlace(
          name: 'EDGE', label: 'EDGE', kind: 'Lead', owner: '', metres: 1000);
      expect(run([onEdge]), hasLength(1));
    });
  });

  group('coordinates', () {
    test('an uncaptured record at (0, 0) is not a place', () {
      // Frappe reads an unset float as 0, and (0, 0) is open ocean. Treating it
      // as real would put every uncaptured lead in the Atlantic.
      expect(isRealCoordinate(0, 0), isFalse);
    });

    test('a real Kerala coordinate is a place', () {
      expect(isRealCoordinate(kLat, kLng), isTrue);
    });

    test('junk is not a place', () {
      expect(isRealCoordinate(double.nan, kLng), isFalse);
      expect(isRealCoordinate(kLat, double.infinity), isFalse);
      expect(isRealCoordinate(91, kLng), isFalse);
    });
  });

  group('what the rep is told', () {
    test('close distances read in metres, far ones in kilometres', () {
      const near =
          NearbyPlace(name: 'a', label: 'a', kind: 'Lead', owner: '', metres: 240.4);
      const far =
          NearbyPlace(name: 'b', label: 'b', kind: 'Lead', owner: '', metres: 1500);
      expect(near.distanceLabel, '240 m away');
      expect(far.distanceLabel, '1.5 km away');
    });

    test('an unassigned record still names something useful', () {
      const p =
          NearbyPlace(name: 'a', label: 'a', kind: 'Lead', owner: '', metres: 10);
      expect(p.ownerLabel, 'no rep assigned');
    });

    test('an assigned record names the rep to chase', () {
      const p = NearbyPlace(
          name: 'a', label: 'a', kind: 'Lead', owner: 'Bibin Balaravi', metres: 10);
      expect(p.ownerLabel, 'Bibin Balaravi');
    });
  });

  test('the radius is 250 metres', () {
    expect(kDuplicateRadiusMetres, 250);
  });
}
