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
  return head.isEmpty ? 'in progress' : head;
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
    return 'Trip ${describeRunningTrip(running.first)} is still running. End it first.';
  }

  final listed = running.take(3).map(describeRunningTrip).join(', ');
  final rest = running.length - 3;
  return '${running.length} trips still running '
      '($listed${rest > 0 ? ', and $rest more' : ''}). End them first.';
}

/// Why the rep may not punch out yet, or null when they may.
///
/// The day ends in this order: End Trip, then punch out (the user, 24 Nov
/// 2026). A punch-out with a trip still running is how a trip stays open
/// overnight — Nikhil Tk punched out every evening while his trip of 11 Nov
/// ran until the 19th — and the next day's visits then land on the old trip.
///
/// Every running trip counts, today's or older: an old one is the case that
/// matters most. Only the rep's own trips are passed in; a trip they are
/// tagged on is somebody else's to end.
String? punchOutRefusal(List<RunningTrip> running) {
  if (running.isEmpty) return null;
  if (running.length == 1) {
    return 'Your trip ${describeRunningTrip(running.first)} is still running. '
        'End the trip first, then punch out.';
  }
  final listed = running.take(3).map(describeRunningTrip).join(', ');
  final rest = running.length - 3;
  return '${running.length} of your trips are still running '
      '($listed${rest > 0 ? ', and $rest more' : ''}). '
      'End them first, then punch out.';
}

/// Trips still running from a day before [today] (`YYYY-MM-DD`), oldest first.
///
/// The one-trip rule stops a second trip being started; it does nothing about
/// a rep who never presses End Trip. Nikhil Tk's trip of 14 Nov 2026 ran until
/// the evening of the 16th, and his trip of 11 Nov until the 19th. Every visit
/// in between was linked to the old trip, so the Trips list (which shows a
/// trip on the day it started) showed no trip on the 16th or the 18th while
/// the attendance calendar showed him at work, and the 14th's trip claimed
/// two days' kilometres.
///
/// A trip with no date is left out rather than warned about: the warning has
/// to say which day the trip is from, and `trip_date` is always set by the
/// app. Plain string comparison is right for ISO dates.
List<RunningTrip> tripsLeftOpen(List<RunningTrip> running, String today) {
  final old = running
      .where((t) => t.date.trim().isNotEmpty && t.date.compareTo(today) < 0)
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  return old;
}

/// What the home screen says about [tripsLeftOpen], or null when there is
/// nothing to say.
String? tripLeftOpenWarning(List<RunningTrip> running, String today) {
  final old = tripsLeftOpen(running, today);
  if (old.isEmpty) return null;
  if (old.length == 1) {
    return 'Your trip from ${old.first.date} is still running. '
        'End it, then start today\'s trip — until then today\'s visits '
        'go onto that day\'s trip.';
  }
  final listed = old.take(3).map((t) => t.date).join(', ');
  final rest = old.length - 3;
  return '${old.length} trips from earlier days are still running '
      '($listed${rest > 0 ? ', and $rest more' : ''}). End them, then start '
      'today\'s trip.';
}

/// Whether a vehicle leg may be started or ended from its dialog (13 Nov
/// 2026). An odometer leg needs its photo to have reached the server — or to
/// be kept on the phone to go when it can — before the leg is saved.
///
/// The dialogs held the button only while a photo was uploading. One that
/// had failed, or was never taken, let the leg be saved with no photo, and
/// the web showed "No photo" on a pay claim (the user: "the odometer image
/// does not reach the website"). Rounded towards holding: a rep who cannot
/// get a photo through is shown why, with Retry; a leg saved without one is
/// a claim HR cannot check.
bool canSaveOdometerLeg({
  required bool odometerLeg,
  required bool photoReady,
  required bool uploading,
}) =>
    !uploading && (!odometerLeg || photoReady);
