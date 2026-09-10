// Turning SAP's kilos into rolls and belts.
//
// SAP holds finished-goods stock as a total weight. A rep orders rolls and
// belts. The conversion needs two per-item numbers — weight-per-roll and
// belts-per-roll — and both apps must convert identically, or the same shelf
// reads differently on a phone and on a dashboard.
//
// THE TRAP THIS FILE EXISTS FOR
//
// Frappe stores Int and Float as `NOT NULL DEFAULT 0`. There is no null. An
// item nobody has entered weights for reads exactly like an item that
// genuinely weighs nothing per roll. Conflating those two is expensive both
// ways:
//
//   - dividing kilos by a zero roll-weight gives infinity, and an infinite
//     quantity on an order screen is an order for an unbounded amount;
//   - rendering the result as 0 tells a rep "out of stock" when the truth is
//     "nobody has told us how to convert this".
//
// So the answer is a third thing: unknown. Every caller has to handle it,
// which is the point — it cannot be quietly rounded into a number.
//
// WHY IT MATTERS NOW
//
// 288 items hold about 37,260 kg in SAP with no belt data. They read 0 qty in
// ERPNext today only because the FG import of 10 September 2026 withheld their
// stock. On the next scheduled sync they become eligible to receive it.
//
// Pinned by `shared/fixtures/stock_from_kg.json`, which the dashboard's suite
// reads too. The TypeScript twin is `client/src/domain/stockFromKg.ts`.

/// Why a conversion could not be made, so a screen can say which.
enum StockUnknownReason { noWeightPerRoll, noBeltsPerRoll, notWeighed }

/// Kilos expressed as rolls and belts, or an honest refusal to guess.
class StockFromKg {
  final bool known;

  /// Always real, and always worth showing even when the rest is unknown.
  final double kg;

  /// Whole rolls. A rep cannot sell 0.885 of a roll.
  final int? rolls;

  /// Belts left over after the whole rolls — 0..beltsPerRoll-1.
  final int? looseBelts;

  /// Every whole belt the kilos can be cut into.
  final int? totalBelts;
  final double? weightPerBelt;
  final StockUnknownReason? reason;

  const StockFromKg._({
    required this.known,
    required this.kg,
    this.rolls,
    this.looseBelts,
    this.totalBelts,
    this.weightPerBelt,
    this.reason,
  });
}

double _round3(double v) => (v * 1000).round() / 1000;

/// Whole units, always rounding DOWN.
///
/// 149.2 kg at 6.4 kg/belt is 23.3 belts: 23 sellable belts and a 2 kg offcut.
/// Rounding to 24 promises a belt that cannot be cut, and an over-promise here
/// is a rep in a shop unable to deliver.
///
/// The epsilon is not decoration. 34.0 / 1.7 evaluates to 19.999999999999996,
/// and flooring that loses a whole roll to binary floating point.
int _wholeUnits(double v) => (v + 1e-9).floor();

/// A stored number Frappe may have defaulted to 0.
///
/// Zero, negative and non-finite all mean "no usable value". Negative is not
/// merely invalid: propagated, it yields a negative roll count that looks like
/// a number and is not one.
double? _usable(num? v) {
  final d = (v ?? 0).toDouble();
  return d.isFinite && d > 0 ? d : null;
}

/// Weight of one belt.
///
/// The site's invariant is `weightPerBelt * beltsPerRoll = weightPerRoll`, and
/// `custom_avg_weight_per_roll` holds the BELT weight despite its name. The FG
/// import left it at 0 on all 153 items it gave belt data to, so it is derived
/// when missing rather than believed.
///
/// A stored value wins: somebody typed it, and this only fills a hole.
double? weightPerBelt({
  num? storedWeightPerBelt,
  num? weightPerRoll,
  num? beltsPerRoll,
}) {
  final stored = _usable(storedWeightPerBelt);
  if (stored != null) return stored;
  final roll = _usable(weightPerRoll);
  final belts = _usable(beltsPerRoll);
  if (roll == null || belts == null) return null;
  return _round3(roll / belts);
}

/// Kilos on the shelf, as rolls and belts.
///
/// [isWeighed] is false for anything sold in Nos or Litre — a tin of solution
/// has no rolls, and the question should not be asked of it rather than
/// answered with a zero.
StockFromKg stockFromKg({
  required num kg,
  num? weightPerRoll,
  num? beltsPerRoll,
  num? storedWeightPerBelt,
  bool isWeighed = true,
}) {
  final k = kg.toDouble().isFinite ? kg.toDouble() : 0.0;

  if (!isWeighed) {
    return StockFromKg._(
        known: false, kg: k, reason: StockUnknownReason.notWeighed);
  }

  final roll = _usable(weightPerRoll);
  final belts = _usable(beltsPerRoll);

  // Both are required. A roll count with no belt count is half an answer, and
  // half an answer on an order screen gets treated as a whole one.
  if (roll == null) {
    return StockFromKg._(
        known: false, kg: k, reason: StockUnknownReason.noWeightPerRoll);
  }
  if (belts == null) {
    return StockFromKg._(
        known: false, kg: k, reason: StockUnknownReason.noBeltsPerRoll);
  }

  final perBelt = roll / belts;
  // Whole belts first, then split. Computing rolls first and multiplying back
  // compounds the rounding error by belts-per-roll, which reaches 20 here.
  final totalBelts = _wholeUnits(k / perBelt);
  final perRoll = belts.round();
  return StockFromKg._(
    known: true,
    kg: k,
    rolls: totalBelts ~/ perRoll,
    looseBelts: totalBelts % perRoll,
    totalBelts: totalBelts,
    weightPerBelt: _round3(perBelt),
  );
}

/// What a screen shows when the conversion could not be made.
String unknownStockLabel(StockUnknownReason r) {
  switch (r) {
    case StockUnknownReason.notWeighed:
      return 'Not sold by weight';
    case StockUnknownReason.noBeltsPerRoll:
      return 'Belts per roll not set';
    case StockUnknownReason.noWeightPerRoll:
      return 'Weights not set';
  }
}
