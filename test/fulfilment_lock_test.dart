// When a line's source stops being changeable.
//
// Three separate things close it, and the delivery deadline is the weakest of
// them. An order is routinely dispatched days before its delivery date, so a
// rule that waited for 1 pm would leave the toggle live on goods that have
// already left the building — and switching one of those back to new production
// releases a reservation against stock that is on a van.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/order_rules.dart';
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

  group('approval is the lock', () {
    test('an approved order is closed to further mode changes', () {
      // The decision is made as part of saying yes. Production is working to
      // it from that moment, whatever the delivery date says.
      expect(
          orderApproved(
              {'custom_po_status': 'PO Approved - Ready for SAP'}),
          isTrue);
    });

    test('an order still awaiting a decision is open', () {
      for (final s in [
        'Pending Approval',
        'Pending Rate Approval',
        'PO Uploaded - Pending Approval',
        'Pending GM Approval',
        'No PO Yet',
        '',
      ]) {
        expect(orderApproved({'custom_po_status': s}), isFalse, reason: s);
      }
    });

    test('a rejected order is not approved, so the choice reopens', () {
      expect(orderApproved({'custom_po_status': 'Rejected'}), isFalse);
    });

    test('an edited order returns to the queue and the choice reopens', () {
      // A rep editing an approved order sends the status back to pending. The
      // manager is being asked to approve it afresh, and the lines may not be
      // the ones they decided on, so they must get the choice again.
      final edited = {'custom_po_status': 'Pending Approval'};
      expect(orderApproved(edited), isFalse);
    });

    test('approval alone locks it, with no delivery date at all', () {
      // orderEditWindowOpen treats a missing delivery date as permanently
      // open. Approval must not depend on it.
      const order = {'custom_po_status': 'PO Approved - Ready for SAP'};
      expect(orderEditWindowOpen(order['delivery_date']), isTrue);
      expect(orderApproved(order), isTrue);
    });
  });
}
