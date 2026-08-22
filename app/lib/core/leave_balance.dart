// How much paid leave a rep actually has.
//
// WHY THIS EXISTS
//
// The app gave everybody a flat twelve days per financial year and took the
// approved days off it. That was wrong in shape as well as in number. What the
// business actually runs is a **running accrual**: a balance carried forward
// from July 2026, plus one day for every month since, minus what has been
// taken. Prasanth carries 22 and Subhash 17.5; five people carry nothing.
// Nobody has twelve.
//
// NOT EVERYONE IS ON IT
//
// Nine sales people are. The UAE team, Saneesh and the test rep are not, and
// that is deliberate — see shared/DIVERGENCES.md. It is why
// [accrualFrom] being **empty** matters and is not the same as an opening
// balance of zero: five of the nine carry zero and still accrue, while
// somebody off the scheme accrues nothing and must not be told their leave is
// unpaid. [LeaveBalance.onScheme] is that distinction, and every screen has to
// respect it.
//
// WHEN A DAY IS CREDITED
//
// At the START of its month, not the end. A leave taken in August comes out of
// August's day — that was the explicit instruction — so the month of
// [accrualFrom] counts as one immediately.

/// One day of paid leave for every month on the scheme.
///
/// A constant rather than a field because every one of the nine accrues at the
/// same rate. If a unit is ever put on a different one, this becomes a column
/// on Sales Person beside the opening balance.
const double kLeaveAccrualPerMonth = 1.0;

class LeaveBalance {
  /// False when the rep is not on the leave scheme at all. Everything below is
  /// zero in that case and means nothing — say "no leave scheme", never
  /// "0 days left", which reads as "you have used them all".
  final bool onScheme;

  /// Carried forward from before accrual started, net of anything taken then.
  final double opening;

  /// Days credited since accrual began, including the current month.
  final double accrued;

  /// Approved leave since accrual began.
  final double taken;

  /// Applied for and not yet decided. Not deducted — a request that is
  /// refused was never leave — but shown, so a rep does not apply twice for
  /// days they have already asked for.
  final double pending;

  const LeaveBalance({
    required this.onScheme,
    required this.opening,
    required this.accrued,
    required this.taken,
    required this.pending,
  });

  static const LeaveBalance none = LeaveBalance(
      onScheme: false, opening: 0, accrued: 0, taken: 0, pending: 0);

  /// Everything earned so far.
  double get entitlement => opening + accrued;

  /// What is left to take. Never below zero on screen — an over-drawn balance
  /// is real, but "-2 days remaining" invites a rep to work out what they can
  /// still take, and the answer is nothing.
  double get remaining {
    final left = entitlement - taken;
    return left < 0 ? 0 : left;
  }

  /// True when more has been taken than earned. Shown plainly rather than
  /// hidden behind the clamp above: it means days already granted were unpaid.
  bool get overdrawn => entitlement - taken < -0.0001;
}

/// Whole months from [from] to [asOf] inclusive of both ends' months.
///
/// August to August is one month, not zero: the day is credited at the start
/// of its month. Returns 0 when [asOf] is before [from], so a scheme starting
/// next month does not credit anything yet.
int monthsAccrued(DateTime from, DateTime asOf) {
  final months =
      (asOf.year - from.year) * 12 + (asOf.month - from.month) + 1;
  return months < 0 ? 0 : months;
}

/// Work out a rep's balance.
///
/// [accrualFrom] is `Sales Person.custom_leave_accrual_from` — null or empty
/// means not on the scheme.
LeaveBalance leaveBalanceFor({
  required String? accrualFrom,
  required double opening,
  required double taken,
  required double pending,
  required DateTime asOf,
}) {
  final start = _parseDate(accrualFrom);
  if (start == null) return LeaveBalance.none;

  return LeaveBalance(
    onScheme: true,
    opening: opening,
    accrued: monthsAccrued(start, asOf) * kLeaveAccrualPerMonth,
    taken: taken,
    pending: pending,
  );
}

DateTime? _parseDate(String? raw) {
  final s = (raw ?? '').trim();
  // Frappe reads an unset Date back as null, '' or the string 'null'.
  if (s.isEmpty || s == 'null') return null;
  try {
    final p = s.substring(0, 10).split('-').map(int.parse).toList();
    return DateTime(p[0], p[1], p[2]);
  } catch (_) {
    // Unparseable reads as "not on the scheme" rather than as today. Guessing
    // would invent an entitlement nobody granted.
    return null;
  }
}
