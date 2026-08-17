// When a captured lead may be deleted.
//
// Deletion is permanent and there is no undo. Every rule here rounds towards
// keeping the record: a lead somebody drove to, or raised an order from, is
// history, and the cost of keeping a junk row is far below the cost of losing
// a real one.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/lead_delete.dart';

void main() {
  group('a lead nothing points at', () {
    test('can be deleted', () {
      expect(leadDeleteRefusal(const LeadDeleteBlockers()), isNull);
    });
  });

  group('a lead that became a customer', () {
    test('is never deleted, whatever else is true of it', () {
      // The account exists because this lead did. Losing the lead loses the
      // trail from first contact to the customer.
      final r = leadDeleteRefusal(
          const LeadDeleteBlockers(customer: 'Royal Tyres-Kozhikode(GST)'));
      expect(r, isNotNull);
      expect(r, contains('Royal Tyres-Kozhikode(GST)'));
    });

    test('outranks visits and orders in what the rep is told', () {
      // One clear reason beats a list. The conversion is the fundamental
      // objection; how many visits it collected on the way does not change it.
      final r = leadDeleteRefusal(const LeadDeleteBlockers(
          customer: 'Some Customer', visits: 4, leadOrders: ['LO-00011']));
      expect(r, contains('Some Customer'));
      expect(r, isNot(contains('4 visits')));
    });
  });

  group('a lead with orders raised against it', () {
    test('names the order, so the rep knows what to go and look at', () {
      final r = leadDeleteRefusal(
          const LeadDeleteBlockers(leadOrders: ['LO-00011']));
      expect(r, contains('LO-00011'));
    });

    test('counts them when there are several, and lists the first few', () {
      final r = leadDeleteRefusal(const LeadDeleteBlockers(
          leadOrders: ['LO-00011', 'LO-00012', 'LO-00013', 'LO-00014']));
      expect(r, contains('4 orders'));
      expect(r, contains('LO-00011'));
      // Not all four - a dialog is not a report.
      expect(r, isNot(contains('LO-00014')));
    });

    test('outranks visits', () {
      final r = leadDeleteRefusal(
          const LeadDeleteBlockers(leadOrders: ['LO-00011'], visits: 2));
      expect(r, contains('LO-00011'));
    });
  });

  group('a lead somebody has visited', () {
    test('says so, and says what deleting it would cost', () {
      // A rep drove there. The visit counts on the day map and in the totals,
      // and deleting the lead silently removes it from both.
      final r = leadDeleteRefusal(const LeadDeleteBlockers(visits: 3));
      expect(r, contains('3 visits'));
      expect(r, contains('day map'));
    });

    test('reads naturally for exactly one', () {
      final r = leadDeleteRefusal(const LeadDeleteBlockers(visits: 1));
      expect(r, contains('A visit is logged'));
      expect(r, isNot(contains('1 visits')));
    });
  });

  group('somebody else\'s lead', () {
    test('cannot be deleted, even by a colleague who can see it', () {
      // In the UAE unit every rep sees every other's leads so they can cover
      // leave. Covering is for serving a colleague's customers, not for
      // destroying their records.
      final r = leadDeleteRefusal(const LeadDeleteBlockers(ownedBy: 'Manikandan'));
      expect(r, contains('Manikandan'));
      expect(r, contains('Only they can delete it'));
    });

    test('outranks every other reason, because it is about who is asking', () {
      final r = leadDeleteRefusal(const LeadDeleteBlockers(
          ownedBy: 'Manikandan', customer: 'X', visits: 9));
      expect(r, contains('Manikandan'));
    });
  });

  group('the confirmation', () {
    test('names the lead, so the wrong row cannot be waved through', () {
      final c = leadDeleteConfirmation('Prasteje Rock');
      expect(c, contains('Prasteje Rock'));
      expect(c, contains('cannot be undone'));
    });
  });

  group('isEmpty', () {
    test('is true only when genuinely nothing is in the way', () {
      expect(const LeadDeleteBlockers().isEmpty, isTrue);
      expect(const LeadDeleteBlockers(visits: 1).isEmpty, isFalse);
      expect(const LeadDeleteBlockers(leadOrders: ['LO-1']).isEmpty, isFalse);
      expect(const LeadDeleteBlockers(customer: 'X').isEmpty, isFalse);
      expect(const LeadDeleteBlockers(ownedBy: 'Y').isEmpty, isFalse);
    });
  });
}
