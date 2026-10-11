// What a customer owes, and how old it is.
//
// Paired with `client/src/domain/credit.ts`. Both read
// `shared/fixtures/credit.json` in their tests, so a rule that changes on one
// side turns the other side red. See `shared/README.md`.
//
// SAP ages its receivables into four buckets and sends all four, plus a single
// credit limit. ERPNext gained four Currency fields on `Customer` on
// 13 August 2026 to hold them:
//
//   custom_outstanding_0_30      0-30 days
//   custom_outstanding_30_60     30-60 days
//   custom_outstanding_60_90     60-90 days
//   custom_outstanding_90_plus   over 90 days
//
// `custom_outstanding_balance` stays, and stays the total. That is not
// redundancy, it is the point:
//
//   - it is the figure the credit limit has always been checked against, and
//     every one of those checks keeps working untouched;
//   - it is what SAP itself calls the balance, so recomputing it here would let
//     a rounding difference in our sum move a figure a rep quoted to a customer;
//   - the buckets are zero on all 620 customers until the SAP job is changed to
//     send them, and deriving the total from them would read every customer as
//     owing nothing in the meantime.
//
// The credit limit is deliberately not split. SAP gives one number.

import 'package:manna_field_sales/core/expenses.dart' show expenseNum;

const String kFieldOutstandingTotal = 'custom_outstanding_balance';
const String kFieldCreditLimit = 'custom_credit_limit';
const String kFieldOutstanding0_30 = 'custom_outstanding_0_30';
const String kFieldOutstanding30_60 = 'custom_outstanding_30_60';
const String kFieldOutstanding60_90 = 'custom_outstanding_60_90';
const String kFieldOutstanding90Plus = 'custom_outstanding_90_plus';

// Payment terms, added 11 Oct 2026. Written by the SAP credit sync, which
// decides what "overdue past the terms" means once, for both apps: the open
// amount on invoices whose SAP due date has passed, capped at the SAP balance,
// and 0 for a customer with no term set. See credit.json `fields`.
const String kFieldOverduePastTerms = 'custom_overdue_past_terms';
const String kFieldPaymentTerms = 'custom_payment_terms';
const String kFieldOverdueDays = 'custom_overdue_days';

/// Every field the aging display and the escalation need, for the `fields`
/// list of a customer query. One list, so a screen cannot quietly fetch three
/// of the four.
const List<String> kOutstandingFields = [
  kFieldOutstandingTotal,
  kFieldCreditLimit,
  kFieldOutstanding0_30,
  kFieldOutstanding30_60,
  kFieldOutstanding60_90,
  kFieldOutstanding90Plus,
  kFieldOverduePastTerms,
  kFieldPaymentTerms,
  kFieldOverdueDays,
];

/// How far the stored total may sit from the sum of the buckets before it is
/// called a fault. SAP rounds; a rupee is not a broken sync.
const double kAgingTolerance = 1;

double _num(dynamic v) => expenseNum(v);

double _round2(double v) => double.parse(v.toStringAsFixed(2));

/// One customer's outstanding, split the way SAP splits it.
class Aging {
  /// 0-30 days.
  final double current;

  /// 30-60 days.
  final double d30;

  /// 60-90 days.
  final double d60;

  /// Over 90 days.
  final double d90;

  /// What the buckets add up to.
  final double sum;

  /// What the credit decision is made on.
  final double total;

  final double creditLimit;

  /// Whether SAP has actually sent a breakdown for this customer.
  ///
  /// False must render as "not synced", never as four zeros — four zeros beside
  /// a real total reads as "nothing is overdue", which is a statement nobody has
  /// the data to make.
  final bool bucketsKnown;

  /// The stored total and the buckets disagree by more than rounding. Surfaced
  /// rather than smoothed over: it means the SAP job wrote one and not the
  /// other, and quietly picking a winner would hide a broken sync for months.
  final bool mismatch;

  const Aging({
    required this.current,
    required this.d30,
    required this.d60,
    required this.d90,
    required this.sum,
    required this.total,
    required this.creditLimit,
    required this.bucketsKnown,
    required this.mismatch,
  });

  /// What is older than ninety days.
  double get overdue => d90;

  bool get hasOverdue => d90 > 0;

  /// The four boxes in the order they are shown, oldest last.
  List<AgingBucket> get buckets => [
        AgingBucket('0-30 days', current, false),
        AgingBucket('30-60 days', d30, false),
        AgingBucket('60-90 days', d60, false),
        // Only the oldest is marked. If every box shouted, none would.
        AgingBucket('Over 90 days', d90, d90 > 0),
      ];
}

class AgingBucket {
  final String label;
  final double amount;
  final bool overdue;
  const AgingBucket(this.label, this.amount, this.overdue);
}

Aging agingOf(Map<String, dynamic> customer) {
  final current = _num(customer[kFieldOutstanding0_30]);
  final d30 = _num(customer[kFieldOutstanding30_60]);
  final d60 = _num(customer[kFieldOutstanding60_90]);
  final d90 = _num(customer[kFieldOutstanding90Plus]);
  final stored = _num(customer[kFieldOutstandingTotal]);

  // Any bucket, including a negative one: a credit note in the 30-60 column is
  // still a breakdown that arrived.
  final known = current != 0 || d30 != 0 || d60 != 0 || d90 != 0;
  final sum = _round2(current + d30 + d60 + d90);

  // The stored total wins whenever there is one. It falls back to the sum only
  // when SAP wrote buckets and left the total at zero — showing zero there
  // would tell a rep a customer owing 169,900 was clear.
  final total = stored != 0
      ? stored
      : known
          ? sum
          : 0.0;

  return Aging(
    current: current,
    d30: d30,
    d60: d60,
    d90: d90,
    sum: sum,
    total: total,
    creditLimit: _num(customer[kFieldCreditLimit]),
    bucketsKnown: known,
    mismatch: known && stored != 0 && (stored - sum).abs() > kAgingTolerance,
  );
}

/// What is older than ninety days. Zero when nothing is, or nothing is known.
double overdueAmount(Map<String, dynamic> customer) =>
    _num(customer[kFieldOutstanding90Plus]);

bool hasOverdue(Map<String, dynamic> customer) => overdueAmount(customer) > 0;

/// Whether an order takes this customer past their credit limit.
///
/// Unchanged by the aging split, deliberately. The four buckets are shown, not
/// enforced: old debt does not escalate on its own. Adding that rule silently
/// would start stopping orders the day it shipped, on customers nobody had
/// warned — so it is a decision to be taken, not a side effect of displaying a
/// number. Recorded 13 Aug 2026 as "information only, for now".
///
/// No limit set is not an unlimited limit, but it is not an escalation either.
/// Many of the 620 customers have none, and escalating all of them would bury
/// the general manager and teach everyone to wave the queue through.
///
/// Since 11 Oct 2026 this is only the LIMIT half of the escalation. Whether an
/// order goes to the GM is [creditEscalates], which adds the payment-terms rule.
bool overCreditLimit(Map<String, dynamic> customer, double orderTotal) {
  final a = agingOf(customer);
  if (!(a.creditLimit > 0)) return false;
  return a.total + orderTotal > a.creditLimit;
}

/// Below this, money left on an invoice is rounding, not an overdue customer.
const double kOverdueTolerance = 1;

/// What is overdue past the customer's payment terms, as the SAP sync wrote
/// it. Zero when nothing is, when no term is set, or when the sync has not
/// reached this customer yet — never an error.
double overduePastTerms(Map<String, dynamic> customer) =>
    _num(customer[kFieldOverduePastTerms]);

/// The SAP payment term's name, or '' when none was synced.
String paymentTermsOf(Map<String, dynamic> customer) {
  final s = '${customer[kFieldPaymentTerms] ?? ''}'.trim();
  return s == 'null' ? '' : s;
}

/// How many days the oldest overdue invoice is past its due date.
int overdueDaysOf(Map<String, dynamic> customer) {
  final d = _num(customer[kFieldOverdueDays]).round();
  return d < 0 ? 0 : d;
}

/// Why an order needs the GM. Both may hold at once.
class CreditEscalation {
  /// The order takes the customer past a credit limit that is set.
  final bool overLimit;

  /// Invoices are overdue past the customer's payment terms.
  final bool pastTerms;

  const CreditEscalation({required this.overLimit, required this.pastTerms});
}

CreditEscalation escalationOf(Map<String, dynamic> customer, double orderTotal) =>
    CreditEscalation(
      overLimit: overCreditLimit(customer, orderTotal),
      pastTerms: overduePastTerms(customer) > kOverdueTolerance,
    );

/// Whether an order needs the general manager's credit approval.
///
/// Over the credit limit (unchanged), or overdue past the payment terms — the
/// second rule, asked for on 11 Oct 2026. The terms rule needs no limit: a
/// customer with none who is overdue past their terms still escalates.
/// Everything that used to ask [overCreditLimit] whether an order escalates —
/// who may approve, the rep's commitment, the held proforma — asks this.
bool creditEscalates(Map<String, dynamic> customer, double orderTotal) {
  final e = escalationOf(customer, orderTotal);
  return e.overLimit || e.pastTerms;
}

/// "Rs 25,000 overdue past their Net-30 terms (oldest 12 days late)".
String pastTermsPhrase(Map<String, dynamic> customer) {
  final amount = overduePastTerms(customer).round();
  final terms = paymentTermsOf(customer);
  final days = overdueDaysOf(customer);
  final against = terms.isEmpty ? 'their payment terms' : 'their $terms terms';
  final late = days > 0 ? ' (oldest $days day${days == 1 ? '' : 's'} late)' : '';
  return 'Rs $amount overdue past $against$late';
}

/// One sentence: why this order is with the GM. Empty when it is not.
String escalationReason(Map<String, dynamic> customer, double orderTotal) {
  final e = escalationOf(customer, orderTotal);
  const limit = 'This order takes the customer past their credit limit';
  final terms = 'has ${pastTermsPhrase(customer)}';
  if (e.overLimit && e.pastTerms) return '$limit, and the customer $terms.';
  if (e.overLimit) return '$limit.';
  if (e.pastTerms) return 'The customer $terms.';
  return '';
}

/// What a bucket reads when SAP has sent no breakdown at all.
///
/// A dash, not a zero. Zero is a statement — "they owe nothing in this band" —
/// and it is one nobody has the data to make until the sync has run. The
/// buckets are still drawn with their labels, so a reader sees the shape of
/// what is missing rather than an empty space. Asked for 21 August 2026.
const String kAgingNoData = '—';

const String kAgingNotSynced =
    'SAP has not sent an age breakdown for this customer yet. '
    'The total is still the total.';

const String kAgingMismatch =
    'The age breakdown does not add up to the outstanding balance. The balance '
    'is what the credit limit is checked against; the breakdown needs '
    're-syncing from SAP.';
