// Credit-period requests (16 Nov 2026, the user): a customer asks, through
// their rep, for a different credit period - the SAP payment term on their
// Manna Treads account. Up to 30 days the rep's manager approves it and
// pushes it to SAP; 31 to 40 days the manager may only escalate it (or reject
// it) and the GM approves and pushes it. Over 40 days is never asked for here.
//
// Read and written only through the manna_credit_period_request Server
// Script (app/server/credit_period_request.py), which enforces all of it and
// hands each row can_* flags. The phone offers a button only when the server
// says so AND this copy of the rule agrees, so a stale row never offers what
// the server would refuse. shared/fixtures/credit_period_request.json pins
// both; the dashboard's copy is client/src/domain/creditPeriodRequest.ts.

const int kCreditPeriodManagerMaxDays = 30;
const int kCreditPeriodGmMaxDays = 40;

const String kCprWithManager = 'With Manager';
const String kCprWithGm = 'With GM';
const String kCprApproved = 'Approved';
const String kCprSending = 'Sending to SAP';
const String kCprInSap = 'In SAP';
const String kCprRejected = 'Rejected';

const List<String> kCprStatuses = [
  kCprWithManager, kCprWithGm, kCprApproved, kCprSending, kCprInSap, kCprRejected,
];

/// What a status is called. An unknown one reads as still with the manager;
/// [cprNextStatus] refuses every action on it, so it offers nobody anything.
String cprLabel(String status) =>
    kCprStatuses.contains(status) ? status : kCprWithManager;

/// Who decides [days]: 'manager', 'gm', or 'refused' (over 40, or negative).
String cprBand(int days) {
  if (days < 0 || days > kCreditPeriodGmMaxDays) return 'refused';
  return days > kCreditPeriodManagerMaxDays ? 'gm' : 'manager';
}

/// The status [action] by [actor] moves a request to, or null when refused.
/// actor: rep | manager (the rep's team manager) | other_manager | gm | sap_sync.
String? cprNextStatus(String action, String status, int days, String actor) {
  final band = cprBand(days);
  if (band == 'refused') return null;
  final gmBand = band == 'gm';
  switch (action) {
    case 'approve':
    case 'reject':
      final to = action == 'approve' ? kCprApproved : kCprRejected;
      if (status == kCprWithManager) {
        if (actor == 'gm') return to;
        if (actor == 'manager' && (action == 'reject' || !gmBand)) return to;
      }
      if (status == kCprWithGm && actor == 'gm') return to;
      return null;
    case 'escalate':
      return status == kCprWithManager && actor == 'manager' && gmBand ? kCprWithGm : null;
    case 'push':
      return status == kCprApproved && (actor == 'gm' || (actor == 'manager' && !gmBand))
          ? kCprSending
          : null;
    case 'sap_done':
    case 'sap_failed':
      if (status == kCprSending && actor == 'sap_sync') {
        return action == 'sap_done' ? kCprInSap : kCprApproved;
      }
      return null;
  }
  return null;
}

/// A new request's status, or null when [days] may not be asked for.
String? cprSubmitStatus(int days) => cprBand(days) == 'refused' ? null : kCprWithManager;

String _s(Object? v) {
  final s = '${v ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

int _i(Object? v) => v is num ? v.toInt() : int.tryParse(_s(v)) ?? 0;
bool _b(Object? v) => v == true || _s(v) == '1';

/// One SAP payment term, as the credit sync copies them to ERPNext.
class SapPaymentTerm {
  final int code;
  final String name;
  final int days;
  const SapPaymentTerm(this.code, this.name, this.days);

  factory SapPaymentTerm.fromJson(Map m) =>
      SapPaymentTerm(_s(m['code']).isEmpty ? -1 : _i(m['code']), _s(m['name']), _i(m['days']));

  String get label => days == 0 ? name : '$name · $days days';
}

/// The terms a rep may ask for: 40 days or fewer, never '- Cash Basic -'
/// (code -1, SAP's 'no term'), never the one the customer is on. Shortest first.
List<SapPaymentTerm> cprOfferedTerms(List<SapPaymentTerm> terms, int? currentCode) {
  final out = terms
      .where((t) => t.code != -1 && t.days >= 0 && t.days <= kCreditPeriodGmMaxDays && t.code != currentCode)
      .toList()
    ..sort((a, b) {
      final d = a.days.compareTo(b.days);
      return d != 0 ? d : a.name.compareTo(b.name);
    });
  return out;
}

class CreditPeriodRequest {
  final String name;
  final String status;
  final String customer;
  final String customerName;
  final String currentTerm;
  final int currentDays;
  final String requestedTerm;
  final int requestedDays;
  final String reason;
  final String salesPerson;
  final String requestedOn;
  final String managerNote;
  final String decisionNote;
  final String approverRole;
  final String sapError;
  final String sapPushedOn;
  /// What this login is to the request, as the server sees it.
  final String actor;
  final bool serverCanApprove;
  final bool serverCanReject;
  final bool serverCanEscalate;
  final bool serverCanPush;

  const CreditPeriodRequest({
    required this.name,
    required this.status,
    required this.customer,
    required this.customerName,
    required this.currentTerm,
    required this.currentDays,
    required this.requestedTerm,
    required this.requestedDays,
    this.reason = '',
    this.salesPerson = '',
    this.requestedOn = '',
    this.managerNote = '',
    this.decisionNote = '',
    this.approverRole = '',
    this.sapError = '',
    this.sapPushedOn = '',
    this.actor = '',
    this.serverCanApprove = false,
    this.serverCanReject = false,
    this.serverCanEscalate = false,
    this.serverCanPush = false,
  });

  factory CreditPeriodRequest.fromJson(Map m) => CreditPeriodRequest(
        name: _s(m['name']),
        status: _s(m['status']),
        customer: _s(m['customer']),
        customerName: _s(m['customer_name']).isNotEmpty ? _s(m['customer_name']) : _s(m['customer']),
        currentTerm: _s(m['current_term']),
        currentDays: _i(m['current_term_days']),
        requestedTerm: _s(m['requested_term']),
        requestedDays: _i(m['requested_days']),
        reason: _s(m['reason']),
        salesPerson: _s(m['sales_person']),
        requestedOn: _s(m['requested_on']),
        managerNote: _s(m['manager_note']),
        decisionNote: _s(m['decision_note']),
        approverRole: _s(m['approver_role']),
        sapError: _s(m['sap_error']),
        sapPushedOn: _s(m['sap_pushed_on']),
        actor: _s(m['actor']),
        serverCanApprove: _b(m['can_approve']),
        serverCanReject: _b(m['can_reject']),
        serverCanEscalate: _b(m['can_escalate']),
        serverCanPush: _b(m['can_push']),
      );

  String get label => cprLabel(status);
  bool get needsGm => cprBand(requestedDays) == 'gm';

  bool _may(bool server, String action) =>
      server && cprNextStatus(action, status, requestedDays, actor) != null;
  bool get canApprove => _may(serverCanApprove, 'approve');
  bool get canReject => _may(serverCanReject, 'reject');
  bool get canEscalate => _may(serverCanEscalate, 'escalate');
  bool get canPush => _may(serverCanPush, 'push');

  /// Waiting on this login: something to decide or to push.
  bool get waitingOnMe => canApprove || canReject || canEscalate || canPush;
}
