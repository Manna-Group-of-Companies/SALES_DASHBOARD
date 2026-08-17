// When a captured lead may be deleted, and why not.
//
// Deletion is permanent and there is no undo, so this is written as a list of
// reasons to refuse rather than a single boolean. Every refusal names the thing
// that is in the way: a rep who is told "cannot delete" and nothing else will
// try again, then ask somebody, then work around it.
//
// Frappe refuses to delete a document another one links to, and answers with a
// LinkExistsError naming an internal doctype. That message is true and useless
// to a rep standing in a shop. These checks run first so the app can say "this
// lead has 2 visits logged against it" instead.
//
// The rules round towards keeping the record. A lead that represents real work
// — somebody drove to it, or an order was raised from it — is history, and the
// cost of keeping a junk row is far below the cost of losing a real one.

/// What stands in the way of deleting a lead. Empty when nothing does.
class LeadDeleteBlockers {
  /// Sales Visits logged against the lead.
  final int visits;

  /// Lead Orders raised for it.
  final List<String> leadOrders;

  /// The customer this lead became, if it was converted.
  final String? customer;

  /// The rep who owns it, when that is not the person asking.
  final String? ownedBy;

  const LeadDeleteBlockers({
    this.visits = 0,
    this.leadOrders = const [],
    this.customer,
    this.ownedBy,
  });

  bool get isEmpty =>
      visits == 0 && leadOrders.isEmpty && customer == null && ownedBy == null;
}

/// Why this lead cannot be deleted, or null when it can.
///
/// Ordered so the most fundamental objection is the one reported. A converted
/// lead is somebody's customer now; that matters more than how many visits it
/// collected on the way, and saying so is more use than a list.
String? leadDeleteRefusal(LeadDeleteBlockers b) {
  // Not yours. Covering for a colleague is for serving their customers, not
  // for destroying their records — see core/visibility.dart. A duplicate that
  // genuinely needs removing is a thing to ask the owner or a manager for.
  if (b.ownedBy != null) {
    return 'This lead belongs to ${b.ownedBy}. Only they can delete it.';
  }

  if (b.customer != null) {
    return 'This lead was converted into the customer ${b.customer}. '
        'Deleting it would break the trail from the lead to the account.';
  }

  if (b.leadOrders.isNotEmpty) {
    final n = b.leadOrders.length;
    return n == 1
        ? 'Order ${b.leadOrders.first} was raised for this lead. '
            'Delete the order first if it was a mistake.'
        : '$n orders were raised for this lead '
            '(${b.leadOrders.take(3).join(', ')}). '
            'Delete those first if they were a mistake.';
  }

  if (b.visits > 0) {
    return b.visits == 1
        ? 'A visit is logged against this lead. Deleting it would remove that '
            'visit from the day map and the visit totals.'
        : '${b.visits} visits are logged against this lead. Deleting it would '
            'remove them from the day map and the visit totals.';
  }

  return null;
}

/// The confirmation a rep is shown before a lead goes.
///
/// Names the lead. A dialog that says "Delete this lead?" is answered yes by
/// somebody who has already scrolled past the one they meant.
String leadDeleteConfirmation(String leadName) =>
    'Delete "$leadName"? This cannot be undone, and the shop photo and captured '
    'location go with it.';
