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

enum ActualPunchKind { none, missedIn, missedOut, complete }

/// What a rep actually punched on a day, read off its Attendance Log — shown
/// to whoever approves a regularization for that day, beside the request.
class ActualPunch {
  final ActualPunchKind kind;
  final String? punchIn;
  final String? punchOut;
  const ActualPunch(this.kind, this.punchIn, this.punchOut);

  String get label => switch (kind) {
        ActualPunchKind.none => 'Nothing punched',
        ActualPunchKind.missedIn => 'Missed punch-in',
        ActualPunchKind.missedOut => 'Missed punch-out',
        ActualPunchKind.complete => 'Punched in and out',
      };
}

/// [log] is the day's Attendance Log, or null when there is none. Frappe
/// reads an unset Datetime back as null, '' or 'null'; all three are unset.
ActualPunch actualPunchOf(Map<String, dynamic>? log) {
  String? at(dynamic v) {
    final s = '${v ?? ''}'.trim();
    return s.isEmpty || s == 'null' ? null : s;
  }

  final pin = at(log?['punch_in_time']);
  final pout = at(log?['punch_out_time']);
  final kind = pin == null && pout == null
      ? ActualPunchKind.none
      : pin == null
          ? ActualPunchKind.missedIn
          : pout == null
              ? ActualPunchKind.missedOut
              : ActualPunchKind.complete;
  return ActualPunch(kind, pin, pout);
}
