// When a line's source stops being changeable.
//
// Three separate things close it, and the delivery deadline is the weakest of
// them. An order is routinely dispatched days before its delivery date, so a
// rule that waited for 1 pm would leave the toggle live on goods that have
// already left the building — and switching one of those back to new production
// releases a reservation against stock that is on a van.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/production_stages.dart';
import 'package:manna_field_sales/services/api.dart';

void main() {
  group('order completion', () {
    test('a dispatched order is complete', () {
      expect(Api.isOrderComplete({'custom_production_status': 'Dispatched'}),
          isTrue);
    });

    test('every earlier state is not complete', () {
      for (final s in ['Not Started', 'In Production', 'Ready', '', 'null']) {
        expect(Api.isOrderComplete({'custom_production_status': s}), isFalse,
            reason: s);
      }
    });

    test('a missing status is not complete', () {
      // Erring the other way would lock an order nobody has touched.
      expect(Api.isOrderComplete({}), isFalse);
    });
  });

  group('a dispatched line', () {
    test('is recognised from its stage', () {
      expect(isDispatched(kStageDispatched), isTrue);
    });

    test('a packed line is not dispatched', () {
      // Packed is the last stage before it goes. The goods are still in the
      // building, so the decision is still reversible.
      expect(isDispatched('Packed'), isFalse);
    });

    test('an untouched or unknown line is not dispatched', () {
      expect(isDispatched(null), isFalse);
      expect(isDispatched(''), isFalse);
      expect(isDispatched('Curing'), isFalse);
    });
  });

  group('the case that was being missed', () {
    test('dispatched with a future delivery date is still complete', () {
      // SAL-ORD-2026-00100: dispatched, delivery 2026-08-08, checked on
      // 2026-08-07. The 1 pm deadline had not passed, so the toggle stayed
      // live on an order that had already gone out.
      final order = {
        'custom_production_status': 'Dispatched',
        'delivery_date': '2026-08-08',
      };
      expect(Api.isOrderComplete(order), isTrue,
          reason: 'completion must not wait for the delivery deadline');
    });
  });
}
