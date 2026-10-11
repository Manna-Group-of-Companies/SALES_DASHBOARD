// When an order can still be changed, and by whom.
//
// The approval status decides, and nothing else. The 1 pm delivery-day cutoff
// that used to sit on top was dropped on 11 October 2026; it is pinned here as
// gone, because a date-based lock is an easy thing to put back by accident.

import 'dart:convert';
import 'dart:io';

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
    Session.I.isGM = false;
  });

  tearDown(() {
    Session.I.salesPerson = null;
    Session.I.managedTeam = null;
    Session.I.teamReps = [];
    Session.I.isGM = false;
  });

  group('The delivery date has no say (11 Oct 2026)', () {
    final past = _iso(today.subtract(const Duration(days: 2)));

    test('an undecided order past its delivery date is still open to its rep',
        () {
      expect(canEditOrder(_order(deliveryDate: past, owner: 'Test Rep')),
          isTrue);
      expect(orderLockReason(_order(deliveryDate: past, owner: 'Test Rep')),
          isEmpty);
    });

    test('and to their manager', () {
      Session.I.managedTeam = 'Pareeth';
      Session.I.teamReps = ['Amjad Pr'];
      expect(canEditOrder(_order(deliveryDate: past, owner: 'Amjad Pr')),
          isTrue);
    });

    test('today, after 1 pm, is no different from any other day', () {
      expect(canEditOrder(_order(deliveryDate: _iso(today), owner: 'Test Rep')),
          isTrue);
    });

    test('an order with no delivery date is open too', () {
      expect(canEditOrder(_order(owner: 'Test Rep')), isTrue);
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

    test('the lock reason says which rule stopped them', () {
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

  /*
   * Approval ends editing, for everyone. Pinned by
   * `shared/fixtures/order_locked_after_approval.json`, which the dashboard's
   * suite reads too.
   *
   * The reason it matters: `Sync-SapOrders.ps1` only ever CREATES a SAP order.
   * Nothing updates one. So an edit saved after approval changed the ERPNext
   * document and left the factory building the old quantities.
   */
  group('An approved order is locked', () {
    final future = _iso(today.add(const Duration(days: 7)));

    Map<String, dynamic> approved({String? sap}) => {
          ..._order(deliveryDate: future, owner: 'Test Rep'),
          'custom_po_status': 'PO Approved - Ready for SAP',
          if (sap != null) 'custom_sap_sales_order': sap,
        };

    test('the owning rep cannot edit it, though they could a moment before',
        () {
      expect(canEditOrder(_order(deliveryDate: future, owner: 'Test Rep')),
          isTrue);
      expect(canEditOrder(approved()), isFalse);
    });

    test('neither can the manager whose team it is', () {
      Session.I.managedTeam = 'Pareeth';
      Session.I.teamReps = ['Test Rep'];
      expect(canEditOrder(approved()), isFalse);
    });

    test('and neither can the GM', () {
      // The GM may trim an order while it is with them, which is about
      // deciding, not about editing an order the factory is already working
      // to. No seniority makes an app edit reach SAP.
      Session.I.isGM = true;
      expect(canEditOrder(approved()), isFalse);
      // Any rep's undecided order is still the GM's to change.
      expect(canEditOrder(_order(deliveryDate: future, owner: 'Amjad Pr')),
          isTrue);
      Session.I.isGM = false;
    });

    test('the reason names the SAP order, which is what the factory asks for',
        () {
      final r = orderLockReason(approved(sap: '404'));
      expect(r, contains('approved'));
      expect(r, contains('factory'));
      expect(r, contains('SAP order 404'));
      expect(r, contains('manufacturing team'));
    });

    test('and invents no number when the order has not reached SAP yet', () {
      final r = orderLockReason(approved());
      expect(r, contains('manufacturing team'));
      expect(r, isNot(contains('SAP order ')));
    });

    test('an unapproved order is not locked at all', () {
      expect(orderLockReason(_order(deliveryDate: future, owner: 'Test Rep')),
          isEmpty);
    });

    test('deleting stays refused, as it already was', () {
      expect(canDeleteOrder(approved()), isFalse);
    });
  });

  /*
   * Escalation and the GM's approval, decided 26 September 2026. Read from
   * shared/fixtures/order_locked_after_approval.json (by_role), which the
   * dashboard's suite reads too: the rep and the sales manager stop at the
   * escalation, the GM at their own approval.
   */
  group('Who may change an order at each stage of approval', () {
    final fixture = json.decode(
            File('../shared/fixtures/order_locked_after_approval.json')
                .readAsStringSync())
        as Map<String, dynamic>;
    final future = _iso(today.add(const Duration(days: 7)));

    test('the lock messages match the fixture word for word', () {
      final m = fixture['messages'] as Map<String, dynamic>;
      expect(kEditLockWithGm, m['with_gm']);
      expect(kEditLockGmApproved, m['gm_approved']);
    });

    test('the fixture\'s dated cases: a past delivery date locks nothing', () {
      // The fixture's orders name no rep, so each is read as the owner's.
      var dated = 0;
      for (final c
          in (fixture['can_edit'] as List).cast<Map<String, dynamic>>()) {
        final order = (c['order'] as Map).cast<String, dynamic>();
        if (order['delivery_date'] == null) continue;
        dated++;
        expect(canEditOrder({...order, 'custom_sales_person': 'Test Rep'}),
            c['expect'],
            reason: c['why'] as String);
      }
      for (final c
          in (fixture['lock_reason'] as List).cast<Map<String, dynamic>>()) {
        if (c['expect_empty_for_owner'] != true) continue;
        final order = (c['order'] as Map).cast<String, dynamic>();
        expect(orderLockReason({...order, 'custom_sales_person': 'Test Rep'}),
            isEmpty,
            reason: c['why'] as String);
      }
      expect(dated, greaterThan(0), reason: 'or this proves nothing');
    });

    test('an unrecognised role is refused, as orderActions refuses it', () {
      expect(statusAllowsEdit('Pending Approval', 'production_manager'), isFalse);
      expect(statusAllowsEdit('Pending Approval', ''), isFalse);
    });

    for (final c in (fixture['by_role'] as List).cast<Map<String, dynamic>>()) {
      final po = c['po_status'];
      test(c['why'], () {
        for (final role in ['rep', 'sales_manager', 'general_manager']) {
          expect(statusAllowsEdit(po, role), c[role], reason: role);
        }

        // And the same through canEditOrder, as each login would see it.
        final order = {
          ..._order(deliveryDate: future, owner: 'Test Rep'),
          'custom_po_status': po,
        };
        expect(canEditOrder(order), c['rep'], reason: 'owning rep');

        Session.I.salesPerson = 'Pareeth Kb';
        Session.I.managedTeam = 'Pareeth';
        Session.I.teamReps = ['Test Rep'];
        expect(canEditOrder(order), c['sales_manager'], reason: 'sales manager');

        Session.I.managedTeam = null;
        Session.I.teamReps = [];
        Session.I.salesPerson = null;
        Session.I.isGM = true;
        expect(canEditOrder(order), c['general_manager'], reason: 'GM');
      });
    }

    test('the rep is told why when the GM has it', () {
      final order = {
        ..._order(deliveryDate: future, owner: 'Test Rep'),
        'custom_po_status': 'Pending GM Approval',
      };
      expect(orderLockReason(order), kEditLockWithGm);
    });

    test('and everyone is told why once the GM has approved it', () {
      final order = {
        ..._order(deliveryDate: future, owner: 'Test Rep'),
        'custom_po_status': 'Pending Final Approval',
      };
      expect(orderLockReason(order), kEditLockGmApproved);
      Session.I.isGM = true;
      expect(orderLockReason(order), kEditLockGmApproved);
    });

    test('the GM editing an order with them is not told it is locked', () {
      Session.I.isGM = true;
      final order = {
        ..._order(deliveryDate: future, owner: 'Test Rep'),
        'custom_po_status': 'Pending GM Approval',
      };
      expect(orderLockReason(order), isNot(kEditLockWithGm));
    });
  });

  /*
   * Found in review, 26 Sep 2026: a Lead Order keeps its approval in
   * `status`, so it read as undecided for ever; and deleting ignored
   * escalation.
   */
  group('Lead orders and deleting follow the same stages', () {
    final future = _iso(today.add(const Duration(days: 7)));
    Map<String, dynamic> lead(String status) => {
          'doctype': 'Lead Order',
          'name': 'LO-0001',
          'lead': 'CRM-LEAD-2026-04130',
          'sales_person': 'Test Rep',
          'delivery_date': future,
          'status': status,
        };

    test('an approved lead order is shut, with its own reason', () {
      for (final s in ['Approved', 'PO Uploaded', 'PO Approved - Ready for SAP', 'Converted']) {
        expect(canEditOrder(lead(s)), isFalse, reason: s);
        expect(orderLockReason(lead(s)), kEditLockLeadApproved, reason: s);
      }
    });

    test('a pending or rejected lead order stays open to its rep', () {
      expect(canEditOrder(lead('Pending Approval')), isTrue);
      expect(canEditOrder(lead('Rejected')), isTrue);
    });

    test('a lead order with the GM is for the GM alone', () {
      expect(canEditOrder(lead('Pending GM Approval')), isFalse);
      Session.I.isGM = true;
      expect(canEditOrder(lead('Pending GM Approval')), isTrue);
    });

    test('the rep cannot delete an order once it is with the GM, or approved by the GM', () {
      Map<String, dynamic> so(String po) => {
            ..._order(deliveryDate: future, owner: 'Test Rep'),
            'docstatus': 0,
            'custom_po_status': po,
          };
      expect(canDeleteOrder(so('Pending Approval')), isTrue);
      expect(canDeleteOrder(so('Pending GM Approval')), isFalse);
      expect(canDeleteOrder(so('Pending Final Approval')), isFalse);
      Session.I.isGM = true;
      expect(canDeleteOrder(so('Pending GM Approval')), isTrue);
      expect(canDeleteOrder(so('Pending Final Approval')), isFalse);
    });

    test('a Sales Order is never mistaken for a lead order', () {
      expect(isLeadOrderDoc(_order(deliveryDate: future)), isFalse);
      expect(editStatusOf({'custom_po_status': ' Pending GM Approval '}), 'Pending GM Approval');
    });
  });
}
