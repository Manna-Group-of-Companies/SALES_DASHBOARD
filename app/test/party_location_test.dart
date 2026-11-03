// Where a place sits, as every screen should read it.
//
// The maps and the customer list each read the coordinates their own way,
// and customers the list showed with figures were missing from the map
// beside it. These pin the one reading they now share.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/party_location.dart';

void main() {
  group('Reading a coordinate the backend sent', () {
    test('a number is itself', () {
      expect(coordOf(9.0544), 9.0544);
      expect(coordOf(9), 9.0);
    });

    test('text is parsed — a legacy Data field sends it that way', () {
      expect(coordOf('76.5344'), 76.5344);
      expect(coordOf(' 9.0544 '), 9.0544);
    });

    test('every spelling of "unset" reads as nothing, never as a place', () {
      expect(coordOf(null), 0);
      expect(coordOf(''), 0);
      expect(coordOf('null'), 0);
      expect(coordOf('abc'), 0);
    });
  });

  group('Where a customer or lead sits', () {
    test('the verified pair wins — it is what punch-in measures against', () {
      final p = partyLatLng({
        'custom_latitude': 9.0,
        'custom_longitude': 76.0,
        'custom_verified_latitude': 9.1,
        'custom_verified_longitude': 76.1,
      })!;
      expect(p.lat, 9.1);
      expect(p.lng, 76.1);
    });

    test("a rep's capture awaiting its manager still has a pin", () {
      // The verified pair is written only on approval; until then the
      // captured pair is the only position, and it must show.
      final p = partyLatLng({
        'custom_latitude': 9.0,
        'custom_longitude': 76.0,
        'custom_verified_latitude': null,
        'custom_verified_longitude': null,
      })!;
      expect(p.lat, 9.0);
      expect(p.lng, 76.0);
    });

    test('a legacy row holding only the verified pair is not "no location"',
        () {
      final p = partyLatLng({
        'custom_latitude': 0,
        'custom_longitude': 0,
        'custom_verified_latitude': 25.2,
        'custom_verified_longitude': 55.3,
      })!;
      expect(p.lat, 25.2);
      expect(p.lng, 55.3);
    });

    test('a coordinate stored as text still places the customer', () {
      // The maps used to drop these: `(v is num) ? v : 0.0` read the text as
      // (0, 0) and the pin vanished while the list beside it showed figures.
      final p = partyLatLng({
        'custom_latitude': '9.0544',
        'custom_longitude': '76.5344',
      })!;
      expect(p.lat, 9.0544);
      expect(p.lng, 76.5344);
    });

    test('(0, 0) is an unset field, not a place in the Atlantic', () {
      expect(
          partyLatLng({
            'custom_latitude': 0,
            'custom_longitude': 0,
            'custom_verified_latitude': 0,
            'custom_verified_longitude': 0,
          }),
          isNull);
      expect(partyLatLng({}), isNull);
    });

    test('a cleared verified pair after a re-capture falls back to the new pin',
        () {
      // Re-capture nulls the verified pair on purpose so the wrong one stops
      // outranking the right one; Frappe reads the cleared field back as 0.
      final p = partyLatLng({
        'custom_latitude': 9.5,
        'custom_longitude': 76.5,
        'custom_verified_latitude': 0,
        'custom_verified_longitude': 0,
      })!;
      expect(p.lat, 9.5);
    });
  });

  group('Where a site sits', () {
    test('reads the unprefixed fields a custom doctype carries', () {
      final p = partyLatLng({
        'latitude': 9.2,
        'longitude': 76.2,
        'verified_latitude': null,
        'verified_longitude': null,
      }, prefix: '')!;
      expect(p.lat, 9.2);
      expect(p.lng, 76.2);
    });
  });
}
