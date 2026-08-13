// When an order can still be changed, and by whom.
//
// The cutoff is 1 pm on the required delivery date — not midnight, and not
// measured from when the order was raised. Both of those are easy mistakes to
// make later, so they are pinned here.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/session.dart';

String _iso(DateTime d) => d.toIso8601String().substring(0, 10);

Map<String, dynamic> _order({
  String? deliveryDate,
  String owner = 'Test Rep',
  int rateApproved = 0,
}) =>
    {
      'name': 'SO-0001',
      'delivery_date': deliveryDate,
      'custom_sales_person': owner,
      'custom_rate_approved': rateApproved,
    };

void main() {
  final today = DateTime.now();

  setUp(() {
    Session.I.salesPerson = 'Test Rep';
    Session.I.managedTeam = null;
    Session.I.teamReps = [];
  });

  tearDown(() {
    Session.I.salesPerson = null;
    Session.I.managedTeam = null;
    Session.I.teamReps = [];
  });

  group('The cutoff', () {
    test('is 1 pm on the delivery date, not midnight', () {
      final d = orderEditDeadline('2026-08-20');
      expect(d, DateTime(2026, 8, 20, 13));
    });

    test('a delivery date well in the future is open', () {
      final future = _iso(today.add(const Duration(days: 30)));
      expect(orderEditWindowOpen(future), isTrue);
    });

    test('a delivery date in the past is closed', () {
      final past = _iso(today.subtract(const Duration(days: 2)));
      expect(orderEditWindowOpen(past), isFalse);
    });

    test('an order with no delivery date stays open, not permanently shut', () {
      // A missing date is a data problem. Freezing the order would make it
      // impossible to fix the very field that is missing.
      expect(orderEditWindowOpen(null), isTrue);
      expect(orderEditWindowOpen(''), isTrue);
      expect(orderEditDeadline(null), isNull);
    });

    test('a datetime string is accepted as well as a plain date', () {
      expect(orderEditDeadline('2026-08-20 00:00:00'),
          DateTime(2026, 8, 20, 13));
    });
  });

  group('Who may change it', () {
    final future = _iso(today.add(const Duration(days: 10)));

    test('the rep who raised it can', () {
      expect(canEditOrder(_order(deliveryDate: future, owner: 'Test Rep')),
          isTrue);
    });

    test('another rep cannot', () {
      expect(canEditOrder(_order(deliveryDate: future, owner: 'Amjad Pr')),
          isFalse);
    });

    test('their manager can', () {
      Session.I.managedTeam = 'Pareeth';
      Session.I.teamReps = ['Amjad Pr', 'Test Rep'];
      expect(canEditOrder(_order(deliveryDate: future, owner: 'Amjad Pr')),
          isTrue);
    });

    test('a manager of a different team cannot', () {
      Session.I.managedTeam = 'Saneesh';
      Session.I.teamReps = ['Bibin Balaravi'];
      expect(canEditOrder(_order(deliveryDate: future, owner: 'Amjad Pr')),
          isFalse);
    });

    test('nobody can edit after the cutoff, not even the owner', () {
      final past = _iso(today.subtract(const Duration(days: 1)));
      expect(
          canEditOrder(_order(deliveryDate: past, owner: 'Test Rep')), isFalse);
    });

    test('the lock reason says which rule stopped them', () {
      final past = _iso(today.subtract(const Duration(days: 1)));
      expect(orderLockReason(_order(deliveryDate: past)), contains('1 pm'));

      Session.I.salesPerson = 'Test Rep';
      expect(orderLockReason(_order(deliveryDate: future, owner: 'Amjad Pr')),
          contains('Amjad Pr'));

      expect(orderLockReason(_order(deliveryDate: future, owner: 'Test Rep')),
          isEmpty);
    });
  });

  group('Rate lock', () {
    test('rates are open until the manager approves', () {
      expect(ratesLocked(_order(rateApproved: 0)), isFalse);
      expect(ratesLocked({}), isFalse);
    });

    test('and locked afterwards', () {
      expect(ratesLocked(_order(rateApproved: 1)), isTrue);
    });

    test('locking the rate does not close the order to changes', () {
      // The two rules are independent on purpose: the customer can still
      // change how much they want after the price has been agreed.
      final future = _iso(today.add(const Duration(days: 5)));
      final o = _order(deliveryDate: future, rateApproved: 1);
      expect(ratesLocked(o), isTrue);
      expect(canEditOrder(o), isTrue);
    });
  });

  group('Lead completeness before approval', () {
    Map<String, dynamic> lead({
      String gstin = '32AAAAA0000A1Z5',
      String address = 'Main Road, Kochi',
      String route = 'Jaimon D - Adoor',
    }) =>
        {
          'custom_gstin': gstin,
          'custom_address': address,
          'custom_sales_route': route,
        };

    test('a complete lead blocks nothing', () {
      expect(missingLeadDetails(lead()), isEmpty);
    });

    test('each missing detail is named so the manager can chase it', () {
      expect(missingLeadDetails(lead(gstin: '')), ['GST number']);
      expect(missingLeadDetails(lead(address: '')), ['Address']);
      expect(missingLeadDetails(lead(route: '')), ['Sales route']);
    });

    test('an empty lead lists all three', () {
      expect(missingLeadDetails({}),
          ['GST number', 'Address', 'Sales route']);
    });

    test("Frappe's literal 'null' counts as missing, not as a value", () {
      expect(missingLeadDetails(lead(gstin: 'null')), ['GST number']);
      expect(missingLeadDetails({'custom_gstin': '   '}), contains('GST number'));
    });
  });

  group('Re-approval after an edit', () {
    // The bug this pins: the order-level rate flag was being read as "already
    // approved", so an order a rep edited came back to the manager with no
    // Approve button and nothing to do.
    test('an approved order reads as approved', () {
      expect(
          orderApproved({'custom_po_status': 'PO Approved - Ready for SAP'}),
          isTrue);
    });

    test('an order sent back after an edit does not', () {
      expect(
          orderApproved({
            'custom_po_status': 'Pending Rate Approval',
            // Still set: the prices that were signed off stay locked.
            'custom_rate_approved': 1,
          }),
          isFalse);
    });

    test('the rate flag alone never makes an order look approved', () {
      expect(orderApproved({'custom_rate_approved': 1}), isFalse);
      expect(
          orderApproved(
              {'custom_po_status': 'Pending Approval', 'custom_rate_approved': 1}),
          isFalse);
    });

    test('rates stay locked on an order that went back for approval', () {
      // Both must hold at once: not approved, but rates still frozen.
      final o = {
        'custom_po_status': 'Pending Rate Approval',
        'custom_rate_approved': 1,
      };
      expect(orderApproved(o), isFalse);
      expect(ratesLocked(o), isTrue);
    });
  });

  group('Approval wording', () {
    test('reps are never shown a status about a purchase order', () {
      for (final raw in [
        'PO Approved - Ready for SAP',
        'PO Uploaded - Pending Approval',
        'Pending Approval',
        'Pending Rate Approval',
        'No PO Yet',
      ]) {
        expect(approvalLabel(raw).toUpperCase(), isNot(contains('PO ')),
            reason: '"$raw" leaked PO wording');
      }
    });

    test('the stored value that drives production still maps to Approved', () {
      expect(approvalLabel('PO Approved - Ready for SAP'), 'Approved');
    });

    test('orders raised under the old scan flow still read sensibly', () {
      expect(approvalLabel('PO Uploaded - Pending Approval'),
          'Waiting for manager approval');
    });

    test('an empty status is not blank on screen', () {
      expect(approvalLabel(null), 'Not sent for approval');
      expect(approvalLabel(''), 'Not sent for approval');
    });
  });
}
