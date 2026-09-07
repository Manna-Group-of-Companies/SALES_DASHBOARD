// Who may move a credit condition, and when one is overdue.
//
// WHY THIS IS A FILE AND NOT THREE IFS IN A WIDGET
//
// A condition is the record of a promise the GM extracted in exchange for
// letting an over-limit order through. The whole value of it is that the
// person who owes it cannot mark it done. That rule has to hold in the API
// call as well as in the screen, on the phone as well as on the dashboard —
// there are no Server Scripts on this site, so a hidden button is not a
// permission, it is a suggestion.
//
// Pinned by `shared/fixtures/credit_condition.json`, which the dashboard's
// suite reads too.

/// Where a condition is in its life.
const String kCondOpen = 'Open';
const String kCondAwaiting = 'Awaiting Review';
const String kCondClosed = 'Closed';

/// What someone is trying to do to it.
enum CondAction { respond, close, reopen }

/// Whether [actor] may take [action] on a condition currently at [status].
///
/// [actor] is the coarse role — 'gm', 'rep', 'sales_manager'. Anything this
/// does not recognise is refused rather than waved through: an unknown role is
/// not a licence, and erring towards refusal here costs a phone call while
/// erring the other way costs the accountability the feature exists for.
bool canMoveCondition({
  required String status,
  required CondAction action,
  required String actor,
}) {
  final isGm = actor == 'gm';

  switch (action) {
    case CondAction.respond:
      // Only the rep answers, and only while it is still live. Answering a
      // closed condition changes nothing and would reopen a settled matter by
      // the back door.
      return actor == 'rep' &&
          (status == kCondOpen || status == kCondAwaiting);

    case CondAction.close:
      // The GM alone. This is the line the whole feature is drawn around.
      return isGm && (status == kCondOpen || status == kCondAwaiting);

    case CondAction.reopen:
      // The GM may send one back for more, or reopen one that turned out not
      // to have been met after all.
      return isGm && (status == kCondAwaiting || status == kCondClosed);
  }
}

/// What the status becomes, or null if [actor] may not do this.
String? nextConditionStatus({
  required String status,
  required CondAction action,
  required String actor,
}) {
  if (!canMoveCondition(status: status, action: action, actor: actor)) {
    return null;
  }
  switch (action) {
    case CondAction.respond:
      return kCondAwaiting;
    case CondAction.close:
      return kCondClosed;
    case CondAction.reopen:
      return kCondOpen;
  }
}

/// Whether a condition is late.
///
/// Overdue is what is still owed *today* — a condition closed after its date
/// is closed, not overdue. Showing it in red forever would turn the list into
/// a history of lateness that nobody can act on, and bury the ones that still
/// need chasing.
///
/// No deadline is never late. Frappe reads an unset Date back as null, '' or
/// the string 'null' depending on how it was written, and all three mean the
/// GM did not set one.
bool conditionOverdue({
  required String status,
  required String? dueDateIso,
  required DateTime today,
}) {
  if (status == kCondClosed) return false;
  final raw = (dueDateIso ?? '').trim();
  if (raw.isEmpty || raw == 'null') return false;
  final due = DateTime.tryParse(raw);
  if (due == null) return false;
  final d = DateTime(due.year, due.month, due.day);
  final t = DateTime(today.year, today.month, today.day);
  // Due today is not yet late — the rep has the day.
  return d.isBefore(t);
}
