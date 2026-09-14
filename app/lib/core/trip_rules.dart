// One trip at a time.
//
// A trip is a rep's day on the road: it opens with a start odometer, collects
// GPS points every five minutes, and every visit punched while it runs is
// linked to it. All of that assumes there is exactly one trip to link to.
//
// When two run at once the damage is quiet and it compounds:
//
//   * `getActiveTrip` answers with whichever was created last, so visits and
//     expenses land on that one and the older trip keeps collecting nothing.
//   * Only one trip records GPS (see TripTracker), so the other shows a day of
//     driving with no route.
//   * The older trip never ends, so its distance is never closed off and it sits
//     "Active · recording" for weeks — which is what put a 2026-08-28 trip and a
//     2026-09-07 trip on the same screen, both claiming to be recording.
//
// There is no Server Script on this site, so nothing on the ERPNext side will
// refuse the second trip. The refusal has to be here, and it has to name the
// trip that is in the way — a rep told only "cannot start" will try again, then
// start one from another screen, then ring the office.

/// A trip of this rep's that has not been ended.
///
/// Normally there is none or one. It is a list everywhere it is used because
/// the record can already hold more than one, and code that assumes otherwise
/// is how the duplicates stayed hidden.
class RunningTrip {
  /// The ERPNext name, e.g. `TRIP-2026-00042`.
  final String name;

  /// `trip_date`, as `YYYY-MM-DD`.
  final String date;

  /// `purpose` — often empty; reps skip it.
  final String purpose;

  const RunningTrip({required this.name, this.date = '', this.purpose = ''});
}

/// How a trip is named back to the rep.
///
/// Date first, then purpose, because that is exactly how the Trips list reads
/// and the rep has to find the row. The ERPNext name is appended rather than
/// led with: it is the only thing that separates two trips started on the same
/// day, which is precisely the case this rule exists to clean up.
String describeRunningTrip(RunningTrip t) {
  final head = [t.date, t.purpose]
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .join(' · ');
  return head.isEmpty ? t.name : '$head (${t.name})';
}

/// Why a new trip cannot be started, or null when it can.
///
/// The plural case is not defensive padding. Trips started before this rule
/// existed are still open on the record, so a rep can genuinely have two in the
/// way, and telling them about one at a time means ending it, being refused
/// again, and reasonably concluding the app is broken.
String? tripStartRefusal(List<RunningTrip> running) {
  if (running.isEmpty) return null;

  if (running.length == 1) {
    return 'Trip ${describeRunningTrip(running.first)} is still running. '
        'End that trip before starting another.';
  }

  final listed = running.take(3).map(describeRunningTrip).join(', ');
  final rest = running.length - 3;
  return '${running.length} of your trips are still running '
      '($listed${rest > 0 ? ', and $rest more' : ''}). '
      'End them before starting another — only one trip can run at a time, so '
      'the others have been collecting no route and no visits.';
}
