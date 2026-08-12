// How far from a shop a rep may punch in.
//
// The rule is not "are you in the doorway" — the registered pin is wherever
// somebody happened to stand when they first captured it, a customer may have
// several premises, and GPS in a shed behind a workshop reads a few hundred
// metres out. What it must catch is a punch from somewhere else entirely.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/proximity.dart';

// Kottayam, roughly — where the rep is standing in every test below.
const kLat = 9.5916;
const kLng = 76.5222;

/// A place [metresNorth] away from the rep.
RegisteredPlace northOf(String label, double metresNorth) =>
    RegisteredPlace(label, kLat + (metresNorth / 110540.0), kLng);

void main() {
  test('the limit is two kilometres', () {
    expect(kPunchInRadiusMetres, 2000);
  });

  group('near enough', () {
    test('standing on the pin is allowed', () {
      final n = nearestRegistered(kLat, kLng, [RegisteredPlace('Shop', kLat, kLng)]);
      expect(n, isNotNull);
      expect(n!.metres, lessThan(1));
      expect(n.metres, lessThanOrEqualTo(kPunchInRadiusMetres));
    });

    test('a few hundred metres out still passes', () {
      // GPS drift, or the yard behind the shop.
      final n = nearestRegistered(kLat, kLng, [northOf('Shop', 400)]);
      expect(n!.metres, lessThanOrEqualTo(kPunchInRadiusMetres));
    });

    test('just inside two kilometres passes', () {
      final n = nearestRegistered(kLat, kLng, [northOf('Shop', 1900)]);
      expect(n!.metres, lessThanOrEqualTo(kPunchInRadiusMetres));
    });
  });

  group('too far', () {
    test('the next town is refused', () {
      final n = nearestRegistered(kLat, kLng, [northOf('Shop', 6000)]);
      expect(n!.metres, greaterThan(kPunchInRadiusMetres));
    });
  });

  group('sites count as the shop', () {
    test('the nearest of several places wins', () {
      // A customer with a shop and a godown. A rep at the godown is not in the
      // wrong place, so the check measures the closest, not the first.
      final n = nearestRegistered(kLat, kLng, [
        northOf('Shop', 5000),
        northOf('Godown', 300),
      ]);
      expect(n!.place.label, 'Godown');
      expect(n.metres, lessThanOrEqualTo(kPunchInRadiusMetres));
    });

    test('a far site does not rescue a rep who is far from everything', () {
      final n = nearestRegistered(kLat, kLng, [
        northOf('Shop', 9000),
        northOf('Godown', 7000),
      ]);
      expect(n!.place.label, 'Godown');
      expect(n.metres, greaterThan(kPunchInRadiusMetres));
    });

    test('the nearest place is named, so the rep knows what was measured', () {
      final n = nearestRegistered(kLat, kLng, [northOf('Second yard', 100)]);
      expect(n!.place.label, 'Second yard');
    });
  });

  group('when there is nothing to measure against', () {
    test('no places at all reads as cannot-tell, not too-far', () {
      // Null must never be treated as a refusal: a party whose location was
      // never captured would otherwise strand the rep at the counter.
      expect(nearestRegistered(kLat, kLng, const []), isNull);
    });

    test('a place at (0, 0) is ignored rather than measured', () {
      // Frappe reads an unset float as 0, and (0, 0) is open ocean. Measuring
      // it would put every uncaptured shop 8,000 km away and refuse the punch.
      expect(nearestRegistered(kLat, kLng, [const RegisteredPlace('X', 0, 0)]),
          isNull);
    });

    test('a real place beside an empty one is still found', () {
      final n = nearestRegistered(kLat, kLng, [
        const RegisteredPlace('Never captured', 0, 0),
        northOf('Shop', 200),
      ]);
      expect(n!.place.label, 'Shop');
    });
  });
}
