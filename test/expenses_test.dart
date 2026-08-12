// What a rep is told they travelled and spent.
//
// These figures are read before asking to be paid, so the two things that
// matter are that nothing is silently dropped and that a trip shared with a
// colleague is never presented as this rep's own cost.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/expenses.dart';

Map<String, dynamic> trip({
  double? odo,
  double? entered,
  double? finalCost,
  double? claimed,
  double? estimate,
  String tagged = '',
}) =>
    {
      'odometer_distance_km': odo,
      'total_distance_km': entered,
      'final_cost': finalCost,
      'total_expenses': claimed,
      'estimated_cost': estimate,
      'tagged_csv': tagged,
    };

void main() {
  group('distance', () {
    test('the odometer beats what was typed', () {
      // The odometer is a reading off the vehicle; the entered figure is not.
      expect(tripKm(trip(odo: 84, entered: 60)), 84);
    });

    test('a trip with no odometer still counts its entered distance', () {
      expect(tripKm(trip(odo: 0, entered: 60)), 60);
    });

    test('a trip with neither counts as nothing rather than throwing', () {
      expect(tripKm(trip()), 0);
    });

    test('a distance that came back as a string is still a number', () {
      // Frappe hands floats back as strings often enough that a summary which
      // ignored them would quietly under-report a rep's month.
      expect(tripKm({'total_distance_km': '42.5'}), 42.5);
    });
  });

  group('cost', () {
    test('the allowance and what was spent add up', () {
      // They are two different pockets of money, not two readings of one.
      // `estimated_cost` is distance times the vehicle rate; `total_expenses`
      // is food and tolls. Treating them as alternatives dropped a rep's whole
      // mileage on any day they also bought lunch.
      expect(tripCost(trip(estimate: 1253, claimed: 150)), 1403);
    });

    test('a trip with no receipts is still worth its allowance', () {
      expect(tripCost(trip(estimate: 469)), 469);
    });

    test('a trip with receipts and no allowance is still worth them', () {
      expect(tripCost(trip(claimed: 150)), 150);
    });

    test('a settled trip is worth what was settled and nothing more', () {
      // Somebody entered `final_cost` by hand to override the arithmetic.
      expect(tripCost(trip(finalCost: 900, estimate: 1253, claimed: 150)), 900);
    });

    test('the two halves are readable on their own', () {
      final t = trip(estimate: 1253, claimed: 150);
      expect(tripTravelAllowance(t), 1253);
      expect(tripOutOfPocket(t), 150);
    });
  });

  group('shared', () {
    test('a trip with somebody tagged on it is shared', () {
      expect(isSharedTrip(trip(tagged: '|SP-0007|')), isTrue);
    });

    test('a solo trip is not shared', () {
      expect(isSharedTrip(trip()), isFalse);
    });

    test("the string 'null' is nobody tagged", () {
      // Unset Link and Data fields read back as null, '' or the literal
      // 'null' depending on how they were written. All three mean solo.
      expect(isSharedTrip({'tagged_csv': 'null'}), isFalse);
      expect(isSharedTrip({'tagged_csv': null}), isFalse);
      expect(isSharedTrip(const <String, dynamic>{}), isFalse);
    });
  });

  group('the period total', () {
    test('a shared trip is never added into the rep own figures', () {
      // Everybody tagged on a trip sees it in their own summary. Folding its
      // whole cost into each of their totals would claim the same money once
      // per person on board.
      final t = sumExpenses([
        trip(odo: 40, claimed: 300),
        trip(odo: 60, claimed: 500, tagged: '|SP-0007|'),
      ]);
      expect(t.ownKm, 40);
      expect(t.ownCost, 300);
      expect(t.sharedKm, 60);
      expect(t.sharedCost, 500);
    });

    test('the headline figure is still everything travelled and spent', () {
      // The rep did travel those kilometres, whoever they rode with.
      final t = sumExpenses([
        trip(odo: 40, claimed: 300),
        trip(odo: 60, claimed: 500, tagged: '|SP-0007|'),
      ]);
      expect(t.totalKm, 100);
      expect(t.totalCost, 800);
      expect(t.trips, 2);
    });

    test('the allowance and the receipts are totalled separately', () {
      final t = sumExpenses([
        trip(odo: 179, estimate: 1253, claimed: 150),
        trip(odo: 103, estimate: 360.5, claimed: 150),
      ]);
      expect(t.travelAllowance, 1613.5);
      expect(t.outOfPocket, 300);
      // And the two halves still make the whole.
      expect(t.totalCost, 1913.5);
    });

    test('a period with nothing shared says so', () {
      final t = sumExpenses([trip(odo: 40, claimed: 300)]);
      expect(t.hasShared, isFalse);
    });

    test('a shared trip with no cost still counts as shared distance', () {
      final t = sumExpenses([trip(odo: 60, tagged: '|SP-0007|')]);
      expect(t.hasShared, isTrue);
      expect(t.sharedKm, 60);
    });

    test('an empty period is zero, not an error', () {
      final t = sumExpenses(const []);
      expect(t.trips, 0);
      expect(t.totalKm, 0);
      expect(t.totalCost, 0);
      expect(t.hasShared, isFalse);
    });
  });

  group('how a figure reads', () {
    test('a whole number carries no decimals', () {
      expect(money(1200), '1200');
    });

    test('a part number keeps two', () {
      expect(money(84.5), '84.50');
    });
  });
}
