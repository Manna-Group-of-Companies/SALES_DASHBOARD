// The leave scheme, checked against the figures HR actually supplied.
//
// The app gave everybody twelve days a year until 22 August 2026. The real
// scheme is a running accrual from a carried-forward balance, and the numbers
// below are the ones on HR's sheet — so if the arithmetic ever drifts, it
// drifts against a real person's leave and these fail.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/leave_balance.dart';

LeaveBalance at(String? from, double opening, DateTime asOf,
        {double taken = 0, double pending = 0}) =>
    leaveBalanceFor(
        accrualFrom: from,
        opening: opening,
        taken: taken,
        pending: pending,
        asOf: asOf);

void main() {
  final dec = DateTime(2026, 12, 15);

  group("HR's sheet, as at December 2026", () {
    // Opening balance carried from July, plus one a month for Aug-Dec.
    const sheet = {
      'Pareeth Kb': [0.0, 5.0],
      'Prashanth': [22.0, 27.0],
      'Sirajudheen Kasim': [0.0, 5.0],
      'Amjad Pr': [0.0, 5.0],
      'Jaimon D': [0.0, 5.0],
      'Subhash': [17.5, 22.5],
      'Prasad V': [6.0, 11.0],
      'Bibin Balaravi': [0.0, 5.0],
      'Nikhil Tk': [0.0, 5.0],
    };

    sheet.forEach((rep, v) {
      test('$rep: ${v[0]} carried forward becomes ${v[1]}', () {
        expect(at('2026-08-01', v[0], dec).entitlement, v[1]);
      });
    });
  });

  group('when a day is credited', () {
    test('August credits its day on the first, not the last', () {
      // The instruction was explicit: leave taken in August comes out of
      // August's day. A rep must not be refused on the 2nd for a day they
      // are owed.
      expect(at('2026-08-01', 0, DateTime(2026, 8, 1)).accrued, 1);
      expect(at('2026-08-01', 0, DateTime(2026, 8, 22)).accrued, 1);
      expect(at('2026-08-01', 0, DateTime(2026, 8, 31)).accrued, 1);
    });

    test('September makes it two', () {
      expect(at('2026-08-01', 0, DateTime(2026, 9, 1)).accrued, 2);
    });

    test('accrual keeps going into the next year', () {
      // Not frozen at December. Nothing resets in January, and nobody has to
      // remember to enter new balances.
      expect(at('2026-08-01', 0, DateTime(2027, 1, 15)).entitlement, 6);
      expect(at('2026-08-01', 22, DateTime(2027, 12, 15)).entitlement, 22 + 17);
    });

    test('a scheme that has not started yet credits nothing', () {
      expect(at('2026-12-01', 3, DateTime(2026, 8, 22)).accrued, 0);
      expect(at('2026-12-01', 3, DateTime(2026, 8, 22)).entitlement, 3);
    });
  });

  group('who is on the scheme', () {
    test('no accrual date means no scheme, which is not a zero balance', () {
      // The UAE team, Saneesh and the test rep. Telling them "0 days left"
      // would read as "you have used them all" and make every day unpaid.
      for (final v in [null, '', 'null', 'not-a-date']) {
        final b = at(v, 0, dec);
        expect(b.onScheme, isFalse, reason: 'accrualFrom=$v');
        expect(b.entitlement, 0);
      }
    });

    test('a zero opening balance is still on the scheme and still accrues', () {
      // Five of the nine carry nothing forward. They are not the same as
      // somebody off the scheme, and this is the case that conflates them.
      final b = at('2026-08-01', 0, dec);
      expect(b.onScheme, isTrue);
      expect(b.entitlement, 5);
    });
  });

  group('what is left', () {
    test('approved leave comes off the entitlement', () {
      expect(at('2026-08-01', 22, dec, taken: 4).remaining, 23);
    });

    test('half days count as halves', () {
      expect(at('2026-08-01', 17.5, dec, taken: 0.5).remaining, 22);
    });

    test('pending is shown but not deducted', () {
      // A request that is refused was never leave. Deducting it would refuse
      // a rep days they still have.
      final b = at('2026-08-01', 0, dec, taken: 1, pending: 2);
      expect(b.taken, 1);
      expect(b.pending, 2);
      expect(b.remaining, 4);
    });

    test('remaining never reads negative, but overdrawn is admitted', () {
      final b = at('2026-08-01', 0, dec, taken: 8);
      expect(b.remaining, 0);
      expect(b.overdrawn, isTrue);
    });

    test('taking exactly the entitlement is not overdrawn', () {
      final b = at('2026-08-01', 0, dec, taken: 5);
      expect(b.remaining, 0);
      expect(b.overdrawn, isFalse);
    });
  });
}
