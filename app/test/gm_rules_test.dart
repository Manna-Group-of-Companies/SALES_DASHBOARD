// What the general manager may do that nobody else may.
//
// Two exemptions, and both exist for the same reason: the GM is the person the
// other rules escalate *to*. An escalation that arrives with no power to change
// anything is a rubber stamp, so the deadline, the ownership check and the rate
// lock all stop at them.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/order_rules.dart';
import 'package:manna_field_sales/core/session.dart';

void main() {
  setUp(() {
    Session.I.isGM = false;
    Session.I.managedTeam = null;
    Session.I.salesPerson = 'Jaimon D';
    Session.I.teamReps = [];
  });

  tearDown(() {
    Session.I.isGM = false;
    Session.I.salesPerson = null;
  });

  Map<String, dynamic> order({
    String rep = 'Jaimon D',
    String delivery = '2020-01-01', // long past, so the 1 pm rule has closed
    int rateApproved = 1,
  }) =>
      {
        'custom_sales_person': rep,
        'delivery_date': delivery,
        'custom_rate_approved': rateApproved,
      };

  group('editing', () {
    test('a closed order is shut to the rep who raised it', () {
      expect(canEditOrder(order()), isFalse);
    });

    test('the GM can edit it anyway', () {
      Session.I.isGM = true;
      expect(canEditOrder(order()), isTrue);
    });

    test('the GM can edit an order belonging to a rep who is not theirs', () {
      // Ownership is the other gate, and it stops at the GM too. They are not
      // on anybody's team by design.
      Session.I.isGM = true;
      Session.I.salesPerson = null;
      expect(canEditOrder(order(rep: 'Someone Else', delivery: '2099-01-01')),
          isTrue);
    });

    test('an ordinary manager is still bound by the deadline', () {
      Session.I.managedTeam = 'Sales Team';
      Session.I.teamReps = ['Jaimon D'];
      Session.I.salesPerson = 'Pareeth Kb';
      expect(canEditOrder(order()), isFalse);
    });
  });

  group('the rate lock', () {
    test('an approved rate is locked to everyone else', () {
      expect(ratesLocked(order(rateApproved: 1)), isTrue);
    });

    test('the GM can move an approved rate', () {
      Session.I.isGM = true;
      expect(ratesLocked(order(rateApproved: 1)), isFalse);
    });

    test('an unapproved rate is open to everyone', () {
      expect(ratesLocked(order(rateApproved: 0)), isFalse);
      Session.I.isGM = true;
      expect(ratesLocked(order(rateApproved: 0)), isFalse);
    });

    test('the exemption is the GM flag, not being a manager', () {
      // A sales manager must not inherit this. They are the one whose approval
      // set the lock in the first place.
      Session.I.managedTeam = 'Sales Team';
      expect(ratesLocked(order(rateApproved: 1)), isTrue);
    });
  });
}
