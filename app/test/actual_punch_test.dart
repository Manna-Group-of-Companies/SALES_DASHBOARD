import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/attendance_rules.dart';

void main() {
  group('actualPunchOf', () {
    test('a day with no attendance log is nothing punched', () {
      expect(actualPunchOf(null).kind, ActualPunchKind.none);
    });

    test('punched in and never out is a missed punch-out', () {
      final a = actualPunchOf({
        'punch_in_time': '2026-10-10 09:12:00',
        'punch_out_time': null,
      });
      expect(a.kind, ActualPunchKind.missedOut);
      expect(a.punchIn, '2026-10-10 09:12:00');
      expect(a.label, 'Missed punch-out');
    });

    test('Frappe\'s three spellings of unset all count as unset', () {
      for (final unset in [null, '', 'null']) {
        expect(
            actualPunchOf({'punch_in_time': unset, 'punch_out_time': unset})
                .kind,
            ActualPunchKind.none);
      }
    });

    test('an out with no in is a missed punch-in', () {
      expect(
          actualPunchOf({'punch_out_time': '2026-10-10 18:00:00'}).kind,
          ActualPunchKind.missedIn);
    });

    test('both punches present is a complete day', () {
      expect(
          actualPunchOf({
            'punch_in_time': '2026-10-10 09:00:00',
            'punch_out_time': '2026-10-10 18:00:00',
          }).kind,
          ActualPunchKind.complete);
    });
  });
}
