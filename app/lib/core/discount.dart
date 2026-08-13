// Discounts a sales manager gives at approval.
//
// The rep quotes a rate. The sales manager, reviewing the order, may knock a
// percentage off any line. Both numbers have to survive: the customer is
// invoiced the discounted rate, but the business needs to see what was given
// away, so the original rate is kept rather than overwritten.
//
// Where the two numbers live differs by order type, and this file is the only
// place that knows it:
//
//   Sales Order Item   `price_list_rate` and `discount_percentage` — the
//                      standard ERPNext fields, so Desk, the print formats and
//                      the web dashboards read the discount without being
//                      taught about it.
//   Lead Order Item    `custom_price_list_rate` and `custom_discount_percentage`
//                      — our own child table, which has no standard pricing
//                      fields at all.
//
// In both cases `rate` is the net rate the customer pays and `amount` is
// qty x rate. Nothing on this site recomputes them: Server Scripts are not
// available, and `Lead Order Item` is a custom table nothing calculates. So
// every figure here is written explicitly and must be internally consistent
// before it is sent.

import 'package:manna_field_sales/core/expenses.dart' show expenseNum;

/// The most a sales manager may take off a line.
///
/// Not a costing limit — nobody has given one. It is a guard against a typo:
/// 100 in a percentage box is an order given away, and a fat finger on the
/// keypad should not be able to do that silently. A genuine giveaway above
/// this is a conversation with the GM, not a number typed at a counter.
const double kMaxDiscountPercent = 50;

/// A number as Frappe might return it — num, numeric string, or null.
double _num(dynamic v) => expenseNum(v);

/// The discount on a line, in percent. Zero when there is none.
double discountPercentOf(Map<String, dynamic> item) {
  final standard = _num(item['discount_percentage']);
  if (standard > 0) return standard;
  return _num(item['custom_discount_percentage']);
}

/// The rate before any discount.
///
/// Falls back to the net rate when nothing was discounted, so an undiscounted
/// line reports the same number both ways rather than zero. Orders taken
/// before discounts existed have no pre-discount rate stored at all, and must
/// read as full price rather than as free.
double rateBeforeDiscount(Map<String, dynamic> item) {
  final standard = _num(item['price_list_rate']);
  if (standard > 0) return standard;
  final custom = _num(item['custom_price_list_rate']);
  if (custom > 0) return custom;
  return _num(item['rate']);
}

/// The rate the customer actually pays.
double rateAfterDiscount(Map<String, dynamic> item) => _num(item['rate']);

/// Money is held to paise. Rounding at every step, rather than once at the
/// end, is what makes the lines on screen add up to the total underneath them
/// — a manager who cannot reconcile the two by eye will not trust either.
double roundMoney(double v) => double.parse(v.toStringAsFixed(2));

/// What a rate becomes after [percent] is taken off it.
double discountedRate(double base, double percent) =>
    roundMoney(base * (1 - percent / 100));

/// The percentage [net] represents off [base].
///
/// The inverse of [discountedRate], used when somebody sets a rate directly
/// and the stored percentage would otherwise contradict it. Returns 0 rather
/// than a negative when the rate went *up*: a rate above the original is a
/// price rise, not a negative discount, and showing "-8% discount" would read
/// as a discount rather than as its opposite.
double percentOff(double base, double net) {
  if (base <= 0 || net >= base) return 0;
  return double.parse((((base - net) / base) * 100).toStringAsFixed(2));
}

/// What a line is worth at full price.
double lineBeforeDiscount(Map<String, dynamic> item) =>
    roundMoney(_num(item['qty']) * rateBeforeDiscount(item));

/// What a line is worth after the discount.
///
/// Prefers the stored `amount`, because that is the figure ERPNext and the
/// proforma print. Falls back to qty x rate when it is missing or zero —
/// lead orders written before the app sent `amount` have it as zero, and a
/// manager must never be shown a nil order against rates a rep entered
/// correctly.
double lineAfterDiscount(Map<String, dynamic> item) {
  final stored = _num(item['amount']);
  if (stored > 0) return roundMoney(stored);
  return roundMoney(_num(item['qty']) * rateAfterDiscount(item));
}

/// True when this line has had something taken off it.
bool isDiscounted(Map<String, dynamic> item) => discountPercentOf(item) > 0;

/// An order's totals, before and after the discounts on its lines.
class DiscountTotals {
  /// What the order would be worth at the rates the rep quoted.
  final double beforeDiscount;

  /// What it is worth at the rates the customer will be invoiced.
  final double afterDiscount;

  /// How many lines carry a discount.
  final int discountedLines;

  const DiscountTotals({
    required this.beforeDiscount,
    required this.afterDiscount,
    required this.discountedLines,
  });

  /// What was given away. Derived rather than accumulated so it can never
  /// disagree with the two totals a manager is reading it between.
  double get discount => roundMoney(beforeDiscount - afterDiscount);

  /// The discount as a share of the full price, for the one-line summary.
  double get discountPercent => percentOff(beforeDiscount, afterDiscount);

  bool get hasDiscount => discountedLines > 0 && discount > 0;
}

/// Totals an order's lines both ways.
DiscountTotals discountTotals(Iterable<Map<String, dynamic>> items) {
  var before = 0.0, after = 0.0, n = 0;
  for (final it in items) {
    before += lineBeforeDiscount(it);
    after += lineAfterDiscount(it);
    if (isDiscounted(it)) n++;
  }
  return DiscountTotals(
    beforeDiscount: roundMoney(before),
    afterDiscount: roundMoney(after),
    discountedLines: n,
  );
}

/// Why a discount cannot be given, or null when it can.
///
/// Returned as a message rather than a bool because every one of these is
/// something the manager has to be told; a disabled button that does not say
/// why is the same bug as no check at all.
String? discountRefusal(double percent) {
  if (percent.isNaN || percent < 0) return 'Enter a discount between 0 and 100.';
  if (percent > 100) return 'A discount cannot be more than 100%.';
  if (percent > kMaxDiscountPercent) {
    return 'The most that can be given here is '
        '${kMaxDiscountPercent.toStringAsFixed(0)}%. Anything more has to go '
        'to the general manager.';
  }
  return null;
}

/// The fields to write to put [percent] on a line.
///
/// Every figure the discount touches is written together — the pre-discount
/// rate, the percentage, the net rate and the amount. They are computed from
/// one another here so that whatever else reads them later finds them
/// agreeing. Nothing on the server will fix them up if they do not.
///
/// [isLead] picks the spelling of the two fields the two order types disagree
/// about; see the note at the top of this file.
Map<String, dynamic> discountFields({
  required Map<String, dynamic> item,
  required double percent,
  required bool isLead,
}) {
  // Read the original before anything is overwritten. A line discounted twice
  // must discount off the rep's rate both times, never off the already
  // discounted one — otherwise 10% given twice quietly becomes 19%.
  final base = rateBeforeDiscount(item);
  final net = discountedRate(base, percent);
  final qty = _num(item['qty']);

  return {
    if (isLead) ...{
      'custom_price_list_rate': base,
      'custom_discount_percentage': percent,
    } else ...{
      'price_list_rate': base,
      'discount_percentage': percent,
      // ERPNext derives rate from price_list_rate and discount_amount when it
      // recalculates. Sent so its arithmetic lands on the same net rate as
      // ours rather than a rounding step away from it.
      'discount_amount': roundMoney(base - net),
    },
    'rate': net,
    'amount': roundMoney(qty * net),
  };
}
