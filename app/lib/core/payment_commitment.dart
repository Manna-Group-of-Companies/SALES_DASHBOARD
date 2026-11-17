// The 10-day payment commitment ladder on an order (17 Nov 2026).
//
// An order whose customer is overdue more than 30 days past their payment
// terms, or which takes them past their credit limit, needs a credit decision.
// The Manager approves it only with a payment commitment of at most 10 days
// (over the limit only within their authority). A customer who missed a
// commitment goes to the GM, bypassing the Manager, until what was overdue is
// cleared; the GM may give another 10 days or reject. Everything is recorded
// in ERPNext (Manna Payment Commitment); SAP gets only approved orders.
//
// Paired with client/src/domain/paymentCommitment.ts; both read
// shared/fixtures/payment_commitment.json, and the manna_payment_commitment
// Server Scripts enforce it. Errors fall toward the GM: an unreadable figure
// never lets an order skip a decision it needs.

import 'package:manna_field_sales/core/credit.dart';

const int kPcMaxDays = 10;

/// Overdue past terms by MORE than this many days needs a commitment.
const int kPcOverdueDays = 30;

const String kPcRunning = 'Running';
const String kPcUnchecked = 'Unchecked';
const String kPcKept = 'Kept';
const String kPcMissed = 'Missed';
const String kPcCancelled = 'Cancelled';

/// What the Manager and GM screens call an order.
const String kStageManager = 'Pending Manager Approval';
const String kStageGm = 'Sent to GM';
const String kStageGmApproved = 'GM Approved';
const String kStageRejected = 'Rejected';
const String kStagePaymentPending = 'Payment Pending';
const String kStagePushed = 'SAP Pushed';
const String kStageApproved = 'Approved';

double _r2(double v) => (v * 100).roundToDouble() / 100;

class PcNeeds {
  /// Overdue past terms, and the oldest more than 30 days late.
  final bool overdue30;
  final bool overLimit;

  /// Outstanding + this order beyond the limit; 0 when within it.
  final double excess;
  final bool needs;
  const PcNeeds(this.overdue30, this.overLimit, this.excess, this.needs);
}

PcNeeds pcNeeds(Map<String, dynamic> customer, double orderTotal) {
  final a = agingOf(customer);
  final overdue30 = overduePastTerms(customer) > kOverdueTolerance && overdueDaysOf(customer) > kPcOverdueDays;
  final overLimit = a.creditLimit > 0 && a.total + orderTotal > a.creditLimit;
  final excess = overLimit ? _r2(a.total + orderTotal - a.creditLimit) : 0.0;
  return PcNeeds(overdue30, overLimit, excess, overdue30 || overLimit);
}

/// manager | manager_commitment | gm: where an order waiting for approval goes.
String pcRoute({
  required bool needs,
  required bool overLimit,
  required double excess,
  required double authority,
  required bool gmLock,
  required bool capReached,
}) {
  if (gmLock) return 'gm';
  if (!needs) return 'manager';
  if (overLimit && !(authority > 0 && excess <= authority)) return 'gm';
  if (capReached) return 'gm';
  return 'manager_commitment';
}

String _s(Object? v) {
  final s = '${v ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

/// A missed commitment not yet cleared sends the customer's orders to the GM.
bool pcGmLock(List<Map> commitments) =>
    commitments.any((c) => _s(c['status']) == kPcMissed && _s(c['cleared_on']).isEmpty);

DateTime? _day(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  return m == null ? null : DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

const Map<String, String> kPcMessages = {
  'date_past': 'Choose a payment commitment date from today on.',
  'too_long': 'A payment commitment may be at most 10 days.',
  'remarks': 'Enter your remarks.',
};

/// Manager or GM: a date within 10 calendar days of the approval, and remarks.
/// null when allowed, else date_past | too_long | remarks.
String? pcCheckApproval({required String approvedOn, required String commitment, required String remarks}) {
  final a = _day(approvedOn), c = _day(commitment);
  if (a == null || c == null || c.isBefore(a)) return 'date_past';
  if (c.difference(a).inDays > kPcMaxDays) return 'too_long';
  if (remarks.trim().isEmpty) return 'remarks';
  return null;
}

String _cut(String s, int n) => s.length > n ? s.substring(0, n) : s;

/// kept | running | missed | missed_cleared | unchecked | none: what the
/// latest synced SAP figures say about a commitment. Kept when nothing is
/// overdue on figures synced after the approval, by the end of the commitment
/// day; missed only on figures synced after that day, never on stale ones.
String pcTrack({
  required String status,
  required String approvedOn,
  required String commitment,
  required String today,
  required double overdueNow,
  required String syncedAt,
}) {
  if (status != kPcRunning && status != kPcUnchecked) return 'none';
  final synced = _cut(syncedAt, 19);
  final fresh = synced.isNotEmpty && synced.compareTo(_cut(approvedOn, 19)) > 0;
  final syncedDay = _cut(synced, 10);
  final day = _cut(commitment, 10);
  final clear = overdueNow <= kOverdueTolerance;
  if (fresh && clear && syncedDay.compareTo(day) <= 0) return 'kept';
  if (_cut(today, 10).compareTo(day) <= 0) return 'running';
  if (fresh && syncedDay.compareTo(day) > 0) return clear ? 'missed_cleared' : 'missed';
  return 'unchecked';
}

/// The stage an order shows on the Manager's and GM's lists.
String pcOrderStage({required String poStatus, required bool pushed, required String commitment}) {
  switch (poStatus.trim()) {
    case 'Rejected':
      return kStageRejected;
    case 'Pending GM Approval':
      return kStageGm;
    case 'Pending Final Approval':
      return kStageGmApproved;
    case 'PO Approved - Ready for SAP':
      if (commitment == kPcRunning || commitment == kPcUnchecked) return kStagePaymentPending;
      return pushed ? kStagePushed : kStageApproved;
    default:
      return kStageManager;
  }
}
