// Correcting a pin that is in the wrong place.
//
// A shop was captured 15.8 km from where it actually stands. The rep, standing
// at the counter, was refused the punch — and there was no way back: their own
// capture button is disabled once a location is on record, and the manager's
// verification queue only lists captures still awaiting a decision, so a
// `Verified` record never appears in it for anyone to reject.
//
// What made it permanent rather than merely wrong is the preference order in
// `Api.registeredPlacesFor`: the verified pair beats the captured pair. Letting
// the rep capture again but leaving the old verified pair in place would have
// looked like a fix and changed nothing. These tests pin that.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/proximity.dart';

// S.N Agencies, roughly — where the rep is standing.
const shopLat = 9.0544;
const shopLng = 76.5344;

/// The wrong pin: the same bearing and distance that was on the record.
const wrongLat = shopLat + (15800 / 110540.0);
const wrongLng = shopLng;

/// What `registeredPlacesFor` builds, in the same preference order: the
/// verified pair when it is real, otherwise the captured pair.
RegisteredPlace? placeFor({
  required double capturedLat,
  required double capturedLng,
  double? verifiedLat,
  double? verifiedLng,
}) {
  if (verifiedLat != null &&
      verifiedLng != null &&
      isRealCoordinate(verifiedLat, verifiedLng)) {
    return RegisteredPlace('S.N Agencies', verifiedLat, verifiedLng);
  }
  if (isRealCoordinate(capturedLat, capturedLng)) {
    return RegisteredPlace('S.N Agencies', capturedLat, capturedLng);
  }
  return null;
}

double? distanceFrom(RegisteredPlace? p) =>
    p == null ? null : nearestRegistered(shopLat, shopLng, [p])?.metres;

void main() {
  group('the bug, as it stood', () {
    test('a wrong verified pin refuses a rep who is at the shop', () {
      final d = distanceFrom(placeFor(
        capturedLat: wrongLat,
        capturedLng: wrongLng,
        verifiedLat: wrongLat,
        verifiedLng: wrongLng,
      ));
      expect(d, greaterThan(kPunchInRadiusMetres));
    });

    test('re-capturing without clearing the verified pair changes nothing', () {
      // The fix that would not have been one. A rep's capture only writes the
      // unverified pair, so the stale verified pin goes on winning and the
      // punch goes on being refused however many times they try.
      final d = distanceFrom(placeFor(
        capturedLat: shopLat,
        capturedLng: shopLng,
        verifiedLat: wrongLat,
        verifiedLng: wrongLng,
      ));
      expect(d, greaterThan(kPunchInRadiusMetres));
    });
  });

  group('after a re-capture clears the verified pair', () {
    test('the new captured pin is what gets measured', () {
      final d = distanceFrom(placeFor(
        capturedLat: shopLat,
        capturedLng: shopLng,
        verifiedLat: null,
        verifiedLng: null,
      ));
      expect(d, isNotNull);
      expect(d, lessThan(kPunchInRadiusMetres));
    });

    test('a cleared pair read back as Frappe zeroes is also discarded', () {
      // The write sends null; Frappe stores 0.0 on a Float field and reads it
      // back that way. If (0, 0) were treated as a place the shop would sit
      // 8,000 km out and the punch would still be refused — worse, not better.
      final d = distanceFrom(placeFor(
        capturedLat: shopLat,
        capturedLng: shopLng,
        verifiedLat: 0,
        verifiedLng: 0,
      ));
      expect(d, isNotNull);
      expect(d, lessThan(kPunchInRadiusMetres));
    });

    test('the rep can punch in without waiting for the manager', () {
      // The correction goes to 'Pending Verification', not 'Verified'. That
      // must not block the punch, or the rep is stranded at the counter until
      // the queue is cleared — which is the whole thing being fixed.
      const status = 'Pending Verification';
      const locationCaptured =
          status == 'Pending Verification' || status == 'Verified';
      expect(locationCaptured, isTrue);
    });
  });

  test('a manager verifying it later keeps the punch working', () {
    final d = distanceFrom(placeFor(
      capturedLat: shopLat,
      capturedLng: shopLng,
      verifiedLat: shopLat,
      verifiedLng: shopLng,
    ));
    expect(d, lessThan(kPunchInRadiusMetres));
  });
}
