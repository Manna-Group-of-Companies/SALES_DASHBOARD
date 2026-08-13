// Which week an order falls in.
//
// The boundary is the whole point. An order taken late on Sunday and one taken
// early on Monday are hours apart and belong to different combined orders, so
// these check the edges rather than the comfortable middle of a week.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/week.dart';

void main() {
  // 5 Aug 2026 is a Wednesday. Its week runs Mon 3 Aug – Sun 9 Aug.
  final wed = DateTime(2026, 8, 5, 14, 30);

  group('week boundaries', () {
    test('a midweek day resolves to its Monday and Sunday', () {
      expect(isoDate(weekStart(wed)), '2026-08-03');
      expect(isoDate(weekEnd(wed)), '2026-08-09');
      expect(weekStart(wed).weekday, DateTime.monday);
      expect(weekEnd(wed).weekday, DateTime.sunday);
    });

    test('Monday is the start of its own week, not the previous one', () {
      final mon = DateTime(2026, 8, 3, 0, 1);
      expect(isoDate(weekStart(mon)), '2026-08-03');
    });

    test('Sunday belongs to the week that is ending, not the next one', () {
      // The costly off-by-one: a Sunday order rolling into next week would be
      // grouped a week late, after its combined order had already been made.
      final sun = DateTime(2026, 8, 9, 23, 55);
      expect(isoDate(weekStart(sun)), '2026-08-03');
      expect(isoDate(weekEnd(sun)), '2026-08-09');
    });

    test('Sunday night and Monday morning fall in different weeks', () {
      final sunNight = DateTime(2026, 8, 9, 23, 55);
      final monMorning = DateTime(2026, 8, 10, 0, 5);
      expect(weekStart(sunNight), isNot(weekStart(monMorning)));
      expect(isoDate(weekStart(monMorning)), '2026-08-10');
    });

    test('the time of day never moves an order between weeks', () {
      for (final h in [0, 1, 6, 12, 18, 23]) {
        expect(isoDate(weekStart(DateTime(2026, 8, 5, h, 59))), '2026-08-03');
      }
    });

    test('a week is always exactly seven days', () {
      var d = DateTime(2026, 1, 1);
      for (var i = 0; i < 400; i++) {
        expect(weekEnd(d).difference(weekStart(d)).inDays, 6, reason: '$d');
        d = d.add(const Duration(days: 1));
      }
    });

    test('weeks work across a month and a year boundary', () {
      // 31 Dec 2026 is a Thursday; its week runs Mon 28 Dec – Sun 3 Jan 2027.
      final nye = DateTime(2026, 12, 31);
      expect(isoDate(weekStart(nye)), '2026-12-28');
      expect(isoDate(weekEnd(nye)), '2027-01-03');
    });

    test('a leap day sits in the right week', () {
      // 29 Feb 2028 is a Tuesday.
      final leap = DateTime(2028, 2, 29);
      expect(isoDate(weekStart(leap)), '2028-02-28');
    });
  });

  group('which week can be grouped', () {
    test('the current week is not closed', () {
      // Grouping a running week would make a combined order that later orders
      // never join, because nothing goes back to update it.
      expect(isWeekClosed(weekStart(wed), wed), isFalse);
    });

    test('a week is still open on its own Sunday', () {
      final sun = DateTime(2026, 8, 9, 20, 0);
      expect(isWeekClosed(weekStart(sun), sun), isFalse);
    });

    test('a week closes on the Monday after it', () {
      final mon = DateTime(2026, 8, 10, 0, 5);
      expect(isWeekClosed(DateTime(2026, 8, 3), mon), isTrue);
    });

    test('the last closed week is the one before the current one', () {
      expect(isoDate(lastClosedWeekStart(wed)), '2026-07-27');
      expect(isWeekClosed(lastClosedWeekStart(wed), wed), isTrue);
    });

    test('on a Monday the week that just ended is the one offered', () {
      final mon = DateTime(2026, 8, 10, 9, 0);
      expect(isoDate(lastClosedWeekStart(mon)), '2026-08-03');
    });
  });

  group('how a week reads', () {
    test('a week inside one month', () {
      expect(weekLabel(DateTime(2026, 8, 3)), '3 Aug – 9 Aug 2026');
    });

    test('a week spanning two months', () {
      expect(weekLabel(DateTime(2026, 7, 27)), '27 Jul – 2 Aug 2026');
    });

    test('a week spanning two years names the year it ends in', () {
      expect(weekLabel(DateTime(2026, 12, 28)), '28 Dec – 3 Jan 2027');
    });
  });
}
