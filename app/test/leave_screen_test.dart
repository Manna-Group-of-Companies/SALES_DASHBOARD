// The leave balance card renders what the accrual scheme produces.
//
// WHY THIS EXISTS
//
// This screen went dark in the field on 11 September 2026. The balance was
// pulled out of a `Future.wait` with `as Map<String, double>`, and when the
// flat twelve-day allowance became the accrual scheme the API began returning
// a `LeaveBalance` instead. The cast threw inside `build`, which in a release
// build is a blank screen and no message.
//
// The analyzer could not see it: a cast from `dynamic` always compiles. So the
// screen is now typed end to end, and these assert the states it has to draw —
// including the one that has no numbers at all.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/leave_balance.dart';

void main() {
  group('what the card has to be able to draw', () {
    test('a rep on the scheme has every figure the card shows', () {
      final b = leaveBalanceFor(
        accrualFrom: '2026-08-01',
        opening: 22,
        taken: 4,
        pending: 2,
        asOf: DateTime(2026, 12, 15),
      );
      expect(b.onScheme, isTrue);
      expect(b.opening, 22);
      expect(b.accrued, 5);
      expect(b.entitlement, 27);
      expect(b.taken, 4);
      expect(b.pending, 2);
      expect(b.remaining, 23);
      expect(b.overdrawn, isFalse);
    });

    test('a rep NOT on the scheme is a different card, not a zero one', () {
      // Drawing 0 for somebody never enrolled reads as "you have used them
      // all", which would have them treat every day as unpaid.
      final b = leaveBalanceFor(
        accrualFrom: null,
        opening: 0,
        taken: 0,
        pending: 0,
        asOf: DateTime(2026, 12, 15),
      );
      expect(b.onScheme, isFalse);
      expect(b.entitlement, 0);
    });

    test('an overdrawn rep shows the excess, and it is positive', () {
      // The card prints `taken - entitlement`; if that ever went negative the
      // warning would read "-3 days beyond your entitlement".
      final b = leaveBalanceFor(
        accrualFrom: '2026-08-01',
        opening: 0,
        taken: 8,
        pending: 0,
        asOf: DateTime(2026, 12, 15),
      );
      expect(b.overdrawn, isTrue);
      expect(b.remaining, 0);
      expect(b.taken - b.entitlement, greaterThan(0));
      expect(b.taken - b.entitlement, 3);
    });

    test('the entitlement is not a fixed twelve any more', () {
      // The number this screen used to hardcode. Nothing should return it by
      // default now.
      final b = leaveBalanceFor(
        accrualFrom: '2026-08-01',
        opening: 0,
        taken: 0,
        pending: 0,
        asOf: DateTime(2026, 9, 11),
      );
      expect(b.entitlement, isNot(12));
      expect(b.entitlement, 2);
    });

    test('nothing accrues before the scheme starts', () {
      final b = leaveBalanceFor(
        accrualFrom: '2026-12-01',
        opening: 3,
        taken: 0,
        pending: 0,
        asOf: DateTime(2026, 9, 11),
      );
      expect(b.onScheme, isTrue);
      expect(b.accrued, 0);
      expect(b.entitlement, 3);
    });
  });
}
