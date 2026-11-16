// Temporary credit extension with a payment commitment (16 Nov 2026, the
// user's strict instruction). A separate workflow: order approval, credit
// periods and credit conditions are untouched. A rep (or the team's manager)
// asks on an order that takes a customer past their SAP credit limit; the
// manager approves an extra amount within their authority with a commitment of
// at most 10 days, which pushes it to SAP; SAP's payments decide Paid or
// Payment Commitment Overdue, which goes to the GM.
//
// Enforced by the manna_credit_extension Server Script
// (app/server/credit_extension.py), which hands each row can_* flags; the
// phone offers a button only when the server says so AND this rule agrees.
// shared/fixtures/credit_extension.json pins both; the dashboard's copy is
// client/src/domain/creditExtension.ts.

const int kExtensionManagerMaxDays = 10;

const String kXtPendingManager = 'Pending Manager';
const String kXtPendingGm = 'Pending GM';
const String kXtSending = 'Sending to SAP';
const String kXtPushFailed = 'SAP Push Failed';
const String kXtActive = 'Active';
const String kXtPaid = 'Paid';
const String kXtOverdue = 'Payment Commitment Overdue';
const String kXtRenewed = 'Renewed by GM';
const String kXtRejected = 'Rejected';
const String kXtRejectedByGm = 'Rejected by GM';

String xtRouteStatus(int missedBefore, bool openExtension) =>
    missedBefore > 0 || openExtension ? kXtPendingGm : kXtPendingManager;

DateTime? _day(String s) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  return m == null ? null : DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// null when a manager's approval is allowed, else what is wrong:
/// amount | authority | date_past | too_long | reason | remarks.
String? xtCheckManager({
  required double amount,
  required double authority,
  required String approvedOn,
  required String commitment,
  required String reason,
  required String remarks,
}) {
  if (!(amount > 0)) return 'amount';
  if (!(authority > 0) || amount > authority) return 'authority';
  final a = _day(approvedOn), c = _day(commitment);
  if (a == null || c == null || c.isBefore(a)) return 'date_past';
  if (c.difference(a).inDays > kExtensionManagerMaxDays) return 'too_long';
  if (reason.trim().isEmpty) return 'reason';
  if (remarks.trim().isEmpty) return 'remarks';
  return null;
}

/// null when the GM's approval is allowed: amount, a date from today, remarks.
String? xtCheckGm({required double amount, required String today, required String commitment, required String remarks}) {
  if (!(amount > 0)) return 'amount';
  final t = _day(today), c = _day(commitment);
  if (t == null || c == null || c.isBefore(t)) return 'date_past';
  if (remarks.trim().isEmpty) return 'remarks';
  return null;
}

const Map<String, String> kXtMessages = {
  'amount': 'Enter an additional credit amount above zero.',
  'authority': 'This amount is past your approval authority. Send it to the GM.',
  'date_past': 'The payment commitment date cannot be in the past.',
  'too_long': 'A manager may give at most 10 days from today.',
  'reason': 'Enter the reason for the extension.',
  'remarks': 'Enter your remarks.',
};

/// The status [action] by [actor] moves an extension to, or null when refused.
/// actor: rep | manager | other_manager | gm | approver (retry) | sap_job.
String? xtNextStatus(String action, String status, String actor) {
  switch (action) {
    case 'approve':
      if (status == kXtPendingManager && (actor == 'manager' || actor == 'gm')) return kXtSending;
      if (status == kXtPendingGm && actor == 'gm') return kXtSending;
      if (status == kXtOverdue && actor == 'gm') return kXtRenewed;
      return null;
    case 'reject':
      if (status == kXtPendingManager && actor == 'manager') return kXtRejected;
      if ([kXtPendingManager, kXtPendingGm, kXtOverdue].contains(status) && actor == 'gm') return kXtRejectedByGm;
      return null;
    case 'escalate':
      return status == kXtPendingManager && actor == 'manager' ? kXtPendingGm : null;
    case 'retry':
      return status == kXtPushFailed && actor == 'approver' ? kXtSending : null;
  }
  if (actor != 'sap_job') return null;
  if (action == 'sap_raised' && status == kXtSending) return kXtActive;
  if (action == 'sap_failed' && status == kXtSending) return kXtPushFailed;
  if (action == 'sap_paid' && status == kXtActive) return kXtPaid;
  if (action == 'sap_overdue' && status == kXtActive) return kXtOverdue;
  return null;
}

double _r2(double v) => (v * 100).roundToDouble() / 100;

/// Paid / Partially Paid / Not Paid, and what is still owed.
({String status, double remaining}) xtPaymentStatus(double amount, double paid) {
  final a = _r2(amount), p = _r2(paid);
  if (a > 0 && p >= a) return (status: 'Paid', remaining: 0);
  if (p > 0) return (status: 'Partially Paid', remaining: _r2(a - p));
  return (status: 'Not Paid', remaining: a);
}

/// paid | running | overdue.
String xtOutcome(double amount, double paid, String today, String commitment) {
  if (_r2(paid) >= _r2(amount)) return 'paid';
  return today.compareTo(commitment) > 0 ? 'overdue' : 'running';
}

String _s(Object? v) {
  final s = '${v ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

double _d(Object? v) => v is num ? v.toDouble() : double.tryParse(_s(v)) ?? 0;
bool _b(Object? v) => v == true || _s(v) == '1';

class CreditExtension {
  final Map<String, dynamic> raw;
  CreditExtension(Map m) : raw = m.cast<String, dynamic>();

  String get name => _s(raw['name']);
  String get status => _s(raw['status']);
  String get customer => _s(raw['customer']);
  String get customerName => _s(raw['customer_name']).isNotEmpty ? _s(raw['customer_name']) : customer;
  String get bpCode => _s(raw['bp_code']);
  String get salesOrder => _s(raw['sales_order']);
  String get salesPerson => _s(raw['sales_person']);
  String get requestedOn => _s(raw['requested_on']);
  String get requestReason => _s(raw['request_reason']);
  double get creditLimit => _d(raw['credit_limit_at_request']);
  double get outstanding => _d(raw['outstanding_at_request']);
  double get overdue => _d(raw['overdue_at_request']);
  double get orderAmount => _d(raw['order_amount']);
  double get excess => _d(raw['excess_amount']);
  double get amount => _d(raw['amount']);
  String get commitmentDate => _s(raw['commitment_date']);
  String get reason => _s(raw['reason']);
  String get remarks => _s(raw['remarks']);
  String get approvedOn => _s(raw['approved_on']);
  String get approverRole => _s(raw['approver_role']);
  String get rejectionRemarks => _s(raw['rejection_remarks']);
  String get escalationReason => _s(raw['escalation_reason']);
  String get sapReference => _s(raw['sap_reference']);
  String get sapError => _s(raw['sap_error']);
  double get paid => _d(raw['paid_amount']);
  double get remaining => _d(raw['remaining_amount']);
  String get paymentStatus => _s(raw['payment_status']).isEmpty ? 'Not Paid' : _s(raw['payment_status']);
  String get restoreStatus => _s(raw['restore_status']);
  double get originalLimit => _d(raw['original_limit']);
  double get raisedLimit => _d(raw['raised_limit']);
  bool get missed => _b(raw['missed']);
  String get actor => _s(raw['actor']);

  bool _may(String key, String action, String actorForRule) =>
      _b(raw[key]) && xtNextStatus(action, status, actorForRule) != null;
  bool get canApprove => _may('can_approve', 'approve', actor);
  bool get canReject => _may('can_reject', 'reject', actor);
  bool get canEscalate => _may('can_escalate', 'escalate', actor);
  bool get canRetry => _may('can_retry', 'retry', 'approver');
  bool get waitingOnMe => canApprove || canReject || canEscalate || canRetry;
}

class EligibleOrder {
  final Map<String, dynamic> raw;
  EligibleOrder(Map m) : raw = m.cast<String, dynamic>();
  String get salesOrder => _s(raw['sales_order']);
  String get customerName => _s(raw['customer_name']).isNotEmpty ? _s(raw['customer_name']) : _s(raw['customer']);
  String get bpCode => _s(raw['bp_code']);
  String get salesPerson => _s(raw['sales_person']);
  double get orderAmount => _d(raw['order_amount']);
  double get creditLimit => _d(raw['credit_limit']);
  double get outstanding => _d(raw['outstanding']);
  double get overdue => _d(raw['overdue']);
  double get excess => _d(raw['excess']);
  bool get hasRequest => _b(raw['has_request']);
}
