// The rep's commitment on an over-limit order, and who may decide one.
//
// WHY IT EXISTS
//
// An order that took a customer past their credit limit used to reach the GM
// carrying nothing but a number. The reason the rep thought it worth taking —
// "cheque for 50,000 on Friday" — lived in a phone call, and the condition the
// GM attached was the GM's guess at what the customer had offered. Since
// 24 September 2026 the rep writes it down when raising the order, the sales
// manager reads it and can only pass the order on, both managers may comment,
// and the GM's approval turns it into the rep's credit condition.
//
// The GM approves the credit; the sales manager pushes to SAP. The GM's
// approval moves the order to `Pending Final Approval` ("Approved by GM") and
// back to the sales manager, whose Push to SAP is what writes `PO Approved -
// Ready for SAP`.
//
// Pinned by `shared/fixtures/credit_commitment.json`, which the dashboard's
// suite reads too (`client/src/domain/creditCommitment.ts`). The phone raises
// most of these orders and the dashboard decides most of them; a rule that
// held on one side and not the other would not be a rule.

import 'package:manna_field_sales/core/credit.dart';

/// The shortest commitment accepted. Low on purpose — the rep is standing at
/// a counter. It exists to stop "ok", not to make anyone write an essay.
const int kCommitmentMinLength = 10;

/// How far out a condition falls due when the rep named no date.
const int kConditionDefaultDays = 15;

const String kCommitmentMissing =
    'Write what the customer has committed to. This order takes them past '
    'their credit limit, and the general manager decides it on your word.';
const String kCommitmentTooShort =
    'Say what the customer has committed to, and by when. A word or two is '
    'not something anyone can be held to.';
const String kConditionRequired =
    "This order came with the rep's commitment, so approving it makes that "
    'their condition. Keep the words or change them, but do not leave them '
    'empty.';
const String kCommentEmpty = 'Write the comment first.';
const String kSalesManagerCannotApprove =
    'This order takes the customer past their credit limit, so only the '
    'general manager can approve it. Send it to the GM instead.';
const String kGmDoesNotPush =
    'The general manager approves the credit; the sales manager pushes the '
    'order to SAP.';

/// The status the GM's approval writes. An option the Select carried unused
/// until 24 Sep 2026; shown as "Approved by GM". The SAP sync only takes
/// `PO Approved - Ready for SAP`, so nothing at this status reaches SAP.
const String kPoFinalApproval = 'Pending Final Approval';

/// Frappe reads an unset text field back as null, '' or the string 'null'.
String _clean(dynamic v) {
  final s = '${v ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

/// Whether the order carries a commitment at all.
bool hasCommitment(dynamic text) => _clean(text).isNotEmpty;

/// Whether the rep must write one before the order may be sent.
///
/// Exactly when the order will escalate, and by the same test —
/// [overCreditLimit]. Anything looser and an order could reach the GM with
/// nothing to weigh; anything tighter and reps are asked for a promise on
/// orders nobody will ever question, and learn to type anything into the box.
bool commitmentRequired(Map<String, dynamic> customer, double orderTotal,
    {bool isLead = false}) {
  if (isLead) return false;
  return overCreditLimit(customer, orderTotal);
}

/// What is wrong with the rep's text, or null when it will do.
String? commitmentProblem(dynamic text) {
  final s = _clean(text);
  if (s.isEmpty) return kCommitmentMissing;
  if (s.length < kCommitmentMinLength) return kCommitmentTooShort;
  return null;
}

/// What a role may do to an order.
class OrderActions {
  /// Approve to SAP — the sales manager's push. The GM never has it.
  final bool approve;

  /// The GM's approval of the credit, which sends the order back to the
  /// sales manager at [kPoFinalApproval].
  final bool gmApprove;

  /// Send to the general manager.
  final bool escalate;
  final bool reject;

  /// Add a comment to the commitment thread.
  final bool comment;

  const OrderActions({
    this.approve = false,
    this.gmApprove = false,
    this.escalate = false,
    this.reject = false,
    this.comment = false,
  });

  static const none = OrderActions();
}

/// What [role] — 'general_manager', 'sales_manager' or 'rep' — may do to an
/// order at [poStatus].
///
/// The sales manager never approves an over-limit order to SAP until the GM
/// has approved its credit — before that the only ways forward are Send to GM
/// or Reject, and while it is with the GM they no longer decide it at all,
/// though they may still add what they know. Once the GM has approved, their
/// one move is Push to SAP: refusing what the GM approved is the GM's call.
///
/// The GM approves the credit on anything not yet decided — including an order
/// they trimmed back inside the limit, since it was escalated to them — and
/// never pushes to SAP (asked for 24 Sep 2026). Until the sales manager
/// pushes, the GM may still withdraw their approval by rejecting.
///
/// An unrecognised role is refused everything. The screen asks this, and so
/// does [Api.approveSalesOrderPO].
OrderActions orderActions({
  required String role,
  required dynamic poStatus,
  required bool overLimit,
}) {
  final s = '${poStatus ?? ''}'.trim();
  if (s == 'PO Approved - Ready for SAP') return OrderActions.none;

  final isGm = role == 'general_manager';
  final isSm = role == 'sales_manager';
  if (!isGm && !isSm) return OrderActions.none;

  final gmApproved = s == kPoFinalApproval;

  // A rejected order may be decided again but not rejected twice. The phone
  // has no Undo — deciding it again is its only way back. Over the limit, it
  // still only goes to the GM.
  final reject = s != 'Rejected';

  if (isGm) {
    return OrderActions(gmApprove: !gmApproved, reject: reject, comment: true);
  }

  if (gmApproved) return const OrderActions(approve: true, comment: true);
  if (s == 'Pending GM Approval') return const OrderActions(comment: true);
  return OrderActions(
      approve: !overLimit, escalate: overLimit, reject: reject, comment: true);
}

/// Whether approving this order must create the rep's credit condition.
bool conditionRequiredOnApproval(dynamic commitment) =>
    hasCommitment(commitment);

/// What is wrong with the GM's condition text at approval, or null.
///
/// With a commitment on the order the condition is required — the rep
/// promised it and the customer was told it, so the GM may reword it but not
/// drop it. Without one, the old rule stands and it is optional.
String? approvalConditionProblem(dynamic commitment, dynamic condition) {
  if (!conditionRequiredOnApproval(commitment)) return null;
  return _clean(condition).isNotEmpty ? null : kConditionRequired;
}

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The due date the GM starts from.
///
/// The rep's date is what the customer promised, so it leads. No date, or one
/// already gone by — which would make the condition overdue the moment it was
/// made — falls back to fifteen days, which is what the GM has always been
/// offered.
String defaultConditionDue(dynamic commitmentDue, DateTime today) {
  final t = DateTime(today.year, today.month, today.day);
  final raw = _clean(commitmentDue);
  final parsed = raw.length >= 10 ? DateTime.tryParse(raw.substring(0, 10)) : null;
  if (parsed != null && !parsed.isBefore(t)) return _iso(parsed);
  return _iso(DateTime(t.year, t.month, t.day + kConditionDefaultDays));
}

/// The coarse role this login decides orders as.
String orderRoleOf({required bool isGM, required bool isManager}) =>
    isGM ? 'general_manager' : (isManager ? 'sales_manager' : 'rep');

// ------------------------------------------------------------- follow-up ---

/// The name a comment is filed under, or null for a role that writes none.
///
/// `Manna Credit Comment.author_role` is a Select of exactly these three. The
/// rep's is new on 25 Sep 2026: their answer to a condition is kept on the
/// order as well as on the condition, so every answer survives a later one
/// and the GM's follow-up reads the whole conversation.
String? commentAuthorRole(String role) => switch (role) {
      'rep' => 'Sales Rep',
      'sales_manager' => 'Sales Manager',
      'general_manager' => 'General Manager',
      _ => null,
    };

/// Whether [role] may add a follow-up note to an order they approved — the GM
/// alone, at any stage. The sales manager's comments close at the push, and
/// the rep's voice is the answer on the condition.
bool mayAddFollowUpNote(String role) => role == 'general_manager';
