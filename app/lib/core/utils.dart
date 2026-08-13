// Small helpers shared across the app.

import 'package:manna_field_sales/core/server_clock.dart';

/// Today's date as an ISO-8601 `yyyy-MM-dd` string — the format the backend
/// expects for date fields. Read off the server's clock, so a phone set to
/// tomorrow does not file today's work under the wrong date.
String today() => ServerClock.I.now().toIso8601String().substring(0, 10);

/// The clock part of a `yyyy-MM-dd HH:mm:ss` timestamp, for display only.
String hhmm(dynamic stamp) {
  final s = (stamp ?? '').toString();
  return s.length >= 16 ? s.substring(11, 16) : '—';
}

/// Now, as the server sees it. Shorthand for the places that need a DateTime
/// rather than a formatted string, and a reminder not to reach for
/// `DateTime.now()` when a rule depends on the answer.
DateTime serverNow() => ServerClock.I.now();

/// Now, as the `yyyy-MM-dd HH:mm:ss` string the backend stores. Off the
/// server's clock for the same reason [today] is: a phone set wrong must not be
/// able to backdate its own work.
String nowStamp() {
  final t = ServerClock.I.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// Whole days between a `yyyy-MM-dd` date and today, measured against the
/// server's clock. Negative dates and junk both come back as 0, so a missing
/// value reads as "no age known" rather than as something impossibly old.
int daysSince(dynamic isoDate) {
  final s = (isoDate ?? '').toString();
  if (s.length < 10) return 0;
  final then = DateTime.tryParse(s.substring(0, 10));
  if (then == null) return 0;
  final now = ServerClock.I.now();
  final days = DateTime(now.year, now.month, now.day).difference(then).inDays;
  return days < 0 ? 0 : days;
}
