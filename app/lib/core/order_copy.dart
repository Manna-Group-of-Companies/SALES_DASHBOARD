// Starting a new order from one of the customer's previous orders
// (19 Nov 2026, the user's request: "copy the order and make it a new
// order" — a quick way to raise today's order from an old one).
//
// Only the quantities are copied — what the rep counted, in the units they
// counted it in. Nothing else carries over, each for a reason:
//
//  * The rate. A Manna Treads per-kg item takes today's SAP price, filled in
//    by the order screen exactly as for a fresh order. A typed rate is left
//    blank, as on any new order: field pricing is negotiated per order, and a
//    prefilled number is one a tired rep accepts without looking.
//  * Loose belts. They have not been taken on an order since 10 Nov 2026.
//  * The delivery date. A date from a past order is in the past.
//
// The item itself may have moved on. The items SAP prices were created on
// 9 Nov 2026 under SAP's own codes and names —
//
//     I-11689      TREAD RUBBER  PRECURED BLACK PEARL 140 MSR 93"
//     PMD01003004  PCTR MANNA DOUBLE BLUE MSR 140 93 (BLACK PEARL)
//
// — and an order from before then names the old item, which SAP has no price
// for. Copied as it stood, every such line read "No price in SAP" while the
// same product had a price on a fresh order. So an old item that cannot be
// sold today is swapped for today's item with the same grade, the same
// numbers (width and thickness, in that order) and the same pattern
// ([itemMatchKey]) — but only when exactly ONE sellable item matches. Two
// candidates is a guess, and a guessed product on a customer's order is
// worse than a line the rep adds by hand; so is no candidate at all. Either
// way the rep is told which items were left out rather than finding the
// order quietly shorter.

import 'package:manna_field_sales/core/constants.dart';
import 'package:manna_field_sales/core/product_grade.dart';
import 'package:manna_field_sales/models/product_category.dart';

class OrderCopyResult {
  /// Item codes now carrying a quantity from the old order.
  final List<String> copied;

  /// Item names (or codes) on the old order that could not be copied.
  final List<String> leftOut;

  /// Old item code → today's item code it was copied onto.
  final Map<String, String> swapped;

  const OrderCopyResult(this.copied, this.leftOut, [this.swapped = const {}]);
}

int _asInt(dynamic v) =>
    v is num ? v.round() : (num.tryParse('${v ?? ''}')?.round() ?? 0);

double _asDouble(dynamic v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

/// Words that say what family or grade a name is, not which product. Dropped
/// before the pattern is compared.
const Set<String> _noise = {
  'TREAD', 'RUBBER', 'PRECURED', 'PCTR', 'HOT', //
  'BLACK', 'PEARL', 'PLATINUM', 'POLY', 'GOLD', 'POLYGOLD', 'POLYCOLD',
  'SILVER', 'DIAMOND', 'MEDIUM',
};

/// What identifies a product across the old and new naming: its grade, its
/// numbers in order, and the words left once family and grade are taken
/// out. Null when the name has no single grade or no numbers — nothing safe
/// to match on.
({String grade, String numbers, Set<String> words})? itemMatchKey(
    String name) {
  final up = name.toUpperCase();
  final grades = gradesIn(name);
  if (grades.length != 1) return null;

  final tokens = RegExp(r'[A-Z0-9]+').allMatches(up).map((m) => m.group(0)!);
  final numbers = <String>[];
  final words = <String>{};
  for (final t in tokens) {
    if (RegExp(r'^\d+$').hasMatch(t)) {
      numbers.add(int.parse(t).toString());
    } else if (!_noise.contains(t)) {
      words.add(t);
    }
  }
  if (numbers.isEmpty) return null;
  return (grade: grades.first, numbers: numbers.join(' '), words: words);
}

/// Whether [current] is the same product as the old item named [oldName]:
/// same grade, same numbers in the same order, and every pattern word of the
/// old name present in the new one (the new names add a brand — MANNA BLUE,
/// ROX, VERDO — that the old ones never had).
bool sameProduct(String oldName, String current) {
  final a = itemMatchKey(oldName);
  final b = itemMatchKey(current);
  if (a == null || b == null) return false;
  return a.grade == b.grade &&
      a.numbers == b.numbers &&
      b.words.containsAll(a.words);
}

/// Puts the quantities of [order]'s lines onto the matching [lines]. Lines
/// already holding a quantity are added to, so copying the same item twice
/// (it appears on two rows of the old order) is not lost.
///
/// [sellable] says whether a line can be ordered today (for Manna Treads:
/// SAP prices it). An old item that is not sellable is swapped for the one
/// sellable line of the same product, if there is exactly one.
OrderCopyResult copyOrderQuantities(
    List<OrderLine> lines, Map<String, dynamic> order,
    {bool Function(OrderLine line)? sellable}) {
  final canSell = sellable ?? (_) => true;
  final byCode = {for (final l in lines) l.product.code: l};
  final copied = <String>[];
  final leftOut = <String>[];
  final swapped = <String, String>{};

  for (final raw in (order['items'] as List? ?? const [])) {
    if (raw is! Map) continue;
    final it = raw.cast<String, dynamic>();
    final code = '${it['item_code'] ?? ''}';
    final label = '${it['item_name'] ?? ''}'.trim();
    final shown = label.isEmpty || label == 'null' ? code : label;

    var line = byCode[code];
    if (line == null || !canSell(line)) {
      final category = line?.product.category;
      final oldName = line?.product.name ?? shown;
      final matches = lines
          .where((l) =>
              l.product.code != code &&
              (category == null || l.product.category == category) &&
              canSell(l) &&
              sameProduct(oldName, l.product.name))
          .toList();
      if (matches.length != 1) {
        leftOut.add(shown);
        continue;
      }
      line = matches.single;
      swapped[code] = line.product.code;
    }

    var rolls = _asInt(it['custom_rolls']);
    var boxes = _asInt(it['custom_boxes']);
    var cans = _asInt(it['custom_cans']);

    // An order raised before the per-unit fields were stamped has only
    // `qty`, in the item's stock unit. Read it the way OrderLine.qty writes
    // it: rolls for tread rubber, tins for solution, kilograms for gum.
    if (rolls == 0 && boxes == 0 && cans == 0) {
      final qty = _asDouble(it['qty']);
      switch (line.product.category) {
        case ProductCategory.pctr:
        case ProductCategory.ctr:
        case ProductCategory.other:
          rolls = qty.floor();
          break;
        case ProductCategory.vulcanizingSolution:
          cans = qty.round();
          break;
        case ProductCategory.bondingGum:
          rolls = (qty / kBgKgPerRoll).round();
          break;
      }
    }

    switch (line.product.category) {
      case ProductCategory.bondingGum:
        line.boxes += boxes;
        line.rolls += rolls;
        break;
      case ProductCategory.vulcanizingSolution:
        line.cans += cans;
        break;
      default:
        line.rolls += rolls;
    }

    if (line.isEmpty) {
      // Loose belts only, or a zero line: nothing that can be ordered now.
      leftOut.add(shown);
    } else if (!copied.contains(line.product.code)) {
      copied.add(line.product.code);
    }
  }
  return OrderCopyResult(copied, leftOut, swapped);
}
