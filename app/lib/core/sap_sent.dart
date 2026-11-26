// The line every Sales Order shows about SAP, in a list and when opened:
// whether SAP has it, who approved it, and SAP's order numbers. Asked for by
// the user on 26 Nov 2026.
//
// "Sent to SAP" means SAP has written its number back. Approve & Push only
// asks the order sync to send the order; until a number comes back the order
// reads "Waiting for SAP". A push that never landed must not look like one
// that did.
//
// Pinned by `shared/fixtures/sap_sent.json`; the TypeScript twin is
// `client/src/domain/sapSent.ts`.
const String kPoApprovedForSap = 'PO Approved - Ready for SAP';

const String kSentToSap = 'Sent to SAP';
const String kWaitingForSap = 'Waiting for SAP';
const String kGmApproved = 'GM Approved';
const String kManagerApproved = 'Manager Approved';

class SapSent {
  final bool sent;

  /// [kSentToSap], [kWaitingForSap] or ''.
  final String label;

  /// [kGmApproved], [kManagerApproved] or ''.
  final String approvedBy;

  /// "Manna Treads SO 591 · Hi-Tech SO 599", or '' when SAP has neither.
  final String numbers;

  const SapSent({
    required this.sent,
    required this.label,
    required this.approvedBy,
    required this.numbers,
  });

  /// Straight off a Sales Order document or list row.
  factory SapSent.fromOrder(Map<String, dynamic> o) => sapSent(
        poStatus: o['custom_po_status'],
        gmApprovedBy: o['custom_gm_approved_by'],
        mtSalesOrder: o['custom_mt_sales_order'],
        sapSalesOrder: o['custom_sap_sales_order'],
      );

  /// Nothing worth a line: a caller renders nothing rather than an empty row.
  bool get isEmpty => label.isEmpty && approvedBy.isEmpty && numbers.isEmpty;
}

String _clean(dynamic v) {
  final s = (v == null ? '' : '$v').trim();
  return s == 'null' ? '' : s;
}

SapSent sapSent({
  dynamic poStatus,
  dynamic gmApprovedBy,
  dynamic mtSalesOrder,
  dynamic sapSalesOrder,
}) {
  final po = _clean(poStatus);
  final mt = _clean(mtSalesOrder);
  final ht = _clean(sapSalesOrder);
  final sent = mt.isNotEmpty || ht.isNotEmpty;
  final numbers = [
    if (mt.isNotEmpty) 'Manna Treads SO $mt',
    if (ht.isNotEmpty) 'Hi-Tech SO $ht',
  ].join(' · ');

  // The GM's stamp survives the manager's push, so a GM-approved order stays
  // GM Approved whoever pressed the push. No other status claims an
  // approver: an order the sync sent early was approved by nobody, and
  // Pending Final Approval already reads "GM approved" on its own pill.
  var approvedBy = '';
  if (po == kPoApprovedForSap) {
    approvedBy =
        _clean(gmApprovedBy).isNotEmpty ? kGmApproved : kManagerApproved;
  }

  final label = sent
      ? kSentToSap
      : po == kPoApprovedForSap
          ? kWaitingForSap
          : '';
  return SapSent(
      sent: sent, label: label, approvedBy: approvedBy, numbers: numbers);
}

// ------------------------------------------------------------------ news ---

/// Which orders reached SAP since this device last looked. For the sales
/// managers and the GM only (the user, 26 Nov 2026); reps are not told.
///
/// There is no server push, so this is a diff, like `stage_watch.dart`:
/// [seen] is the orders this device has already shown as in SAP. Null - never
/// looked - reports nothing and takes the baseline, so a first sign-in is not
/// a flood of last month's orders. [seen] only grows, so an order that leaves
/// the window read and comes back is not news twice. Fixture: `news` in
/// sap_sent.json; the TypeScript twin is `sapSentNews`.
({List<Map<String, dynamic>> news, List<String> seen}) sapSentNews(
    List<String>? seen, List<Map<String, dynamic>> orders) {
  final sent = orders.where((o) => SapSent.fromOrder(o).sent).toList();
  final known = {...?seen};
  final news = seen == null
      ? <Map<String, dynamic>>[]
      : sent.where((o) => !known.contains('${o['name']}')).toList();
  final next = [...?seen];
  for (final o in sent) {
    if (!known.contains('${o['name']}')) next.add('${o['name']}');
  }
  return (news: news, seen: next);
}

/// "Sent to SAP · Manna Treads SO 591 · GM Approved", for one news line.
String sapSentHeadline(Map<String, dynamic> o) {
  final s = SapSent.fromOrder(o);
  return [s.label, s.numbers, s.approvedBy].where((x) => x.isNotEmpty).join(' · ');
}
