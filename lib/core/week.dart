// Which week an order belongs to.
//
// Weeks run Monday to Sunday. The boundary matters more than it looks: an order
// taken on Sunday evening and one taken on Monday morning are fifteen hours
// apart and belong to different combined orders, so the rule that decides
// which side of midnight they fall on is written once, here, and tested.

import 'package:manna_field_sales/core/server_clock.dart';

/// The Monday beginning the week that contains [d].
///
/// Works on the date alone, never the time, so an order at 23:55 and one at
/// 00:05 the next morning land where a person would expect rather than where
/// the clock happens to leave them.
DateTime weekStart(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

/// The Sunday ending the week that contains [d].
DateTime weekEnd(DateTime d) => weekStart(d).add(const Duration(days: 6));

/// A date as the `yyyy-MM-dd` string the backend stores.
String isoDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// The Monday of the most recent week that has actually finished.
///
/// Grouping is a job done *after* a week closes — a week still running would
/// have orders added to it after the combined order was made, and nothing
/// would go back and update it. On a Wednesday this returns last Monday; the
/// current week only becomes groupable once its Sunday has passed.
DateTime lastClosedWeekStart([DateTime? now]) =>
    weekStart(now ?? ServerClock.I.now())
        .subtract(const Duration(days: 7));

/// True once the week beginning [start] has finished.
bool isWeekClosed(DateTime start, [DateTime? now]) {
  final today = now ?? ServerClock.I.now();
  return DateTime(today.year, today.month, today.day)
      .isAfter(weekEnd(start));
}

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// How a week reads to a person: "4 Aug – 10 Aug 2026".
String weekLabel(DateTime start) {
  final end = weekEnd(start);
  final l = '${start.day} ${_months[start.month - 1]}';
  final r = '${end.day} ${_months[end.month - 1]} ${end.year}';
  return '$l – $r';
}
