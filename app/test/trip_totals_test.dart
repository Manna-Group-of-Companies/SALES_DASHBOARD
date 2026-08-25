// A trip's stored figures, computed from its legs — read from the shared
// fixture the dashboard's suite reads too.
//
// Both apps write trips and this decides what a rep is paid, so the two
// implementations have to agree exactly. Two live bugs are pinned here:
// TRP-00311 claiming double after its leg mode was edited, and five of
// Prashanth's trips whose bus fares were being read as zero.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/trip_totals.dart';

void main() {
  final raw = File('../shared/fixtures/trip_totals.json').readAsStringSync();
  final fixture = json.decode(raw) as Map<String, dynamic>;
  final rates = (fixture['rates'] as Map).cast<String, dynamic>();

  double rateFor(String? mode) {
    final v = rates[mode ?? ''];
    return v is num ? v.toDouble() : 0.0;
  }

  TripLegInput leg(Map<String, dynamic> l) => TripLegInput(
        mode: l['mode'] as String?,
        km: (l['km'] as num).toDouble(),
        hasOdometer: (l['has_odometer'] as num) == 1,
        claimedAmount: (l['claimed_amount'] as num).toDouble(),
      );

  group('trip totals, from the legs', () {
    for (final c in (fixture['totals'] as List).cast<Map<String, dynamic>>()) {
      test(c['why'] as String, () {
        final got = tripTotalsFromLegs(
            (c['legs'] as List)
                .cast<Map<String, dynamic>>()
                .map(leg)
                .toList(),
            rateFor);
        final want = c['expect'] as Map<String, dynamic>;
        expect(got.totalKm, (want['total_km'] as num).toDouble());
        expect(got.odometerKm, (want['odometer_km'] as num).toDouble());
        expect(got.cost, (want['cost'] as num).toDouble());
        expect(got.primaryMode, want['primary_mode']);
        expect(got.costBasis, want['cost_basis']);
      });
    }
  });

  group('the two bugs this was written for', () {
    test('TRP-00311: Own Vehicle earns exactly double what Bike earns', () {
      // "Own Vehicle" prices at the own-CAR rate. A rep on their own motorbike
      // recorded that way is paid twice what they earned.
      const km = 53.0;
      final bike = tripTotalsFromLegs(
          [const TripLegInput(mode: 'Bike', km: km, hasOdometer: true)],
          rateFor);
      final car = tripTotalsFromLegs(
          [const TripLegInput(mode: 'Own Vehicle', km: km, hasOdometer: true)],
          rateFor);
      expect(bike.cost, 185.5);
      expect(car.cost, 371.0);
      expect(car.cost, bike.cost * 2);
    });

    test('a Mixed leg with no distance is worth its fare, not zero', () {
      for (final fare in [1088.0, 623.0, 168.0, 605.0, 637.0]) {
        final t = tripTotalsFromLegs([
          TripLegInput(
              mode: 'Mixed', km: 0, hasOdometer: false, claimedAmount: fare)
        ], rateFor);
        expect(t.cost, fare);
      }
    });

    test('a fare on a non-Mixed leg is ignored', () {
      // The kilometres already paid for that journey; adding the claimed
      // amount would pay for it twice, which is the opposite mistake.
      final t = tripTotalsFromLegs([
        const TripLegInput(
            mode: 'Bike', km: 10, hasOdometer: true, claimedAmount: 500)
      ], rateFor);
      expect(t.cost, 35.0);
    });
  });

  group('the header can never contradict the legs', () {
    test('one mode wins, several become Mixed, none leaves it alone', () {
      TripTotals of(List<String> modes) => tripTotalsFromLegs(
          [for (final m in modes) TripLegInput(mode: m, km: 5, hasOdometer: true)],
          rateFor);
      expect(of(['Bike']).primaryMode, 'Bike');
      expect(of(['Bike', 'Bike']).primaryMode, 'Bike');
      expect(of(['Bike', 'Own Vehicle']).primaryMode, 'Mixed');
      expect(of([]).primaryMode, isNull);
    });

    test('a blank mode is not a mode', () {
      // Frappe reads an unset Select back as null or ''. Neither should make
      // a trip look Mixed, which would be a mode nobody drove.
      final t = tripTotalsFromLegs([
        const TripLegInput(mode: 'Bike', km: 5, hasOdometer: true),
        const TripLegInput(mode: '', km: 5, hasOdometer: true),
      ], rateFor);
      expect(t.primaryMode, 'Bike');
    });
  });
}
