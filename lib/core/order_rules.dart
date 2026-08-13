// When an order can still be changed, and by whom.
//
// An order stays fully open — lines added, lines deleted, quantities changed —
// until 1 pm on the day the customer wants it delivered. That is the last
// moment the factory can still act on a change, so it is the deadline rather
// than anything measured from when the order was raised.
//
// Judged against the server's clock, for the same reason attendance is: a rep
// controls the phone's clock, and this deadline decides whether a change is
// allowed. Without a server script the backend cannot re-check it, so the
// clock the app trusts is the only defence there is — see the note at the
// bottom of this file.

import 'package:manna_field_sales/core/server_clock.dart';
import 'package:manna_field_sales/core/session.dart';

/// The hour of the delivery date after which an order is frozen.
const int kOrderEditCutoffHour = 13;

/// The moment an order stops being editable: 1 pm on its required delivery
/// date. Null when the order has no delivery date, which is treated as
/// permanently open rather than permanently shut — an order without a date is
/// a data problem, and refusing to let anyone fix it would make that worse.
DateTime? orderEditDeadline(dynamic deliveryDate) {
  final s = '${deliveryDate ?? ''}';
  if (s.length < 10) return null;
  final d = DateTime.tryParse(s.substring(0, 10));
  if (d == null) return null;
  return DateTime(d.year, d.month, d.day, kOrderEditCutoffHour);
}

/// Whether the cutoff has passed.
bool orderEditWindowOpen(dynamic deliveryDate) {
  final deadline = orderEditDeadline(deliveryDate);
  if (deadline == null) return true;
  return ServerClock.I.now().isBefore(deadline);
}

/// Whether this login may change [order].
///
/// The rep who raised it, and the manager whose team they are on. A manager
/// needs it because a customer who rings the office to change an order should
/// not have to wait for their rep to come back into signal.
bool canEditOrder(Map<String, dynamic> order) {
  // The general manager is not bound by the deadline, by ownership, or by the
  // rate lock. Everything below exists to stop an order changing under the
  // people acting on it; the GM is the person those rules escalate *to*, and
  // an escalation that arrives with no power to change anything is a rubber
  // stamp. See [ratesLocked] for the price half of the same exemption.
  if (Session.I.isGM) return true;

  if (!orderEditWindowOpen(order['delivery_date'])) return false;

  // A Sales Order names the rep in `custom_sales_person`; a Lead Order, which
  // is our own doctype, uses the plain `sales_person`. Both are the same
  // question — whose order is this.
  final owner =
      '${order['custom_sales_person'] ?? order['sales_person'] ?? ''}';
  if (owner.isEmpty) return false;

  if (Session.I.salesPerson != null && owner == Session.I.salesPerson) {
    return true;
  }
  return Session.I.isManager && Session.I.teamReps.contains(owner);
}

/// Why editing is closed, for the rep who is looking at a locked order. Empty
/// when it is open.
String orderLockReason(Map<String, dynamic> order) {
  if (!orderEditWindowOpen(order['delivery_date'])) {
    final d = orderEditDeadline(order['delivery_date']);
    if (d == null) return 'This order can no longer be changed.';
    return 'Changes closed at 1 pm on '
        '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}, '
        'the required delivery date.';
  }
  // A Sales Order names the rep in `custom_sales_person`; a Lead Order, which
  // is our own doctype, uses the plain `sales_person`. Both are the same
  // question — whose order is this.
  final owner =
      '${order['custom_sales_person'] ?? order['sales_person'] ?? ''}';
  if (owner.isNotEmpty &&
      owner != Session.I.salesPerson &&
      !(Session.I.isManager && Session.I.teamReps.contains(owner))) {
    return 'Only $owner or their manager can change this order.';
  }
  return '';
}

/// The approval state in the words a rep uses.
///
/// The stored values still talk about a "PO" because the production dashboard,
/// the monthly sales figures and every existing record key off those exact
/// strings — renaming them would rewrite history to no benefit. Nobody scans a
/// purchase order any more, though, so the rep is not shown a status about one.
String approvalLabel(dynamic rawStatus) {
  switch ('${rawStatus ?? ''}') {
    case 'PO Approved - Ready for SAP':
      return 'Approved';
    case 'Pending Approval':
    case 'PO Uploaded - Pending Approval':
      return 'Waiting for manager approval';
    case 'Pending Rate Approval':
      return 'Waiting for rate approval';
    case 'Pending GM Approval':
      return 'Escalated to GM';
    case 'Rejected':
      return 'Rejected';
    case '':
    case 'null':
    case 'No PO Yet':
      return 'Not sent for approval';
    default:
      return '$rawStatus';
  }
}

/// What a lead is still missing before an order against it can be approved.
///
/// A lead becomes a customer the moment it is first invoiced, and an invoice
/// cannot be raised without a GSTIN and an address. The route is needed for a
/// different reason: production is shown a route and nothing else, so an order
/// against a routeless lead reaches the floor with nowhere to deliver.
///
/// Collected at approval rather than at lead creation on purpose. A rep meeting
/// somebody for the first time should be able to record them in thirty seconds;
/// the paperwork is only owed once there is an order worth invoicing.
List<String> missingLeadDetails(Map<String, dynamic> lead) {
  bool blank(String key) {
    final v = '${lead[key] ?? ''}'.trim();
    return v.isEmpty || v == 'null';
  }

  return [
    if (blank('custom_gstin')) 'GST number',
    if (blank('custom_address')) 'Address',
    if (blank('custom_sales_route')) 'Sales route',
  ];
}

/// Whether the order currently has a decision on it.
///
/// Read off the status, never off `custom_rate_approved`. The rate flag says
/// "prices were signed off at some point"; the status says "there is nothing
/// left to decide". A rep who edits an approved order sends it back, and it has
/// to look like work to do again even though the rates it already had stay
/// locked.
bool orderApproved(Map<String, dynamic> order) =>
    '${order['custom_po_status'] ?? ''}' == 'PO Approved - Ready for SAP';

/// Whether an order has been signed off, asking the right field for its type.
///
/// A lead order has no `custom_po_status` — approving one sets `status` to
/// `Approved` and converts the lead — so [orderApproved] alone reads every
/// lead order as still open. Anything that must not happen after sign-off has
/// to use this instead, or it silently permits on leads what it forbids on
/// customer orders.
bool orderSignedOff(Map<String, dynamic> order, {required bool isLead}) {
  if ((order['custom_rate_approved'] ?? 0) == 1) return true;
  if (!isLead) return orderApproved(order);
  const done = {'Approved', 'PO Approved - Ready for SAP'};
  return done.contains('${order['status'] ?? ''}');
}

/// True once the sales manager has approved the order's rates, which is what
/// locks manual pricing. Adding a line afterwards is still allowed — it just
/// puts the order back in the manager's queue, because a line nobody priced is
/// worse than one nobody re-checked.
/// The general manager is exempt.
///
/// The lock exists so that a price the sales manager signed off cannot be
/// quietly moved afterwards by the rep who quoted it. Somebody still has to be
/// able to move it — a customer negotiates, a costing turns out wrong — and
/// that authority sits with the GM and nowhere else.
bool ratesLocked(Map<String, dynamic> order) =>
    !Session.I.isGM && (order['custom_rate_approved'] ?? 0) == 1;

// A note on what this does and does not guarantee.
//
// Every check here runs on the phone. With Server Scripts the backend re-ran
// the deadline on every write and a modified client could not get past it; the
// site's plan no longer allows that, so these rules bind the app alone. They
// stop an honest rep from making a change the factory cannot act on. They do
// not stop a determined one. If that distinction ever starts to matter, the
// deadline needs to move back to a Before Save script.
