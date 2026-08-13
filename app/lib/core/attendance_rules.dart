// The hours a rep may punch inside. Outside them the day goes through
// regularization instead. `server/attendance_log_time_rules.py` enforces the
// same two numbers — change them in both places.

/// Punch-in opens at 05:00.
const int kPunchInFromMinute = 5 * 60;

/// Punch-out closes at the end of the 21:30 minute.
const int kPunchOutUntilMinute = 21 * 60 + 30;

int minuteOfDay(DateTime t) => t.hour * 60 + t.minute;

/// A punch refused because of the time of day, not because anything failed.
/// [regularizeDate] is set when the rep's only way forward is a regularization
/// request for that day, so callers can offer the shortcut.
class AttendanceWindowError implements Exception {
  final String message;
  final DateTime? regularizeDate;
  const AttendanceWindowError(this.message, {this.regularizeDate});
  @override
  String toString() => message;
}
