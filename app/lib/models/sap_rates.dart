// Manna Treads' SAP rates for one customer or lead, as the order screen shows
// them beside the rate box (the user, 25 Sep 2026: "the sales user would see
// the rates of items").
//
// Worked out on the server by the ERPNext Server Script `manna_customer_rates`,
// from the copy of Manna Treads' SAP the office server keeps in ERPNext
// (`SAP Pricing Control`): the dealer's own special price when SAP holds one
// that is switched on, otherwise Price List 01 ("selling price"). The rule lives
// there only, so the phone and the dashboard cannot price an item differently.
// Per kg, and GST-inclusive exactly as SAP holds it — the same unit and basis
// as the "Rate per kg" box, so nothing is converted here.
//
// Where SAP has a rate it is the price, and the rep cannot change it (the user,
// 26 Sep 2026; on 25 Sep it was a hint with a "Use" button). The order screen
// fills it in and locks the box. For a LEAD it is always the list price (the
// user, 25 Sep 2026): a lower one goes through Higher Management and becomes a
// special price once the lead is a customer; the script says so with
// `list_only`. An item for which SAP has no rate is typed by hand as before.

import 'package:manna_field_sales/models/min_stock.dart' show trimQty;

class SapRate {
  /// Rupees per kg, GST-inclusive, as SAP holds it.
  final double rate;

  /// `special` — this dealer's own price in Manna Treads' SAP; `list` — Price
  /// List 01.
  final String source;

  /// Price List 01's price for the item, when known.
  final double? list;

  const SapRate({required this.rate, required this.source, this.list});

  bool get isDealerPrice => source == 'special';

  /// The line under the rate box.
  String hint(String unit) {
    final r = 'Rs ${trimQty(rate)}/$unit';
    if (!isDealerPrice) return 'Manna Treads list rate $r';
    final l = list;
    return (l != null && l > 0 && (l - rate).abs() > 0.004)
        ? "Manna Treads rate $r — this dealer's price (list Rs ${trimQty(l)})"
        : "Manna Treads rate $r — this dealer's price";
  }

  /// The line under a customer's locked rate box.
  String fixedHint(String unit) =>
      '${hint(unit)}. Set in SAP — ask the office to change it.';

  /// The line under a lead order's locked rate box.
  String leadHint(String unit) =>
      'Lead order: Manna Treads list rate Rs ${trimQty(rate)}/$unit. '
      'A lower price goes through Higher Management once the lead is a customer.';

  /// One entry of the script's `rates`, or null when it is not a usable price.
  static SapRate? fromJson(dynamic v) {
    if (v is! Map) return null;
    final rate = _num(v['rate']);
    if (rate == null || rate <= 0) return null;
    return SapRate(rate: rate, source: '${v['source'] ?? 'list'}', list: _num(v['list']));
  }
}

class SapRates {
  final String customer;

  /// The lead asked about, when it was a lead; empty for a customer.
  final String lead;

  /// The customer's Manna Treads SAP code (`Customer.custom_bp_code`), or empty.
  final String bpCode;

  /// When the office server last read SAP, as it wrote it.
  final String syncedAt;

  /// Why some or all rates are missing, in words for the rep; empty otherwise.
  final String note;

  /// True when these are the only prices the order may carry — a lead's list
  /// prices. The order screen fills them in and locks the box.
  final bool listOnly;

  /// Keyed by ERPNext item code.
  final Map<String, SapRate> rates;

  const SapRates({
    this.customer = '',
    this.lead = '',
    this.bpCode = '',
    this.syncedAt = '',
    this.note = '',
    this.listOnly = false,
    this.rates = const {},
  });

  /// No rates: not a Manna Treads customer, no signal, or nothing priced yet.
  static const SapRates none = SapRates();

  bool get isEmpty => rates.isEmpty;

  SapRate? operator [](String itemCode) => rates[itemCode];

  /// The script's `message`. Anything odd in it is dropped, never thrown.
  factory SapRates.fromMessage(Map<String, dynamic> m) {
    final raw = m['rates'];
    final rates = <String, SapRate>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        final r = SapRate.fromJson(v);
        if (r != null) rates['$k'] = r;
      });
    }
    final lo = m['list_only'];
    return SapRates(
      customer: '${m['customer'] ?? ''}',
      lead: '${m['lead'] ?? ''}',
      bpCode: '${m['bp_code'] ?? ''}',
      syncedAt: '${m['synced_at'] ?? ''}',
      note: '${m['note'] ?? ''}',
      listOnly: lo == true || lo == 1 || '$lo' == '1',
      rates: rates,
    );
  }
}

double? _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
