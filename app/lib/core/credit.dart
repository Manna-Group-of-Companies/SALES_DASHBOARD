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

/// Every field the aging display needs, for the `fields` list of a customer
/// query. One list, so a screen cannot quietly fetch three of the four.
const List<String> kOutstandingFields = [
  kFieldOutstandingTotal,
  kFieldCreditLimit,
  kFieldOutstanding0_30,
  kFieldOutstanding30_60,
  kFieldOutstanding60_90,
  kFieldOutstanding90Plus,
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
bool overCreditLimit(Map<String, dynamic> customer, double orderTotal) {
  final a = agingOf(customer);
  if (!(a.creditLimit > 0)) return false;
  return a.total + orderTotal > a.creditLimit;
}

const String kAgingNotSynced =
    'SAP has not sent an age breakdown for this customer yet. '
    'The total is still the total.';

const String kAgingMismatch =
    'The age breakdown does not add up to the outstanding balance. The balance '
    'is what the credit limit is checked against; the breakdown needs '
    're-syncing from SAP.';
