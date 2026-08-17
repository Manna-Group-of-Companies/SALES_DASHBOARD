// What each proforma line puts in each column.
//
// Paired with `client/src/domain/proforma.ts`. The phone renders a PDF and the
// dashboard renders HTML, but to a customer they are the same document, so both
// read `shared/fixtures/proforma_columns.json` in their tests.
//
// The columns are:
//
//     #  Description  Rolls  Belts  Cans  Qty  MRP  Amount
//
// Rolls, belts and cans are COLUMNS, not a second line under the item name.
// They are quantities; printing them as prose under the description meant a
// customer checking a delivery had to read a sentence to find a number.
//
// Every row must multiply out against a column the customer can see. Tread
// rubber and gum are billed by weight, so Qty(kg) x MRP = Amount. Solution is
// billed by the can, so Cans x MRP = Amount — which is why MRP carries its unit
// underneath rather than being assumed to be per kilogram.
//
// That last point fixed a real fault: this PDF printed solution as qty 90
// against a rate of 195 with an amount of 585 — three numbers that do not
// reconcile — because it assumed `custom_rate_per_kg` was per kilogram on every
// line. On solution it is per can.

const String kFieldCategory = 'custom_product_category';
const String kFieldRolls = 'custom_rolls';
const String kFieldBelts = 'custom_loose_belts';
const String kFieldWeight = 'custom_total_weight';
const String kFieldRatePerKg = 'custom_rate_per_kg';

double _num(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse('${v ?? ''}'.trim()) ?? 0;
}

/// A count for a packing column. Zero prints as nothing, never as "0".
String _count(dynamic v) {
  final n = _num(v);
  return n > 0 ? _tidy(n) : '';
}

String _tidy(double n) {
  final s = n.toStringAsFixed(3);
  return s.contains('.')
      ? s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
      : s;
}

class ProformaCells {
  final String rolls;
  final String belts;
  final String cans;

  /// The billed quantity with its unit, e.g. "56.4 kg" or "90 L".
  final String qty;
  final double mrp;

  /// Printed under the MRP so the row can be checked.
  final String mrpUnit;
  final double amount;

  const ProformaCells({
    required this.rolls,
    required this.belts,
    required this.cans,
    required this.qty,
    required this.mrp,
    required this.mrpUnit,
    required this.amount,
  });
}

/// The cells for one line.
///
/// A zero never prints in a packing column. An empty cell reads as "not
/// applicable"; a 0 reads as "none supplied", and on a packing column those are
/// different claims — hot rubber is not cut into belts at all, which is not the
/// same as a roll that yielded none.
ProformaCells proformaCells(Map<String, dynamic> line) {
  final category = '${line[kFieldCategory] ?? ''}';
  final weight = _num(line[kFieldWeight]);
  final perKg = _num(line[kFieldRatePerKg]);
  final qty = _num(line['qty']);
  final rate = _num(line['rate']);
  final amount = _num(line['amount']);

  // Solution is counted and billed by the can. The tin size — 10 L or 30 L — is
  // already in the item name, so the column carries the COUNT.
  //
  // `qty` is the can count, not `custom_cans`: on the live orders those two
  // disagree (qty 3 against custom_cans 2 on SAL-ORD-2026-00129) and `qty` is
  // the one the amount was computed from.
  if (category == 'VS') {
    return ProformaCells(
      rolls: '',
      belts: '',
      cans: _count(qty),
      qty: weight > 0 ? '${_tidy(weight)} L' : '',
      mrp: rate,
      mrpUnit: 'per can',
      amount: amount,
    );
  }

  // Everything else is billed by weight when a per-kilogram rate exists. An
  // order raised before that field did falls back to the stored qty and rate,
  // so an old proforma still reprints correctly rather than showing a nil line.
  final byWeight = perKg > 0 && weight > 0;

  return ProformaCells(
    // Gum has no packing count at all — it is sold by the kilogram.
    rolls: category == 'BG' ? '' : _count(line[kFieldRolls]),
    // Only precured is cut into belts.
    belts: category == 'PCTR' ? _count(line[kFieldBelts]) : '',
    cans: '',
    qty: byWeight ? '${_tidy(weight)} kg' : _tidy(qty),
    mrp: byWeight ? perKg : rate,
    mrpUnit: byWeight ? 'per kg' : '',
    amount: amount,
  );
}

/// The column the row multiplies out on, for the test that proves it does.
String reconcilesOn(Map<String, dynamic> line) {
  if ('${line[kFieldCategory] ?? ''}' == 'VS') return 'cans';
  return _num(line[kFieldRatePerKg]) > 0 && _num(line[kFieldWeight]) > 0
      ? 'weight'
      : 'qty';
}
