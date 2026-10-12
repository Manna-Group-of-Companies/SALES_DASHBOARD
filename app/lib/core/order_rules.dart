// When an order can still be changed, and by whom.
//
// An order stays fully open — lines added, lines deleted, quantities changed —
// until the decision that settles it: the sales manager's approval, or their
// sending it to the GM. The status alone decides. There used to be a second
// gate, 1 pm on the delivery date; it was dropped on 11 October 2026 because
// approval, not the calendar, is when the factory takes the order
// (order_locked_after_approval.json, `no_time_cutoff`).

import 'package:manna_field_sales/core/session.dart';

/// What the rep and the sales manager are told once an order is with the GM.
const String kEditLockWithGm =
    'This order is with the general manager. Only they can change it now.';

/// What everyone is told once the GM has approved an order.
const String kEditLockGmApproved =
    'The general manager approved this order as it stands, so it can no '
    'longer be changed. The sales manager pushes it to SAP, or the general '
    'manager rejects it.';

/// Whether an order at [poStatus] may be changed by [role] — `rep`,
/// `sales_manager` or `general_manager` — as far as its approval goes.
///
/// Decided 26 Sep 2026 (order_locked_after_approval.json, `by_role`). Rates
/// come from SAP, so what is left to change is quantities, items and the
/// delivery date, and those stop at the decision that settles the order:
///  - undecided (and Rejected, which the rep is meant to fix): all three;
///  - escalated to the GM: the GM only — they may trim it before deciding;
///  - approved by the GM, or approved and pushed to SAP: nobody.
/// Any other role is refused, as `orderActions` refuses it. Ownership is
/// [canEditOrder]'s, on top of this.
///
/// The statuses are the stored Select values, spelled out as the rest of this
/// file spells them.
bool statusAllowsEdit(dynamic poStatus, String role) {
  if (role != 'rep' && role != 'sales_manager' && role != 'general_manager') {
    return false;
  }
  switch ('${poStatus ?? ''}'.trim()) {
    case 'PO Approved - Ready for SAP':
    case 'Pending Final Approval':
      return false;
    case 'Pending GM Approval':
      return role == 'general_manager';
    default:
      return true;
  }
}

/// The role this login changes orders as, for [statusAllowsEdit]. A manager
/// editing their own order is locked at exactly the same points as a rep, so
/// the distinction only matters for the GM.
String editRole() => Session.I.isGM
    ? 'general_manager'
    : (Session.I.isManager ? 'sales_manager' : 'rep');

/// What a lead order is told once it is approved.
const String kEditLockLeadApproved =
    'This lead order is approved and has gone to the factory as a customer '
    'order. It cannot be changed here — to drop or reduce an item, ring the '
    'manufacturing team.';

/// Whether [order] is a Lead Order, whose approval lives in `status` rather
/// than `custom_po_status`.
bool isLeadOrderDoc(Map<String, dynamic> order) =>
    '${order['doctype'] ?? ''}' == 'Lead Order' ||
    (order['custom_po_status'] == null && order.containsKey('lead'));

/// The approval status the edit rules read, in Sales Order terms.
///
/// A Lead Order keeps its state in `status`, so without this every lead
/// order read as undecided and stayed open after approval (found in review,
/// 26 Sep 2026). Signed off — `Approved` (it has become a Sales Order already
/// with the factory), `PO Uploaded`, `PO Approved - Ready for SAP`,
/// `Converted` — reads as approved; `Pending GM Approval` as itself; the rest
/// as it stands.
String editStatusOf(Map<String, dynamic> order) {
  if (!isLeadOrderDoc(order)) return '${order['custom_po_status'] ?? ''}'.trim();
  final s = '${order['status'] ?? ''}'.trim();
  const signedOff = {
    'Approved',
    'PO Uploaded',
    'PO Approved - Ready for SAP',
    'Converted',
  };
  return signedOff.contains(s) ? 'PO Approved - Ready for SAP' : s;
}

/// Whether this login may change [order].
///
/// The rep who raised it, and the manager whose team they are on. A manager
/// needs it because a customer who rings the office to change an order should
/// not have to wait for their rep to come back into signal.
///
/// Both only until the order is escalated to the GM, and the GM only until
/// they approve it — see [statusAllowsEdit].
bool canEditOrder(Map<String, dynamic> order) {
  /*
   * APPROVAL IS THE END OF EDITING, FOR EVERYONE. Decided 17 September 2026.
   *
   * An approved order is pushed to SAP, and SAP is where it lives from then
   * on. Changes go through the manufacturing team: they reduce or drop a line
   * that has not been made, and where it has been made they ship what exists
   * and leave the rest of the order open. The app then follows SAP.
   *
   * This is not a new restriction so much as an honest one. `Sync-SapOrders`
   * has only ever CREATED a SAP order — there is no code path anywhere that
   * updates one — so an edit made here after approval never reached the
   * factory. It changed the ERPNext document, showed the rep a new quantity,
   * and left SAP building the old one. Refusing the edit is strictly better
   * than pretending it landed.
   *
   * The GM's licence to trim an escalated order stops here too. It exists
   * because an escalation with no power to act is a rubber stamp — but that
   * is about deciding, not about editing an order the factory is already
   * working to. There is no seniority that makes an app edit reach SAP.
   */
  if (orderApproved(order)) return false;

  // Escalation and the GM's approval (26 Sep 2026), and a lead order's own
  // approval, read off `status` (editStatusOf).
  if (!statusAllowsEdit(editStatusOf(order), editRole())) return false;

  if (Session.I.isGM) return true;

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

/// How an order's edit count reads, wherever it is shown.
///
/// One phrasing, used by the rep's order screen, the sales manager's review and
/// the production manager's detail, so the same order does not describe its own
/// history three different ways. Added 21 August 2026.
///
/// Zero says nothing at all: "edited 0 times" is noise on the overwhelming
/// majority of orders, which are raised once and left alone.
String editCountLabel(int count) {
  if (count <= 0) return '';
  return count == 1 ? 'Edited once' : 'Edited $count times';
}

/// Whether this order may be deleted, and by whom.
///
/// Deliberately much narrower than [canEditOrder]. Deleting destroys the
/// record, so it is allowed only where nothing downstream can have acted on it:
///
///  - the rep who raised it (or the GM), and nobody else — a manager tidying
///    up somebody else's order is how an order disappears while a rep is still
///    telling a customer it is coming;
///  - **still a draft**, `docstatus` 0, so nothing is submitted;
///  - **not PO-approved**, so production has never been told about it.
///
/// Anything past that is cancelled through Desk with a human deciding, not
/// deleted from a phone. Added 21 August 2026.
///
/// The stock a deleted order holds must be released FIRST — see
/// `Api.deleteOrder`, which will not delete without it.
bool canDeleteOrder(Map<String, dynamic> order) {
  final n = order['docstatus'];
  final docstatus = n is num ? n.toInt() : int.tryParse('${n ?? 0}') ?? 0;
  if (docstatus != 0) return false;

  // Approved means production has it. Past this point the order is somebody
  // else's work in progress, not just the rep's intention.
  final po = '${order['custom_po_status'] ?? ''}';
  if (po == 'PO Approved - Ready for SAP') return false;

  // No narrower than editing on escalation (26 Sep 2026): with the GM it is
  // the GM's to decide, and once the GM has approved it nobody throws it
  // away — the order would vanish from the queue mid-decision.
  if (!statusAllowsEdit(editStatusOf(order), editRole())) return false;

  if (Session.I.isGM) return true;

  final owner =
      '${order['custom_sales_person'] ?? order['sales_person'] ?? ''}';
  if (owner.isEmpty) return false;
  return Session.I.salesPerson != null && owner == Session.I.salesPerson;
}

/// Why editing is closed, for the rep who is looking at a locked order. Empty
/// when it is open.
String orderLockReason(Map<String, dynamic> order) {
  // Checked first, because it is the reason that will apply to nearly every
  // locked order and it tells the rep what to actually do about it. The
  // SAP number is named when there is one: it is what the manufacturing team
  // will ask for on the phone.
  if (orderApproved(order)) {
    final sap = '${order['custom_sap_sales_order'] ?? ''}'.trim();
    final ref = (sap.isEmpty || sap == 'null') ? '' : ' Quote SAP order $sap.';
    return 'This order is approved and is with the factory. It cannot be '
        'changed here.$ref To drop or reduce an item, ring the manufacturing '
        'team — anything already made will be delivered and the rest of the '
        'order stays open.';
  }
  final po = editStatusOf(order);
  if (isLeadOrderDoc(order) && po == 'PO Approved - Ready for SAP') {
    return kEditLockLeadApproved;
  }
  if (po == 'Pending Final Approval') return kEditLockGmApproved;
  if (po == 'Pending GM Approval' &&
      !statusAllowsEdit(po, editRole())) {
    return kEditLockWithGm;
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
    // The GM approved the credit; the sales manager has still to push it to
    // SAP. Not "Approved" — nothing has reached the factory yet.
    case 'Pending Final Approval':
      return 'Approved by GM';
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
  // `Converted` is what the dashboard writes when it approves a lead order;
  // the phone writes `Approved`. Missing it (until 11 Oct 2026) left a lead
  // order approved on the web open to a second approval here, which raises a
  // second Sales Order. The twin is `leadOrderApproved` in orderStatus.ts.
  const done = {'Approved', 'PO Approved - Ready for SAP', 'Converted'};
  return done.contains('${order['status'] ?? ''}'.trim());
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
// Every check here runs on the phone, and the dashboard repeats it; nothing on
// the server re-runs it. They stop an honest rep from making a change the
// factory cannot act on. They do not stop a determined one. If that
// distinction ever starts to matter, the status gate belongs in a Before Save
// Server Script, which the site's plan has allowed since 7 September 2026.
